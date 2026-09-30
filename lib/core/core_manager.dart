import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'paths.dart';
import 'util.dart';

class LogLine {
  LogLine(this.source, this.text) : time = DateTime.now();
  final DateTime time;
  final String source;
  final String text;
}

class LogBuffer extends ChangeNotifier {
  static const max = 2000;
  static const _fileLimit = 1024 * 1024;
  final lines = <LogLine>[];
  File? _file;

  /// События приложения (не поток вывода ядер) дублируются в файл — для разбора проблем после перезапуска.
  void attachFile(String path) {
    try {
      final f = File(path);
      if (f.existsSync() && f.lengthSync() > _fileLimit) f.renameSync('$path.old');
      _file = f;
      _write('--- запуск ${DateTime.now().toIso8601String()} ---');
    } catch (_) {}
  }

  void _write(String line) {
    try {
      _file?.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  void add(String source, String text) {
    final toFile = source != 'xray' && source != 'sing-box' && source != 'test';
    for (final t in const LineSplitter().convert(text)) {
      if (t.trim().isEmpty) continue;
      final line = LogLine(source, t);
      lines.add(line);
      if (toFile) _write('${line.time.toIso8601String()} [$source] $t');
    }
    if (lines.length > max) lines.removeRange(0, lines.length - max);
    notifyListeners();
  }

  void clear() {
    lines.clear();
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

class CoreException implements Exception {
  CoreException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Один управляемый процесс ядра (xray или sing-box).
class CoreProcess {
  CoreProcess(this.name, this.log);

  final String name;
  final LogBuffer log;
  Process? _process;
  bool _stopping = false;
  void Function(int exitCode)? onUnexpectedExit;

  bool get running => _process != null;
  int? get pid => _process?.pid;

  Future<void> start(String exe, List<String> args, {Map<String, String>? env}) async {
    if (!File(exe).existsSync()) {
      throw CoreException('Не найден $exe. Запустите tools\\setup.ps1, чтобы скачать ядра.');
    }
    _stopping = false;
    final p = await Process.start(exe, args,
        workingDirectory: File(exe).parent.path, environment: env);
    _process = p;
    p.stdout.transform(utf8.decoder).listen((t) => log.add(name, t));
    p.stderr.transform(utf8.decoder).listen((t) => log.add(name, t));
    unawaited(p.exitCode.then((code) {
      if (!identical(_process, p)) return;
      _process = null;
      log.add(name, '[$name завершился с кодом $code]');
      if (!_stopping) onUnexpectedExit?.call(code);
    }));
  }

  Future<void> stop() async {
    final p = _process;
    if (p == null) return;
    _stopping = true;
    _process = null;
    p.kill();
    await p.exitCode.timeout(const Duration(seconds: 3), onTimeout: () {
      Process.killPid(p.pid, ProcessSignal.sigkill);
      return -1;
    });
  }
}

Future<bool> waitForPort(int port, {Duration timeout = const Duration(seconds: 6), bool Function()? alive}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (alive != null && !alive()) return false;
    try {
      final s = await Socket.connect(InternetAddress.loopbackIPv4, port,
          timeout: const Duration(milliseconds: 300));
      s.destroy();
      return true;
    } catch (_) {
      await Future.delayed(const Duration(milliseconds: 150));
    }
  }
  return false;
}

/// Счётчики трафика из Stats API Xray (`xray api statsquery`).
class TrafficStats {
  int up = 0;
  int down = 0;
  int upSpeed = 0;
  int downSpeed = 0;

  void reset() => up = down = upSpeed = downSpeed = 0;

  Future<void> poll(int apiPort) async {
    try {
      final r = await Process.run(AppPaths.xrayExe,
          ['api', 'statsquery', '--server=127.0.0.1:$apiPort', '-pattern', 'outbound>>>'],
          stdoutEncoding: utf8);
      if (r.exitCode != 0) return;
      final data = jsonDecode(r.stdout as String) as Map<String, dynamic>;
      var u = 0, d = 0;
      for (final s in (data['stat'] as List? ?? const [])) {
        final name = s['name'] as String? ?? '';
        final value = asInt(s['value']) ?? 0;
        if (name.startsWith('outbound>>>api')) continue;
        if (name.endsWith('uplink')) u += value;
        if (name.endsWith('downlink')) d += value;
      }
      upSpeed = u > up ? u - up : 0;
      downSpeed = d > down ? d - down : 0;
      up = u;
      down = d;
    } catch (_) {}
  }
}
