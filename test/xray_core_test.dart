import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skipit/core/link_parser.dart';
import 'package:skipit/core/xray_config.dart';
import 'package:skipit/models/routing.dart';
import 'package:skipit/models/settings.dart';

/// Проверка на настоящем ядре: конфиг, который SkipIt строит из ссылки каждого вида,
/// должен приниматься вложенным Xray (`xray run -test`). Ловит случаи, когда новая версия ядра
/// убрала или переименовала параметр. Ядро берётся из core\ (или из переменной XRAY_EXE);
/// если его нет (ядра ещё не скачаны), проверка пропускается.
void main() {
  final exe = Platform.environment['XRAY_EXE'] ?? '${Directory.current.path}\\core\\skipit-xray.exe';
  final hasCore = File(exe).existsSync();

  const uuid = '3b5a3c2e-8f6b-4c7e-9d1a-2f4e6a8c0b1d';
  const pbk = 'SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc';
  final vmessJson = base64.encode(utf8.encode(jsonEncode({
    'v': '2', 'ps': 'vmess ws', 'add': 'example.com', 'port': '443', 'id': uuid, 'aid': '0', 'scy': 'auto',
    'net': 'ws', 'type': 'none', 'host': 'example.com', 'path': '/ws', 'tls': 'tls', 'sni': 'example.com',
  })));

  final links = <String, String>{
    'VLESS + REALITY + Vision':
        'vless://$uuid@example.com:443?type=tcp&security=reality&pbk=$pbk&sid=6ba85179e30d4fc2&sni=www.example.com&fp=chrome&flow=xtls-rprx-vision#a',
    'VLESS + REALITY + XHTTP':
        'vless://$uuid@example.com:443?type=xhttp&security=reality&pbk=$pbk&sid=6ba85179&sni=www.example.com&path=%2Fx&mode=auto#a',
    'VLESS + XHTTP + TLS (extra)':
        'vless://$uuid@example.com:443?type=xhttp&security=tls&sni=example.com&host=example.com&path=%2Fx&mode=packet-up&alpn=h2&extra=%7B%22xPaddingBytes%22%3A%22100-1000%22%7D#a',
    'VLESS + WS + TLS': 'vless://$uuid@example.com:443?type=ws&security=tls&sni=example.com&host=example.com&path=%2Fws&fp=firefox#a',
    'VLESS + gRPC + TLS': 'vless://$uuid@example.com:443?type=grpc&security=tls&sni=example.com&serviceName=grpc&mode=multi#a',
    'VLESS + HTTPUpgrade': 'vless://$uuid@example.com:443?type=httpupgrade&security=tls&sni=example.com&host=example.com&path=%2Fup#a',
    // VLESS без шифрования Xray разрешает только для адресов локальной сети.
    'VLESS + TCP без шифрования (локальная сеть)': 'vless://$uuid@192.168.1.10:8080?type=tcp&security=none#a',
    'VLESS + TCP c HTTP-заголовком': 'vless://$uuid@192.168.1.10:80?type=tcp&headerType=http&host=example.com&path=%2F#a',
    'VLESS + mKCP': 'vless://$uuid@192.168.1.10:443?type=kcp&headerType=wechat-video&seed=secret#a',
    'VLESS + TLS без проверки сертификата': 'vless://$uuid@example.com:443?type=tcp&security=tls&sni=example.com&allowInsecure=1#a',
    'VLESS + TLS с закреплённым сертификатом (pcs, vcn)':
        'vless://$uuid@example.com:443?type=tcp&security=tls&sni=example.com&pcs=${'ab' * 32}&vcn=example.org#a',
    'VLESS + TLS + ECH': 'vless://$uuid@example.com:443?type=ws&security=tls&sni=example.com&path=%2Fws&ech=cloudflare-ech.com%2Bhttps%3A%2F%2F1.1.1.1%2Fdns-query#a',
    'VLESS + старый транспорт h2': 'vless://$uuid@example.com:443?type=h2&security=tls&sni=example.com&path=%2Fh2#a',
    'VMess (base64 JSON) + WS + TLS': 'vmess://$vmessJson',
    'VMess (ссылка) + TCP': 'vmess://$uuid@example.com:443?type=tcp&security=tls&sni=example.com#a',
    'Trojan + TLS': 'trojan://password@example.com:443?security=tls&sni=example.com#a',
    'Trojan + WS': 'trojan://password@example.com:443?type=ws&security=tls&sni=example.com&path=%2Ft#a',
    'Trojan + gRPC': 'trojan://password@example.com:443?type=grpc&security=tls&sni=example.com&serviceName=t#a',
    'Shadowsocks': 'ss://${base64.encode(utf8.encode('chacha20-ietf-poly1305:password'))}@example.com:8388#a',
    'Shadowsocks 2022':
        'ss://${base64Url.encode(utf8.encode('2022-blake3-aes-128-gcm:${base64.encode(List.filled(16, 7))}'))}@example.com:8388#a',
    'SOCKS5': 'socks://${base64.encode(utf8.encode('user:pass'))}@example.com:1080#a',
    'Hysteria 2': 'hysteria2://password@example.com:443?sni=example.com#a',
    'Hysteria 2 без проверки сертификата': 'hy2://password@example.com:443?sni=example.com&insecure=1#a',
  };

  for (final entry in links.entries) {
    test('Xray принимает конфиг: ${entry.key}', () async {
      final server = LinkParser.parseLink(entry.value)!;
      final config = XrayConfig.build(server: server, routing: RoutingProfile.global(), settings: AppSettings());
      // Правила с geoip/geosite требуют файлов баз, которых в проекте нет, — для проверки ссылок они не нужны.
      ((config['routing'] as Map)['rules'] as List).removeWhere((r) => jsonEncode(r).contains(RegExp('geoip:|geosite:')));
      final dir = await Directory.systemTemp.createTemp('skipit-xray-test');
      try {
        final file = File('${dir.path}\\config.json');
        await file.writeAsString(jsonEncode(config));
        final r = await Process.run(exe, ['run', '-test', '-c', file.path], stdoutEncoding: utf8, stderrEncoding: utf8);
        final out = '${r.stdout}\n${r.stderr}';
        expect(r.exitCode, 0, reason: out);
        // Устаревшие параметры конфига ядро пока принимает с предупреждением — ловим их заранее, до удаления.
        // (Предупреждения о самих протоколах — WebSocket, gRPC, VMess, Trojan, Shadowsocks — сюда не относятся:
        // их выбирает провайдер, а не SkipIt.)
        expect(out, isNot(contains('setting is deprecated')), reason: out);
      } finally {
        await dir.delete(recursive: true);
      }
    }, skip: hasCore ? false : 'ядро Xray не скачано (tools\\setup.ps1)');
  }
}
