import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

final _random = Random();

/// Понятное описание сетевой ошибки для пользователя (подробности остаются в журнале).
String describeNetError(Object e) {
  if (e is TimeoutException) return 'Сервер не ответил вовремя';
  if (e is SocketException) {
    // 10013 / 10057 — Windows не дала открыть соединение: так выглядит блокировка файрволом
    // (например, simplewall ещё не разрешил новый файл программы).
    final code = e.osError?.errorCode;
    if (code == 10013 || code == 10057) {
      return 'Соединение заблокировано. Если установлен файрвол или антивирус — разрешите в нём SkipIt';
    }
    return 'Нет соединения с сервером — проверьте интернет';
  }
  if (e is HandshakeException) return 'Не удалось установить защищённое соединение с сервером';
  return e.toString().replaceFirst(RegExp(r'^(Http)?Exception: '), '');
}
String newId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
    '${_random.nextInt(0x7fffffff).toRadixString(36)}';

/// Декодирует base64 / base64url с отсутствующим паддингом. null — если это не base64.
String? tryBase64Decode(String input) {
  var s = input.trim().replaceAll(RegExp(r'\s'), '');
  if (s.isEmpty) return null;
  s = s.replaceAll('-', '+').replaceAll('_', '/').replaceAll('=', '');
  final rem = s.length % 4;
  if (rem == 1) return null;
  if (rem > 0) s = s.padRight(s.length + 4 - rem, '=');
  try {
    return utf8.decode(base64.decode(s));
  } catch (_) {
    return null;
  }
}

/// Значения заголовков подписок могут приходить как `base64:....`.
String decodeMaybeBase64Prefixed(String value) {
  final v = value.trim();
  if (v.toLowerCase().startsWith('base64:')) {
    return tryBase64Decode(v.substring(7)) ?? v;
  }
  return v;
}

String urlDecode(String s) {
  try {
    return Uri.decodeComponent(s);
  } catch (_) {
    return s;
  }
}

bool parseBool(Object? value, [bool fallback = false]) {
  if (value == null) return fallback;
  if (value is bool) return value;
  switch (value.toString().trim().toLowerCase()) {
    case 'true' || '1' || 'yes' || 'on':
      return true;
    case 'false' || '0' || 'no' || 'off':
      return false;
  }
  return fallback;
}

int? asInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return num.tryParse(value.toString().trim())?.toInt();
}

List<String> splitLines(String text) => text
    .split(RegExp(r'[\r\n]+'))
    .map((e) => e.trim())
    .where((e) => e.isNotEmpty)
    .toList();

Map<String, dynamic> deepCopyMap(Map<String, dynamic> map) =>
    jsonDecode(jsonEncode(map)) as Map<String, dynamic>;

String formatBytes(num bytes) {
  const units = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = unit == 0 ? 0 : (value < 10 ? 2 : 1);
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

String formatSpeed(num bytesPerSecond) => '${formatBytes(bytesPerSecond)}/с';

String _two(int n) => n.toString().padLeft(2, '0');

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  return h > 0 ? '$h:${_two(m)}:${_two(s)}' : '${_two(m)}:${_two(s)}';
}

String formatDate(DateTime d) => '${_two(d.day)}.${_two(d.month)}.${d.year}';

String formatDateTime(DateTime d) =>
    '${formatDate(d)} ${_two(d.hour)}:${_two(d.minute)}';
