import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/log_store.dart';

/// Журнал разбит на отрезки по подключениям, каждый отрезок — файл; журнал дня живёт 5 дней.
void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('skipit-logs'));
  tearDown(() async => dir.delete(recursive: true));

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
