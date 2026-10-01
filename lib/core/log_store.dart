import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

class LogLine {
  LogLine(this.source, this.text, [DateTime? time]) : time = time ?? DateTime.now();
  final DateTime time;
  final String source;
  final String text;

  /// 2 — ошибка, 1 — предупреждение, 0 — обычная строка.
  late final int level = _levelOf(text);

  static int _levelOf(String text) {
    final t = text.toLowerCase();
    if (t.contains('error') || t.contains('fatal') || t.contains('panic') || t.contains('ошибк') ||
        t.contains('сбой') || t.contains('не удалось')) {
      return 2;
    }
    // Xray пишет «[Warning] core: Xray … started» при обычном запуске — это не предупреждение.
    if (t.contains('warn') && !t.contains('started')) return 1;
    return 0;
  }
}

/// Отрезок журнала: одно подключение к серверу или время без подключения между ними.
class LogSession {
  LogSession({
    required this.id,
    required this.start,
    required this.connection,
    required this.title,
    this.detail = '',
    this.file,
  }) : end = start;

  /// Имя файла без расширения: `2026-10-01_15-13-41_123` (по нему же считается срок хранения).
  final String id;
  final DateTime start;
  DateTime end;

  /// true — подключение к серверу, false — события программы без подключения.
  final bool connection;

  /// Имя сервера (для подключения) или подпись отрезка.
  final String title;

  /// Режим подключения.
  final String detail;
  final File? file;

  int count = 0;
  int warnings = 0;
  int errors = 0;

  /// Сейчас в этот отрезок пишутся строки.
  bool live = false;

  /// Строки отрезка; null — ещё не прочитаны с диска (см. [LogBuffer.load]).
  List<LogLine>? lines;

  RandomAccessFile? _out;
  int _written = 0;

  void _count(LogLine l) {
    count++;
    if (l.level == 2) errors++;
    if (l.level == 1) warnings++;
    if (l.time.isAfter(end)) end = l.time;
  }
}

/// Журнал программы и ядер, разбитый на отрезки по подключениям. Каждый отрезок — отдельный файл
/// в папке `logs`; файлы старше [keepDays] дней удаляются.
class LogBuffer extends ChangeNotifier {
  /// Сколько дней хранится журнал каждого дня.
  static const keepDays = 5;

  /// Больше строк одного отрезка в памяти не держим (при уровне debug ядро пишет очень много).
  static const maxLines = 5000;

  /// И больше этого в файл одного отрезка не пишем.
  static const _fileLimit = 4 * 1024 * 1024;

  /// Все отрезки, от старых к новым.
  final sessions = <LogSession>[];
  LogSession? _current;
  Directory? _dir;

  /// Отрезок, в который сейчас идёт запись (null — пока не было ни одной строки).
  LogSession? get current => _current;

  /// Строки текущего отрезка.
  List<LogLine> get lines => _current?.lines ?? const [];

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _idFor(DateTime t) => '${t.year}-${_two(t.month)}-${_two(t.day)}_${_two(t.hour)}-${_two(t.minute)}-'
      '${_two(t.second)}_${t.millisecond.toString().padLeft(3, '0')}';

  /// Подключает папку с файлами журнала: удаляет просроченные и поднимает список прошлых отрезков.
  /// Без вызова журнал живёт только в памяти (так работают тесты).
  Future<void> open(Directory dir) async {
    try {
      // Папка подключается сразу (синхронно): строки, пришедшие, пока читается история, уже пишутся в файлы.
      dir.createSync(recursive: true);
      _dir = dir;
      _purgeOld();
      final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.log')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      final past = <LogSession>[];
      for (final f in files) {
        if (sessions.any((s) => s.file?.path == f.path)) continue;
        final s = await _readSession(f, keepLines: false);
        if (s != null) past.add(s);
      }
      sessions.insertAll(0, past);
      notifyListeners();
    } catch (_) {
      // Папка недоступна — журнал остаётся в памяти.
    }
  }

