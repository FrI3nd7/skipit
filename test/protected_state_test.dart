import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/core_manager.dart';
import 'package:skipit/core/link_parser.dart';
import 'package:skipit/core/paths.dart';
import 'package:skipit/core/windows.dart';
import 'package:skipit/models/subscription.dart';
import 'package:skipit/state/app_state.dart';

/// Подписки и серверы на диске зашифрованы ключом учётной записи Windows; перенос — через экспорт.
void main() {
  late Directory tmp;
  const url = 'https://panel.example/sub/SECRET-TOKEN';

  setUp(() async {
    await AppPaths.init();
    tmp = await Directory.systemTemp.createTemp('skipit-protected');
    AppPaths.dataDir = tmp;
  });
  tearDown(() async => tmp.delete(recursive: true));

  AppState filled() {
    final state = AppState();
    final sub = Subscription(url: url, name: 'Провайдер');
    state.subscriptions.add(sub);
    final server = LinkParser.parseText('trojan://PASSWORD-123@server.example:443#Germany').servers.single
      ..subscriptionId = sub.id;
    state.servers.add(server);
    state.settings
      ..selectedServerId = server.id
      ..killSwitch = true;
    return state;
  }

  test('шифрование Windows: свои данные читаются, чужие и повреждённые — нет', () {
    final plain = Uint8List.fromList(utf8.encode('ссылка подписки $url'));
    final blob = WinSys.protect(plain)!;
    expect(utf8.decode(blob, allowMalformed: true), isNot(contains('SECRET-TOKEN')));
    expect(WinSys.unprotect(blob), plain);
    expect(WinSys.unprotect(Uint8List.fromList([...blob]..[blob.length ~/ 2] ^= 0xFF)), isNull);
    expect(WinSys.unprotect(Uint8List.fromList(utf8.encode('это не шифр'))), isNull);
    expect(WinSys.unprotect(WinSys.protect(Uint8List(0))!), isEmpty);
  });

  test('в файле данных нет ссылок подписок и ключей серверов, а после запуска они на месте', () async {
    await filled().saveNow();
    final text = File(AppPaths.stateFile).readAsStringSync();
    expect(text, isNot(contains('SECRET-TOKEN')));
    expect(text, isNot(contains('PASSWORD-123')));
    expect(text, isNot(contains('server.example')));
    final j = jsonDecode(text) as Map<String, dynamic>;
    expect(j['protected'], isA<String>());
    expect(j.containsKey('subscriptions'), isFalse);
    // Настройки остаются открытыми — в них нет секретов.
    expect((j['settings'] as Map)['killSwitch'], isTrue);

    final again = AppState();
    await again.loadForTest();
    expect(again.subscriptions.single.url, url);
    expect(again.servers.single.address, 'server.example');
    expect(again.selectedServer?.name, 'Germany');
    expect(again.protectedUnreadable, isFalse);
  });

  test('файл от прежней версии (без шифрования) читается и шифруется при первом сохранении', () async {
    await File(AppPaths.stateFile).writeAsString('{"subscriptions":[{"id":"s1","url":"$url","name":"Test"}],'
        '"servers":[{"id":"a","name":"A","protocol":"vless","address":"1.1.1.1","port":443,"link":"vless://x",'
        '"outbound":{},"subscriptionId":"s1"}]}');
    final state = AppState();
    await state.loadForTest();
    expect((state.subscriptions.single.url, state.servers.single.name), (url, 'A'));
    await state.saveNow();
    expect(File(AppPaths.stateFile).readAsStringSync(), isNot(contains('SECRET-TOKEN')));
  });

  test('файл, зашифрованный для другой учётной записи: подписки не читаются, копия сохраняется', () async {
    await File(AppPaths.stateFile)
        .writeAsString(jsonEncode({'settings': {'killSwitch': true}, 'protected': base64Encode(utf8.encode('чужое'))}));
    final state = AppState();
    await state.loadForTest();
    expect(state.protectedUnreadable, isTrue);
    expect(state.subscriptions, isEmpty);
    // Настройки при этом читаются, а зашифрованная часть не пропадает.
    expect(state.settings.killSwitch, isTrue);
    expect(File('${AppPaths.stateFile}.locked').existsSync(), isTrue);
  });

  test('экспорт и импорт переносят всё; негодный файл ничего не портит', () async {
    final state = filled();
    final path = await state.exportData(tmp.path);
    // Файл экспорта — открытый: его и переносят на другой компьютер.
    expect(File(path).readAsStringSync(), contains('SECRET-TOKEN'));

    final other = AppState();
    expect(await other.importData(path), isNull);
    expect(other.subscriptions.single.url, url);
    expect(other.servers.single.name, 'Germany');
    expect(other.settings.killSwitch, isTrue);
    // Импортированное сразу сохранено зашифрованным.
    expect(File(AppPaths.stateFile).readAsStringSync(), isNot(contains('SECRET-TOKEN')));

    final junk = File('${tmp.path}\\junk.json')..writeAsStringSync('{"hello": 1}');
    expect(await other.importData(junk.path), 'Это не файл настроек SkipIt');
    final broken = File('${tmp.path}\\broken.json')
      ..writeAsStringSync('{"settings": {}, "subscriptions": [{"id": 5, "url": 7}], "servers": "x"}');
    expect(await other.importData(broken.path), isNotNull);
    expect(other.subscriptions.single.url, url);
    expect(other.servers.single.name, 'Germany');
  });

  test('ядро получает конфиг напрямую, без файла на диске', () async {
    final xray = File('core/skipit-xray.exe');
    if (!xray.existsSync()) return;
    final log = LogBuffer();
    final core = CoreProcess('xray', log);
    const config = '{"log":{"loglevel":"warning"},"inbounds":[{"tag":"s","protocol":"socks","listen":"127.0.0.1",'
        '"port":28941,"settings":{"auth":"noauth"}}],"outbounds":[{"tag":"direct","protocol":"freedom"}]}';
    await core.start(xray.absolute.path, ['run', '-c', 'stdin:'], input: config);
    final ok = await waitForPort(28941, alive: () => core.running);
    await core.stop();
    expect(ok, isTrue, reason: log.tail(8));
  });
}
