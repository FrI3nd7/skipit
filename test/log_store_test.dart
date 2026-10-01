import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/log_explain.dart';
import 'package:skipit/core/log_store.dart';

/// Журнал разбит на отрезки по подключениям, каждый отрезок — файл; журнал дня живёт 5 дней.
void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('skipit-logs'));
  tearDown(() async => dir.delete(recursive: true));

  test('строка журнала доступа Xray разбирается в соединение: куда шло и каким путём', () {
    const routes = {'proxy': ConnRoute.proxy, 'direct': ConnRoute.direct, 'block': ConnRoute.block};
    // Строки в том виде, как их пишет Xray 26.9.30.
    final a = ConnEntry.tryParse(
        '2026/10/02 00:01:11.773977 from tcp:127.0.0.1:50349 accepted tcp:example.com:443 [socks >> direct]', routes)!;
    expect((a.network, a.host, a.port, a.inbound, a.outbound, a.route),
        ('tcp', 'example.com', 443, 'socks', 'direct', ConnRoute.direct));
    final b = ConnEntry.tryParse('from tcp:127.0.0.1:1 accepted udp:[2a00:1450::8a]:443 [skipit-tun -> block]', routes)!;
    expect((b.network, b.host, b.route), ('udp', '[2a00:1450::8a]', ConnRoute.block));
    // Неизвестный выход (сервер провайдера с любым тегом) — это VPN.
    expect(ConnEntry.tryParse('from 127.0.0.1:1 accepted tcp:a.com:80 [http -> de-1]', routes)!.route, ConnRoute.proxy);
    expect(ConnEntry.tryParse('[Warning] core: Xray 26.9.30 started', routes), isNull);
  });

  test('соединения хранятся только в памяти: список сайтов на диск не пишется', () async {
    final log = LogBuffer();
    await log.open(dir);
    log.startSession('Сервер');
    log.addConnection(ConnEntry(
        network: 'tcp', host: 'secret.example', port: 443, inbound: 'socks', outbound: 'proxy', route: ConnRoute.proxy));
    log.endSession();
    expect(log.sessions.single.connections, hasLength(1));
    expect(log.sessions.single.file!.readAsStringSync(), isNot(contains('secret.example')));
  });

  test('к строкам ядра есть пояснения простыми словами, к строкам программы — нет', () {
    expect(LogExplain.of('xray', '[Warning] core: Xray 26.9.30 started'), contains('запущено'));
    expect(LogExplain.of('xray', 'proxy/http: failed to read response from ipv6.msftconnecttest.com > unexpected EOF'),
        contains('ipv6.msftconnecttest.com'));
    expect(LogExplain.of('xray', 'The "freedom.domainStrategy" setting is deprecated'), contains('устаревший'));
    expect(LogExplain.of('sing-box', 'open interface take too much time'), contains('адаптер'));
    expect(LogExplain.of('app', 'Ошибка подключения: timeout'), isNull);
    expect(LogExplain.of('xray', 'A unified platform for anti-censorship.'), isNull);
  });

  test('строки делятся на отрезки: без подключения → подключение → без подключения', () async {
    final log = LogBuffer();
    await log.open(dir);

    log.add('app', 'Запуск');
    log.startSession('🇩🇪 Germany', detail: 'Смешанный');
    log.add('xray', '[Warning] core: Xray 26.9.30 started');
    log.add('xray', '[Warning] proxy/http: failed to read response');
    log.add('app', 'Ошибка подключения: порт занят');
    log.endSession();
    log.add('update', 'У вас последняя версия');

    expect(log.sessions.map((s) => s.connection), [false, true, false]);
    final conn = log.sessions[1];
    expect(conn.title, '🇩🇪 Germany');
    expect(conn.detail, 'Смешанный');
    expect(conn.live, isFalse);
    // «Xray … started» — не предупреждение, остальные две строки считаются.
    expect((conn.count, conn.warnings, conn.errors), (3, 1, 1));
    expect(log.sessions.last.live, isTrue);
    expect(log.tail(5), 'У вас последняя версия');
    log.close();
  });

  test('после перезапуска прошлые отрезки читаются с диска', () async {
    final first = LogBuffer();
    await first.open(dir);
    first.startSession('Finland', detail: 'TUN');
    first.add('sing-box', 'ERROR connection: i/o timeout');
    first.endSession();

    final second = LogBuffer();
    await second.open(dir);
    final past = second.sessions.single;
    expect((past.title, past.detail, past.errors, past.live), ('Finland', 'TUN', 1, false));
    expect(past.lines, isNull, reason: 'строки подгружаются только при открытии отрезка');
    await second.load(past);
    expect(past.lines!.single.text, 'ERROR connection: i/o timeout');

    second.remove(past);
    expect(second.sessions, isEmpty);
    expect(dir.listSync(), isEmpty);
  });

  test('журнал старше 5 дней удаляется, более свежий остаётся', () async {
    String name(DateTime t) =>
        '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}_10-00-00_000.log';
    final now = DateTime.now();
    final old = File('${dir.path}\\${name(now.subtract(const Duration(days: 6)))}');
    final fresh = File('${dir.path}\\${name(now.subtract(const Duration(days: 4)))}');
    for (final f in [old, fresh]) {
      await f.writeAsString('#{"start":"${now.toIso8601String()}","connection":true,"title":"A","detail":""}\n');
    }

    final log = LogBuffer();
    await log.open(dir);
    expect(old.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);
    expect(log.sessions.length, 1);
  });
}
