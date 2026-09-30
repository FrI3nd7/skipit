import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/link_parser.dart';
import 'package:skipit/core/xray_config.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/models/settings.dart';

/// JSON-подписка в духе Remnawave: балансировщик, DNS-вход, правила «напрямую/через VPN/блок».
const _provider = '''
[{
  "remarks": "🇩🇪Germany",
  "log": {"loglevel": "warning"},
  "dns": {"tag": "dns-in", "servers": [{"address": "77.88.8.8", "domains": ["domain:ru"]}, "1.1.1.1"]},
  "inbounds": [
    {"tag": "socks", "protocol": "socks", "listen": "127.0.0.1", "port": 10808, "settings": {"udp": true}},
    {"tag": "http", "protocol": "http", "listen": "127.0.0.1", "port": 10809}
  ],
  "outbounds": [
    {"tag": "proxy", "protocol": "vless", "settings": {"vnext": [{"address": "de.example.com", "port": 443,
      "users": [{"id": "b831381d-6324-4d53-ad4f-8cda48b30811", "encryption": "none", "flow": "xtls-rprx-vision"}]}]},
     "streamSettings": {"network": "raw", "security": "reality", "realitySettings": {"serverName": "yahoo.com",
      "fingerprint": "chrome", "publicKey": "Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw", "shortId": "6ba8"}}},
    {"tag": "proxy-2", "protocol": "vless", "settings": {"vnext": [{"address": "de2.example.com", "port": 443,
      "users": [{"id": "b831381d-6324-4d53-ad4f-8cda48b30811", "encryption": "none"}]}]}},
    {"tag": "block", "protocol": "blackhole"},
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "dns-out", "protocol": "dns"}
  ],
  "observatory": {"subjectSelector": ["proxy"], "probeUrl": "https://www.gstatic.com/generate_204"},
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "balancers": [{"tag": "PROXY", "selector": ["proxy"], "strategy": {"type": "leastPing"}, "fallbackTag": "proxy"}],
    "rules": [
      {"type": "field", "inboundTag": ["dns-in"], "balancerTag": "PROXY"},
      {"type": "field", "port": 53, "outboundTag": "dns-out"},
      {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"},
      {"type": "field", "ip": ["::/0"], "outboundTag": "block"},
      {"type": "field", "network": "udp", "port": "443", "outboundTag": "block"},
      {"type": "field", "ip": ["10.0.0.0/8", "192.168.0.0/16"], "outboundTag": "direct"},
      {"type": "field", "domain": ["domain:ru", "domain:su", "domain:xn--p1ai", "domain:2ip.ru"], "outboundTag": "direct"},
      {"type": "field", "domain": ["domain:telegram.org", "domain:t.me"], "balancerTag": "PROXY"},
      {"type": "field", "network": "tcp,udp", "balancerTag": "PROXY"}
    ]
  }
}]
''';

void main() {
  test('JSON-конфиг провайдера используется целиком, меняются только порты и статистика', () async {
    final server = LinkParser.parseText(_provider).servers.single;
    expect(server.isJson, isTrue);
    expect(server.name, '🇩🇪Germany');

    final settings = AppSettings()
      ..socksPort = 20808
      ..httpPort = 20809;
    final cfg = XrayConfig.build(server: server, routing: RoutingProfile.global(), settings: settings);

    // Правила и балансировщик провайдера на месте.
    final routing = cfg['routing'] as Map;
    expect((routing['rules'] as List).length, 9);
    expect((routing['balancers'] as List).single['tag'], 'PROXY');
    expect(cfg['observatory'], isNotNull);
    expect((cfg['outbounds'] as List).map((o) => o['tag']), containsAll(['proxy', 'proxy-2', 'direct', 'block']));

    // Входы — наши порты, статистика включена.
    final inbounds = cfg['inbounds'] as List;
    expect(inbounds.firstWhere((i) => i['tag'] == 'socks')['port'], 20808);
    expect(inbounds.firstWhere((i) => i['tag'] == 'http')['port'], 20809);
    expect(cfg['api'], isNotNull);
    expect(((cfg['policy'] as Map)['system'] as Map)['statsOutboundUplink'], isTrue);

    final s = XrayConfig.summarize(cfg);
    expect(s.direct, 6);
    expect(s.blockNotes, containsAll(['торренты', 'IPv6', 'QUIC']));

    // Проверка самим ядром Xray, если оно лежит в проекте.
    final xray = File('core/xray.exe');
    if (xray.existsSync()) {
      final f = File('${Directory.systemTemp.path}\\skipit-provider-test.json');
      await f.writeAsString(jsonEncode(cfg));
      final r = await Process.run(xray.absolute.path, ['run', '-test', '-c', f.path]);
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      await f.delete();
    }
  });
}