  /// День из имени файла: журнал дня живёт [keepDays] дней, потом удаляется целиком.
  void _purgeOld() {
    final dir = _dir;
    if (dir == null) return;
    final now = DateTime.now();
    final limit = DateTime(now.year, now.month, now.day).subtract(const Duration(days: keepDays));
    try {
      for (final f in dir.listSync().whereType<File>()) {
        final m = RegExp(r'(\d{4})-(\d{2})-(\d{2})_[\d_-]+\.log$').firstMatch(f.path);
        if (m == null) continue;
        final day = DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
        if (day.isBefore(limit)) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
    sessions.removeWhere((s) => !s.live && s.file != null && !s.file!.existsSync());
  }

  /// Читает файл отрезка: заголовок и строки (для списка достаточно счётчиков — [keepLines] false).
  static Future<LogSession?> _readSession(File f, {required bool keepLines}) async {
    try {
      final rows = await f.readAsLines();
      if (rows.isEmpty || !rows.first.startsWith('#')) return null;
      final head = jsonDecode(rows.first.substring(1)) as Map<String, dynamic>;
      final name = f.uri.pathSegments.last;
      final s = LogSession(
        id: name.substring(0, name.length - 4),
        start: DateTime.parse(head['start'] as String),
        connection: head['connection'] == true,
        title: head['title'] as String? ?? '',
        detail: head['detail'] as String? ?? '',
        file: f,
      );
      final lines = <LogLine>[];
      for (final row in rows.skip(1)) {
        final a = row.indexOf('\t');
        final b = a < 0 ? -1 : row.indexOf('\t', a + 1);
        if (b < 0) continue;
        final time = DateTime.tryParse(row.substring(0, a));
        if (time == null) continue;
        final line = LogLine(row.substring(a + 1, b), row.substring(b + 1), time);
        s._count(line);
        if (keepLines) lines.add(line);
      }
      if (keepLines) s.lines = lines;
      return s;
    } catch (_) {
      return null;
    }
  }

  /// Подгружает строки прошлого отрезка с диска (текущий и так в памяти).
  Future<void> load(LogSession s) async {
    if (s.lines != null || s.file == null || !_loading.add(s.id)) return;
    final full = await _readSession(s.file!, keepLines: true);
    s.lines = full?.lines ?? [];
    _loading.remove(s.id);
    notifyListeners();
  }

  final _loading = <String>{};

  void _begin({required bool connection, required String title, String detail = ''}) {
    _purgeOld();
    final now = DateTime.now();
    final id = _idFor(now);
    final dir = _dir;
    final s = LogSession(
      id: id,
      start: now,
      connection: connection,
      title: title,
      detail: detail,
      file: dir == null ? null : File('${dir.path}\\$id.log'),
    )
      ..live = true
      ..lines = [];
    try {
      s._out = s.file?.openSync(mode: FileMode.write);
      s._out?.writeStringSync('#${jsonEncode({
            'start': now.toIso8601String(),
            'connection': connection,
            'title': title,
            'detail': detail,
          })}\n');
    } catch (_) {
      s._out = null;
    }
    sessions.add(s);
    _current = s;
  }

  void _finish() {
    final s = _current;
    if (s == null) return;
    s.live = false;
    try {
      s._out?.closeSync();
    } catch (_) {}
    s._out = null;
    _current = null;
  }

  /// Начало подключения: дальше строки пишутся в новый отрезок с именем сервера.
  void startSession(String title, {String detail = ''}) {
    _finish();
    _begin(connection: true, title: title, detail: detail);
    notifyListeners();
  }

  /// Подключение закончилось. Следующий отрезок («без подключения») появится с первой же строкой.
  void endSession() {
    if (_current == null) return;
    _finish();
    notifyListeners();
  }

  void add(String source, String text) {
    for (final t in const LineSplitter().convert(text)) {
      if (t.trim().isEmpty) continue;
      if (_current == null) _begin(connection: false, title: 'Без подключения');
      final s = _current!;
      final line = LogLine(source, t);
      s.lines!.add(line);
      if (s.lines!.length > maxLines) s.lines!.removeRange(0, s.lines!.length - maxLines);
      s._count(line);
      if (s._out != null && s._written < _fileLimit) {
        try {
          final row = '${line.time.toIso8601String()}\t$source\t$t\n';
          s._out!.writeStringSync(row);
          s._written += row.length;
        } catch (_) {}
      }
    }
    notifyListeners();
  }

  /// Закрывает файл текущего отрезка (выход из программы).
  void close() => _finish();

  /// Удаляет прошлый отрезок вместе с файлом. Текущий удалить нельзя — в него идёт запись.
  void remove(LogSession s) {
    if (s.live) return;
    try {
      s.file?.deleteSync();
    } catch (_) {}
    sessions.remove(s);
    notifyListeners();
  }

  /// Удаляет все прошлые отрезки; текущий остаётся.
  void clearHistory() {
    for (final s in sessions.where((s) => !s.live).toList()) {
      try {
        s.file?.deleteSync();
      } catch (_) {}
      sessions.remove(s);
    }
    notifyListeners();
  }

  String tail(int n, {String? source}) => lines
      .where((l) => source == null || l.source == source)
      .toList()
      .reversed
      .take(n)
      .toList()
      .reversed
      .map((l) => l.text)
      .join('\n');
}
