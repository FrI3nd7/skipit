import 'dart:convert';
import 'dart:io';

import '../models/routing.dart';
import '../models/server.dart';
import '../models/settings.dart';
import 'util.dart';

class XrayConfig {
  static const _prefixes = ['geosite:', 'domain:', 'full:', 'regexp:', 'keyword:', 'ext:', 'dotless:'];

  /// Happ пишет домены без префикса — в Xray это была бы подстрока, поэтому добавляем `domain:`.
  static List<String> normalizeDomains(List<String> list) => [
        for (final raw in list)
          if (raw.trim().isNotEmpty)
            _prefixes.any((p) => raw.trim().toLowerCase().startsWith(p)) ? raw.trim() : 'domain:${raw.trim()}',
      ];

  static List<String> normalizeIps(List<String> list) =>
      [for (final raw in list) if (raw.trim().isNotEmpty) raw.trim()];

  static bool needsGeoFiles(RoutingProfile r) => [
        ...r.directSites, ...r.directIp, ...r.proxySites, ...r.proxyIp, ...r.blockSites, ...r.blockIp,
      ].any((e) => e.startsWith('geosite:') || e.startsWith('geoip:') || e.startsWith('ext:'));

  /// Полный JSON-конфиг сервера от провайдера (правила, балансировщики, DNS) или null для обычных ссылок.
  static Map<String, dynamic>? providerConfig(ServerProfile server) {
    if (!server.isJson) return null;
    try {
      final data = jsonDecode(server.link);
      final cfg = data is List ? data.first : data;
      return cfg is Map<String, dynamic> && cfg['outbounds'] is List ? cfg : null;
    } catch (_) {
      return null;
    }
  }

  static bool configNeedsGeoFiles(Map<String, dynamic> cfg) {
    final text = jsonEncode(cfg['routing'] ?? const {});
    return text.contains('geosite:') || text.contains('geoip:') || text.contains('ext:');
  }

  /// Убирает параметры, с которыми свежий Xray отказывается запускаться. Сейчас это `allowInsecure`:
  /// в Xray 26 он удалён (вместо него pinnedPeerCertSha256 / verifyPeerCertByName), а конфиги
  /// провайдеров и старые сохранённые серверы всё ещё могут его содержать.
  static T dropRemovedOptions<T>(T node) {
    if (node is Map) {
      final tls = node['tlsSettings'];
      if (tls is Map) tls.remove('allowInsecure');
      node.values.forEach(dropRemovedOptions);
    } else if (node is List) {
      node.forEach(dropRemovedOptions);
    }
    return node;
  }

