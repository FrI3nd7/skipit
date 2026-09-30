import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/link_parser.dart';
import 'package:skipit/core/singbox_config.dart';
import 'package:skipit/core/updates.dart';
import 'package:skipit/models/app_rules.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/models/settings.dart';
import 'package:skipit/state/app_state.dart';

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
    final singbox = File('core/sing-box.exe');
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
    const url = 'https://example.com/SkipIt-Setup-Windows-9.9.9.exe';

    await Updates.verify(Release('9.9.9', '', {}, digests: {url: real}), url, f.path);
    expect(f.existsSync(), isTrue);

    await expectLater(
      Updates.verify(Release('9.9.9', '', {}, digests: {url: '0' * 64}), url, f.path),
      throwsA(isA<Exception>()),
    );
    expect(f.existsSync(), isFalse, reason: 'подменённый файл должен быть удалён');
  });

  test('парсер не падает на мусоре из ссылки', () {
    for (final s in ['skipit://add/', 'vless://', 'ss://@:0', 'happ://routing/add/%%%', 'vmess://!!!']) {
      expect(() => LinkParser.parseText(s), returnsNormally, reason: s);
    }
  });
}
