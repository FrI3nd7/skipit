import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/link_parser.dart';
import 'package:skipit/core/singbox_config.dart';
import 'package:skipit/core/updates.dart';
import 'package:skipit/core/xray_config.dart';
import 'package:skipit/models/app_rules.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/models/settings.dart';
import 'package:skipit/state/app_state.dart';
import 'package:skipit/version.dart';

void main() {
  test('ссылки извне не импортируются без подтверждения', () async {
    final state = AppState();
    await state.handleArgs(['skipit://add/https://evil.example/sub', '--autostart']);
    expect(state.pendingLinks, ['skipit://add/https://evil.example/sub']);
    expect(state.subscriptions, isEmpty);
    await state.resolvePendingLink(state.pendingLinks.first, accept: false);
    expect(state.pendingLinks, isEmpty);
    expect(state.subscriptions, isEmpty);
  });

  test('TUN перехватывает IPv6: при выключенном IPv6 он блокируется, а не идёт мимо VPN', () async {
    final settings = AppSettings()..ipv6 = false;
    final cfg = SingboxConfig.build(
        settings: settings, routing: RoutingProfile.global(), apps: AppRules(), serverDomains: const []);
    final tun = (cfg['inbounds'] as List).single as Map;
    expect((tun['address'] as List).any((a) => '$a'.contains(':')), isTrue);
    final rules = (cfg['route'] as Map)['rules'] as List;
    expect(rules.any((r) => r['ip_version'] == 6 && r['action'] == 'reject'), isTrue);

    settings.ipv6 = true;
    final on = SingboxConfig.build(
        settings: settings, routing: RoutingProfile.global(), apps: AppRules(), serverDomains: const []);
    expect(((on['route'] as Map)['rules'] as List).any((r) => r['ip_version'] == 6), isFalse);

    // Проверка самим ядром sing-box, если оно лежит в проекте.
    final singbox = File('core/skipit-sing-box.exe');
    if (singbox.existsSync()) {
      final f = File('${Directory.systemTemp.path}\\skipit-tun-test.json');
      await f.writeAsString(jsonEncode(cfg));
      final r = await Process.run(singbox.absolute.path, ['check', '-c', f.path]);
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      await f.delete();
    }
  });

  test('подменённый файл обновления отбрасывается', () async {
    final f = File('${Directory.systemTemp.path}\\skipit-verify-test.bin');
    await f.writeAsString('настоящий установщик');
    final real = await Updates.sha256Of(f.path);

    await Updates.verify(f.path, real.toUpperCase());
    expect(f.existsSync(), isTrue);

    await expectLater(Updates.verify(f.path, '0' * 64), throwsA(isA<Exception>()));
    expect(f.existsSync(), isFalse, reason: 'подменённый файл должен быть удалён');
  });

  test('адреса обновления строятся из тега релиза, без API GitHub', () {
    final r = Release('v1.0.2b', 'getskipit/skipit');
    expect(r.version, '1.0.2b');
    expect(r.installerUrl,
        'https://github.com/getskipit/skipit/releases/download/v1.0.2b/SkipIt-Setup-Windows-1.0.2b.exe');
    expect(r.checksumUrl, '${r.installerUrl}.sha256');
  });

  test('allowInsecure не попадает в конфиг: Xray 26 с ним не запускается', () {
    final s = LinkParser.parseLink(
        'vless://3b5a3c2e-8f6b-4c7e-9d1a-2f4e6a8c0b1d@example.com:443?security=tls&sni=example.com&allowInsecure=1#a')!;
    expect(jsonEncode(s.outbound), isNot(contains('allowInsecure')));
    expect(s.warning, contains('allowInsecure'));

    // Отпечаток и имя сертификата из ссылки (pcs, vcn) переходят в новые параметры ядра.
    final pinned = LinkParser.parseLink(
        'vless://3b5a3c2e-8f6b-4c7e-9d1a-2f4e6a8c0b1d@example.com:443?security=tls&sni=example.com&allowInsecure=1&pcs=${'ab' * 32}&vcn=example.org#a')!;
    final tls = (pinned.outbound['streamSettings'] as Map)['tlsSettings'] as Map;
    expect(tls['pinnedPeerCertSha256'], 'ab' * 32);
    expect(tls['verifyPeerCertByName'], 'example.org');
    expect(pinned.warning, isNull);

    // Серверы, сохранённые старой версией, и конфиги провайдеров: параметр вычищается при сборке конфига.
    final legacy = {
      'outbounds': [
        {'protocol': 'trojan', 'streamSettings': {'security': 'tls', 'tlsSettings': {'allowInsecure': true, 'serverName': 'a.com'}}},
      ],
    };
    final cleaned = jsonEncode(XrayConfig.dropRemovedOptions(legacy));
    expect(cleaned, isNot(contains('allowInsecure')));
    expect(cleaned, contains('a.com'));
  });

  test('просьба применить правила приложений зависит от того, изменилось ли что-то на деле', () {
    final rules = AppRules(mode: AppRoutingMode.allExcept, entries: [
      AppEntry(match: 'C:/Apps/Steam.exe', label: 'steam'),
      AppEntry(match: 'C:/Apps/Game.exe', label: 'game', enabled: false),
    ]);
    final applied = rules.signature;

    // Переключили режим и вернули обратно — применять нечего.
    rules.mode = AppRoutingMode.onlySelected;
    expect(rules.signature, isNot(applied));
    rules.mode = AppRoutingMode.allExcept;
    expect(rules.signature, applied);

    // Выключенная запись и переименование на трафик не влияют.
    rules.entries.removeLast();
    rules.entries.first.label = 'Steam';
    expect(rules.signature, applied);

    // А включение/выключение программы — влияет.
    rules.entries.first.enabled = false;
    expect(rules.signature, isNot(applied));

    // В режиме «Выключено» список не важен.
    rules.mode = AppRoutingMode.off;
    final off = rules.signature;
    rules.entries.first.enabled = true;
    expect(rules.signature, off);
  });

  test('User-Agent по умолчанию несёт версию программы и обновляется вместе с ней', () {
    expect(AppSettings().userAgent, 'SkipIt/$appVersion');
    // Значение, сохранённое старой версией, — не выбор пользователя: заменяется текущим.
    expect(AppSettings.fromJson({'userAgent': 'SkipIt/1.0'}).userAgent, 'SkipIt/$appVersion');
    expect(AppSettings.fromJson({'userAgent': 'SkipIt/1.0.1a'}).userAgent, 'SkipIt/$appVersion');
    // А своё значение пользователя сохраняется как есть.
    expect(AppSettings.fromJson({'userAgent': 'Happ/2.0'}).userAgent, 'Happ/2.0');
  });

  test('VLESS без шифрования к серверу в интернете помечается предупреждением', () {
    const id = '3b5a3c2e-8f6b-4c7e-9d1a-2f4e6a8c0b1d';
    expect(LinkParser.parseLink('vless://$id@example.com:80?type=tcp&security=none#a')!.warning, isNotNull);
    expect(LinkParser.parseLink('vless://$id@192.168.1.10:80?type=tcp&security=none#a')!.warning, isNull);
    expect(LinkParser.parseLink('vless://$id@example.com:443?type=tcp&security=tls&sni=example.com#a')!.warning, isNull);
  });

  test('парсер не падает на мусоре из ссылки', () {
    for (final s in ['skipit://add/', 'vless://', 'ss://@:0', 'happ://routing/add/%%%', 'vmess://!!!']) {
      expect(() => LinkParser.parseText(s), returnsNormally, reason: s);
    }
  });
}