  /// Конфиг провайдера используется целиком; подменяются только локальные входы (наши порты),
  /// журнал и статистика — чтобы работали счётчики трафика и настройки портов.
  static Map<String, dynamic> buildFromProvider(Map<String, dynamic> provider, AppSettings settings) {
    final cfg = deepCopyMap(provider);
    final listen = settings.allowLan ? '0.0.0.0' : '127.0.0.1';
    final sniffing = {
      'enabled': settings.sniffing,
      'destOverride': ['http', 'tls', 'quic'],
      'routeOnly': false,
    };
    final verbose = settings.logLevel == 'debug' || settings.logLevel == 'info';

    // Входы SOCKS/HTTP провайдера заменяем своими (теги те же — правила провайдера на них ссылаются),
    // прочие входы (например, DNS) оставляем.
    final keep = [
      for (final i in (cfg['inbounds'] as List? ?? const []))
        if (i is Map && i['protocol'] != 'socks' && i['protocol'] != 'http' && i['protocol'] != 'mixed') i,
    ];
    cfg['inbounds'] = [
      {
        'tag': 'socks',
        'protocol': 'socks',
        'listen': listen,
        'port': settings.socksPort,
        'settings': {'auth': 'noauth', 'udp': true},
        'sniffing': sniffing,
      },
      {
        'tag': 'http',
        'protocol': 'http',
        'listen': listen,
        'port': settings.httpPort,
        'settings': <String, dynamic>{},
        'sniffing': sniffing,
      },
      ...keep,
    ];
    cfg['log'] = {'loglevel': settings.logLevel, if (!verbose) 'access': 'none'};
    cfg['api'] = {
      'tag': 'api',
      'listen': '127.0.0.1:${settings.apiPort}',
      'services': ['StatsService'],
    };
    cfg['stats'] = <String, dynamic>{};
    final policy = (cfg['policy'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final system = (policy['system'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    system['statsOutboundUplink'] = true;
    system['statsOutboundDownlink'] = true;
    policy['system'] = system;
    cfg['policy'] = policy;
    // Метаданные клиента Xray не нужны.
    cfg.remove('remarks');
    return dropRemovedOptions(cfg);
  }

  /// Краткое содержание правил провайдера для экрана «Маршрутизация».
  static ({int direct, int proxy, int block, List<String> directExamples, List<String> blockNotes}) summarize(
      Map<String, dynamic> cfg) {
    var direct = 0, proxy = 0, block = 0;
    final examples = <String>[];
    final notes = <String>{};
    for (final r in ((cfg['routing'] as Map?)?['rules'] as List? ?? const [])) {
      if (r is! Map || r['inboundTag'] != null) continue;
      final domains = (r['domain'] as List?)?.cast<Object>() ?? const [];
      final ips = (r['ip'] as List?)?.cast<Object>() ?? const [];
      final count = domains.length + ips.length;
      final target = r['outboundTag'] ?? r['balancerTag'];
      if (target == 'direct') {
        direct += count;
        for (final d in domains) {
          if (examples.length < 4) examples.add('$d'.replaceFirst(RegExp(r'^(domain|full):'), '.'));
        }
      } else if (target == 'block') {
        block += count;
        if (r['protocol'] != null) notes.add('торренты');
        if (ips.contains('::/0')) notes.add('IPv6');
        if (r['network'] == 'udp' && '${r['port']}' == '443') notes.add('QUIC');
      } else if (target != null && r['network'] == null && r['port'] == null) {
        proxy += count;
      }
    }
    return (direct: direct, proxy: proxy, block: block, directExamples: examples, blockNotes: notes.toList());
  }

  static Map<String, dynamic> build({
    required ServerProfile server,
    required RoutingProfile routing,
    required AppSettings settings,
  }) {
    final provider = providerConfig(server);
    if (provider != null) return buildFromProvider(provider, settings);

    final listen = settings.allowLan ? '0.0.0.0' : '127.0.0.1';
    final sniffing = {
      'enabled': settings.sniffing,
      'destOverride': ['http', 'tls', 'quic'],
      'routeOnly': false,
    };
    final verbose = settings.logLevel == 'debug' || settings.logLevel == 'info';

    final proxy = dropRemovedOptions(deepCopyMap(server.outbound))..['tag'] = 'proxy';

    final directDomains = normalizeDomains(routing.directSites);
    final domesticDns = routing.domesticDnsAddress;
    final rules = <Map<String, dynamic>>[];

    // DNS-сервер для российских доменов ходит напрямую.
    if (InternetAddress.tryParse(domesticDns) != null) {
      rules.add({'ip': [domesticDns], 'port': '53', 'outboundTag': 'direct'});
    }

    void add(List<String> domains, List<String> ips, String tag) {
      final d = normalizeDomains(domains);
      final i = normalizeIps(ips);
      if (d.isNotEmpty) rules.add({'domain': d, 'outboundTag': tag});
      if (i.isNotEmpty) rules.add({'ip': i, 'outboundTag': tag});
    }

    add(routing.blockSites, routing.blockIp, 'block');
    add(routing.proxySites, routing.proxyIp, 'proxy');
    add(routing.directSites, routing.directIp, 'direct');
    rules.add({'network': 'tcp,udp', 'outboundTag': routing.globalProxy ? 'proxy' : 'direct'});

    return {
      'log': {'loglevel': settings.logLevel, if (!verbose) 'access': 'none'},
      'api': {
        'tag': 'api',
        'listen': '127.0.0.1:${settings.apiPort}',
        'services': ['StatsService'],
      },
      'stats': <String, dynamic>{},
      'policy': {
        'system': {'statsOutboundUplink': true, 'statsOutboundDownlink': true},
      },
      'dns': {
        if (routing.dnsHosts.isNotEmpty) 'hosts': routing.dnsHosts,
        'servers': [
          routing.remoteDnsAddress,
          if (directDomains.isNotEmpty)
            {'address': domesticDns, 'domains': directDomains, 'skipFallback': true},
        ],
        'queryStrategy': settings.ipv6 ? 'UseIP' : 'UseIPv4',
      },
      'inbounds': [
        {
          'tag': 'socks',
          'protocol': 'socks',
          'listen': listen,
          'port': settings.socksPort,
          'settings': {'auth': 'noauth', 'udp': true},
          'sniffing': sniffing,
        },
        {
          'tag': 'http',
          'protocol': 'http',
          'listen': listen,
          'port': settings.httpPort,
          'settings': <String, dynamic>{},
          'sniffing': sniffing,
        },
      ],
      'outbounds': [
        proxy,
        {
          'tag': 'direct',
          'protocol': 'freedom',
          // В Xray 26 стратегия адресов переехала из settings в sockopt (старое место объявлено устаревшим).
          'streamSettings': {
            'sockopt': {'domainStrategy': settings.ipv6 ? 'UseIP' : 'UseIPv4'},
          },
        },
        {'tag': 'block', 'protocol': 'blackhole'},
      ],
      'routing': {'domainStrategy': routing.domainStrategy, 'rules': rules},
    };
  }

  /// Конфиг для проверки задержки: на каждый сервер свой HTTP-inbound на своём порту.
  static Map<String, dynamic> buildTest(List<ServerProfile> servers, int basePort) {
    final inbounds = <Map<String, dynamic>>[];
    final outbounds = <Map<String, dynamic>>[];
    final rules = <Map<String, dynamic>>[];
    for (var i = 0; i < servers.length; i++) {
      inbounds.add({
        'tag': 'in$i',
        'protocol': 'http',
        'listen': '127.0.0.1',
        'port': basePort + i,
        'settings': <String, dynamic>{},
      });
      outbounds.add(dropRemovedOptions(deepCopyMap(servers[i].outbound))..['tag'] = 'out$i');
      rules.add({
        'inboundTag': ['in$i'],
        'outboundTag': 'out$i',
      });
    }
    return {
      'log': {'loglevel': 'none', 'access': 'none'},
      'inbounds': inbounds,
      'outbounds': outbounds,
      'routing': {'rules': rules},
    };
  }
}
