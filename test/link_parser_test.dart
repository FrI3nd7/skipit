import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/link_parser.dart';
import 'package:skipit/core/singbox_config.dart';
import 'package:skipit/core/updates.dart';
import 'package:skipit/core/xray_config.dart';
import 'package:skipit/models/app_rules.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/models/settings.dart';

void main() {
  test('VLESS Reality', () {
    final r = LinkParser.parseText(
        'vless://b831381d-6324-4d53-ad4f-8cda48b30811@1.2.3.4:443?type=tcp&security=reality&sni=yahoo.com'
        '&fp=chrome&pbk=Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw&sid=6ba8&flow=xtls-rprx-vision#%F0%9F%87%B3%F0%9F%87%B1%20NL');
    expect(r.servers, hasLength(1));
    final s = r.servers.first;
    expect(s.name, '🇳🇱 NL');
    expect(s.port, 443);
    final stream = s.outbound['streamSettings'] as Map;
    expect(stream['security'], 'reality');
    expect((stream['realitySettings'] as Map)['publicKey'], 'Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw');
  });

  test('VMess base64', () {
    final json = jsonEncode({
      'v': '2', 'ps': 'vm', 'add': 'a.com', 'port': '8443', 'id': 'b831381d-6324-4d53-ad4f-8cda48b30811',
      'net': 'ws', 'path': '/ws', 'host': 'a.com', 'tls': 'tls',
    });
    final r = LinkParser.parseText('vmess://${base64.encode(utf8.encode(json))}');
    expect(r.servers.single.port, 8443);
    expect((r.servers.single.outbound['streamSettings'] as Map)['network'], 'ws');
  });

  test('Shadowsocks SIP002 и старый формат', () {
    final a = LinkParser.parseText('ss://${base64Url.encode(utf8.encode('aes-256-gcm:pass'))}@h.com:8388#A');
    final b = LinkParser.parseText('ss://${base64.encode(utf8.encode('chacha20-ietf-poly1305:pw@h.com:1234'))}#B');
    expect(a.servers.single.port, 8388);
    expect(b.servers.single.port, 1234);
    final server = ((b.servers.single.outbound['settings'] as Map)['servers'] as List).first as Map;
    expect(server['password'], 'pw');
  });

  test('Trojan, Hysteria2, подписка base64, URL и диплинки', () {
    final body = base64.encode(utf8.encode('trojan://pw@t.com:443?sni=t.com#T\nhy2://auth@h.com:443?sni=h.com#H'));
    final r = LinkParser.parseText(body);
    expect(r.servers.map((e) => e.protocol), ['trojan', 'hysteria']);

    final sub = LinkParser.parseText('happ://add/https://panel.example/sub/abc');
    expect(sub.subscriptionUrls, ['https://panel.example/sub/abc']);

    final crypt = LinkParser.parseText('happ://crypt3/xxxx');
    expect(crypt.errors, isNotEmpty);

    final routing = RoutingProfile(name: 'R', proxySites: ['geosite:youtube']);
    final rd = LinkParser.parseText(routing.toDeeplink().replaceFirst('/add/', '/onadd/'));
    expect(rd.routing.single.activate, isTrue);
    expect(rd.routing.single.profile!.proxySites, ['geosite:youtube']);
  });

  test('Генерация конфигов', () {
    final server = LinkParser.parseText('trojan://pw@t.com:443#T').servers.single;
    final routing = RoutingProfile.templates()[0];
    final settings = AppSettings();
    final x = XrayConfig.build(server: server, routing: routing, settings: settings);
    expect((x['outbounds'] as List).first['tag'], 'proxy');
    final apps = AppRules(mode: AppRoutingMode.allExcept, entries: [
      AppEntry(match: 'Telegram', label: 'Telegram', action: AppAction.direct),
      AppEntry(match: 'C:/Games/', label: 'Games', action: AppAction.direct),
    ]);
    final s = SingboxConfig.build(settings: settings, routing: routing, apps: apps, serverDomains: ['t.com']);
    final rules = (s['route'] as Map)['rules'] as List;
    expect(rules.any((r) => (r as Map)['process_name']?.contains('Telegram.exe') == true), isTrue);
  });

  test('Сравнение версий', () {
    expect(Updates.compare('26.3.27', '26.3.9'), 1);
    expect(Updates.compare('v1.14.2', '1.14.2'), 0);
    expect(Updates.compare('1.0.0', '1.0.0a'), 1);
    expect(Updates.compare('1.0.0b', '1.0.0a'), 1);
    expect(Updates.compare('1.0.1a', '1.0.0'), 1);
    // Схема версий SkipIt: 1.0.0a → 1.0.1a → 1.0.2b → 1.0.3.
    const order = ['1.0.0a', '1.0.1a', '1.0.2b', '1.0.3'];
    for (var i = 0; i + 1 < order.length; i++) {
      expect(Updates.compare(order[i + 1], order[i]), 1, reason: '${order[i + 1]} новее ${order[i]}');
      expect(Updates.compare(order[i], order[i + 1]), -1);
    }
    expect(Updates.compare('v1.0.2b', '1.0.2b'), 0);
    expect(Updates.compare('1.0.3', '1.0.3b'), 1);
  });
}