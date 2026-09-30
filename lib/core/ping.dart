import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/server.dart';
import 'core_manager.dart';
import 'paths.dart';
import 'xray_config.dart';

class Pinger {
  static const _basePort = 20800;
  static const _timeout = Duration(seconds: 6);

  /// TCP-рукопожатие с сервером. -1 — недоступен.
  static Future<int> tcp(ServerProfile s) async {
    final sw = Stopwatch()..start();
    try {
      final socket = await Socket.connect(s.address, s.port, timeout: const Duration(seconds: 4));
      socket.destroy();
      return sw.elapsedMilliseconds;
    } catch (_) {
      return -1;
    }
  }

  static Future<void> _pool<T>(List<T> items, int concurrency, Future<void> Function(T) fn) async {
    var index = 0;
    Future<void> worker() async {
      while (index < items.length) {
        final item = items[index++];
        await fn(item);
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));
  }

  static Future<void> tcpAll(List<ServerProfile> servers, void Function(ServerProfile, int) onResult) =>
      _pool(servers, 24, (s) async => onResult(s, s.isUdpOnly ? -1 : await tcp(s)));

  /// Реальная задержка: запрос testUrl через каждый сервер (отдельный процесс Xray на время теста).
  /// Ищет диапазон из [count] свободных локальных портов, чтобы не попасть в чужой процесс
  /// (например, в зависший тестовый Xray с прошлого раза).
  static Future<int?> _freeRange(int count) async {
    for (var base = _basePort; base < _basePort + 2000; base += count + 7) {
      final taken = <ServerSocket>[];
      var ok = true;
      for (var p = base; p < base + count; p++) {
        try {
          taken.add(await ServerSocket.bind(InternetAddress.loopbackIPv4, p));
        } catch (_) {
          ok = false;
          break;
        }
      }
      for (final s in taken) {
        await s.close();
      }
      if (ok) return base;
    }
    return null;
  }

  static Future<void> realDelayAll(
    List<ServerProfile> servers,
    String testUrl,
    LogBuffer log,
    void Function(ServerProfile, int) onResult,
  ) async {
    if (servers.isEmpty) return;
    void failAll(String why) {
      for (final s in servers) {
        onResult(s, -1);
      }
      log.add('test', why);
    }

    final base = await _freeRange(servers.length);
    if (base == null) return failAll('Нет свободных портов для проверки задержки');
    await File(AppPaths.testConfigFile).writeAsString(jsonEncode(XrayConfig.buildTest(servers, base)));
    final proc = CoreProcess('test', log);
    try {
      await proc.start(AppPaths.xrayExe, ['run', '-c', AppPaths.testConfigFile]);
      final ok = await waitForPort(base, alive: () => proc.running);
      if (!ok || !proc.running) return failAll('Xray не запустился для проверки задержки');
      final results = List<int>.filled(servers.length, -1);
      final indexed = List.generate(servers.length, (i) => i);
      await _pool(indexed, 12, (i) async {
        results[i] = await _httpDelay(base + i, testUrl);
      });
      // Если тестовый Xray умер посреди проверки, ответы получены не от него — результатам не верим.
      if (!proc.running) return failAll('Тестовый Xray завершился во время проверки');
      for (var i = 0; i < servers.length; i++) {
        onResult(servers[i], results[i]);
      }
    } finally {
      await proc.stop();
    }
  }

  static Future<int> _httpDelay(int port, String url) async {
    final client = HttpClient()
      ..findProxy = ((_) => 'PROXY 127.0.0.1:$port')
      ..connectionTimeout = _timeout
      ..badCertificateCallback = ((_, __, ___) => true);
    try {
      Future<int> once() async {
        final sw = Stopwatch()..start();
        final req = await client.getUrl(Uri.parse(url));
        final res = await req.close();
        await res.drain<void>();
        // Ответ с ошибкой (например, прокси сразу вернул 5xx) — это не «быстрый сервер», а недоступность.
        if (res.statusCode >= 400) throw HttpException('HTTP ${res.statusCode}');
        return sw.elapsedMilliseconds;
      }

      // Первый запрос прогревает соединение (TLS/Reality-рукопожатие), второй — честная задержка.
      final first = await once().timeout(_timeout);
      try {
        return await once().timeout(_timeout);
      } catch (_) {
        return first;
      }
    } catch (_) {
      return -1;
    } finally {
      client.close(force: true);
    }
  }
}
