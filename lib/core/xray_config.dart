import 'dart:convert';
import 'dart:io';

import '../models/app_rules.dart';
import '../models/routing.dart';
import '../models/server.dart';
import '../models/settings.dart';
import 'paths.dart';
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

  /// Переносит устаревшие параметры конфига провайдера на новое место, чтобы ядро не ругалось в журнале.
  /// Сейчас это `domainStrategy` у выхода freedom: в Xray 26 он переехал из settings в sockopt.
  static void _migrateDeprecated(Map<String, dynamic> cfg) {
    for (final o in (cfg['outbounds'] as List? ?? const [])) {
      if (o is! Map || o['protocol'] != 'freedom') continue;
      final settings = o['settings'];
      if (settings is! Map || !settings.containsKey('domainStrategy')) continue;
      final strategy = settings.remove('domainStrategy');
      final stream = (o['streamSettings'] ??= <String, dynamic>{}) as Map;
      final sockopt = (stream['sockopt'] ??= <String, dynamic>{}) as Map;
      sockopt['domainStrategy'] ??= strategy;
    }
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
    // Журнал доступа включён всегда: из него строится список соединений в разделе «Логи».
    cfg['log'] = {'loglevel': settings.logLevel};
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
    _migrateDeprecated(cfg);
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
      'log': {'loglevel': settings.logLevel},
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

  static const tunTag = 'skipit-tun';
  static const _tunGateway = ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'];

  /// DNS адаптера — сосед шлюза в подсети TUN: запросы к нему попадают в адаптер, там их
  /// перехватывает правило, и отвечает встроенный DNS Xray.
  static const _tunDns = '172.19.0.2';

  /// Адреса VPN-серверов резолвим напрямую, иначе Xray не сможет к ним подключиться.
  static const _bootstrapDns = '77.88.8.8';
  static const _privateNets = [
    '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16', '127.0.0.0/8', '224.0.0.0/4',
    '255.255.255.255/32', 'fc00::/7', 'fe80::/10', 'ff00::/8',
  ];

  static void _collectAddresses(Object? node, Set<String> out) {
    if (node is Map) {
      final a = node['address'];
      if (a is String && a.isNotEmpty && InternetAddress.tryParse(a) == null) out.add(a);
      node.values.forEach((v) => _collectAddresses(v, out));
    } else if (node is List) {
      node.forEach((v) => _collectAddresses(v, out));
    }
  }

  /// Режим «TUN на ядре Xray»: адаптер поднимает сам Xray, sing-box не запускается.
  /// Дописывает в готовый конфиг (свой или провайдера) вход TUN, перехват DNS и правила по приложениям —
  /// то же, что в обычном режиме делает [SingboxConfig]. Свои выходы и правила названы с приставкой
  /// `skipit-`, чтобы не совпасть с тегами провайдера.
  static void addTun(
    Map<String, dynamic> cfg, {
    required AppSettings settings,
    required AppRules apps,
    List<String> directDomains = const [],
  }) {
    const direct = 'skipit-direct', block = 'skipit-block', dnsOut = 'skipit-dns';
    final inbound = [tunTag];

    final tun = {
      'tag': tunTag,
      'protocol': 'tun',
      'settings': {
        'name': AppPaths.appName,
        'desc': AppPaths.appName,
        'mtu': settings.mtu,
        // IPv6-адрес и маршрут есть всегда: иначе IPv6-трафик шёл бы мимо туннеля (утечка IP).
        // При выключенном IPv6 он блокируется правилом ниже.
        'gateway': _tunGateway,
        'dns': [_tunDns],
        'autoSystemRoutingTable': ['0.0.0.0/0', '::/0'],
        // Сам Xray ходит через настоящий сетевой адаптер — иначе получится петля.
        'autoOutboundsInterface': 'auto',
        // DNS-запросы программ мимо адаптера блокируются фильтром Windows.
        'autoSystemWfpBlockLeak': ['dns'],
      },
      'sniffing': {
        'enabled': settings.sniffing,
        'destOverride': ['http', 'tls', 'quic'],
        'routeOnly': false,
      },
    };
    cfg['inbounds'] = [...(cfg['inbounds'] as List? ?? const []), tun];

    final outbounds = [...(cfg['outbounds'] as List)];
    final first = outbounds.first as Map;
    final defaultTag = (first['tag'] ??= 'proxy') as String;
    final domains = <String>{...directDomains};
    _collectAddresses(outbounds, domains);
    outbounds.addAll([
      {
        'tag': dnsOut,
        'protocol': 'dns',
        'settings': {
          // На запросы адресов (A и AAAA) отвечает встроенный DNS Xray, остальные виды запросов отклоняются.
          'rules': [
            {'action': 'hijack', 'qType': '1,28'},
            {'action': 'return', 'rCode': 5},
          ],
        },
      },
      {
        'tag': direct,
        'protocol': 'freedom',
        'streamSettings': {
          'sockopt': {'domainStrategy': settings.ipv6 ? 'UseIP' : 'UseIPv4'},
        },
      },
      {'tag': block, 'protocol': 'blackhole'},
    ]);
    cfg['outbounds'] = outbounds;

    final dns = (cfg['dns'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final servers = [...(dns['servers'] as List? ?? const [])];
    if (servers.isEmpty) servers.add('1.1.1.1');
    if (domains.isNotEmpty) {
      servers.add({'address': _bootstrapDns, 'domains': [for (final d in domains) 'full:$d'], 'skipFallback': true});
    }
    dns['servers'] = servers;
    cfg['dns'] = dns;

    final routing = (cfg['routing'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final rules = [...(routing['rules'] as List? ?? const [])];
    final own = <Map<String, dynamic>>[
      {'inboundTag': inbound, 'port': '53', 'outboundTag': dnsOut},
      {'ip': [_bootstrapDns], 'port': '53', 'outboundTag': direct},
      {'inboundTag': inbound, 'ip': _privateNets, 'outboundTag': direct},
      if (!settings.ipv6) {'inboundTag': inbound, 'ip': ['::/0'], 'outboundTag': block},
    ];

    routing['rules'] = [
      ...own,
      // Правила по приложениям действуют и на адаптер, и на прокси-порты: в «Смешанном» режиме
      // браузеры ходят через системный прокси, мимо адаптера.
      ..._appRules(apps, [tunTag, ..._proxyInbounds], rules, defaultTag, direct),
      ...rules,
    ];
    cfg['routing'] = routing;
  }

  static const _proxyInbounds = ['socks', 'http'];

  /// Правила по приложениям для соединений, пришедших через входы [inbound].
  /// Запись списка — имя процесса, путь или папка с прямыми слэшами: Xray понимает их в том же виде.
  /// [alwaysVpn] — процессы, которые в режиме «только выбранные» считаются выбранными.
  static List<Map<String, dynamic>> _appRules(
    AppRules apps,
    List<String> inbound,
    List rules,
    String defaultTag,
    String direct, {
    List<String> alwaysVpn = const [],
  }) {
    final listed = apps.enabledMatches;
    switch (apps.mode) {
      case AppRoutingMode.off:
        return const [];
      case AppRoutingMode.allExcept:
        return [
          if (listed.isNotEmpty) {'inboundTag': inbound, 'process': listed, 'outboundTag': direct},
        ];
      case AppRoutingMode.onlySelected:
        // Правила «все, кроме списка» в Xray нет. Поэтому для выбранных программ повторяются обычные
        // правила, а всё остальное с этих входов идёт напрямую.
        final vpn = [...listed, ...alwaysVpn];
        return [
          if (vpn.isNotEmpty) ...[
            for (final r in rules)
              if (r is Map && r['inboundTag'] == null && r['process'] == null)
                {...r.cast<String, dynamic>(), 'inboundTag': inbound, 'process': vpn}..remove('ruleTag'),
            {'inboundTag': inbound, 'process': vpn, 'outboundTag': defaultTag},
          ],
          {'inboundTag': inbound, 'outboundTag': direct},
        ];
    }
  }

  /// TUN держит sing-box: правила по приложениям для трафика из адаптера применяет он сам
  /// ([SingboxConfig]). Но через прокси-порты программы приходят в Xray напрямую, мимо sing-box
  /// (в «Смешанном» режиме так ходят браузеры) — для них те же правила добавляются сюда.
  static void addProxyAppRules(Map<String, dynamic> cfg, {required AppSettings settings, required AppRules apps}) {
    if (apps.mode == AppRoutingMode.off) return;
    const direct = 'skipit-direct';
    final outbounds = [...(cfg['outbounds'] as List)];
    final defaultTag = ((outbounds.first as Map)['tag'] ??= 'proxy') as String;
    outbounds.add({
      'tag': direct,
      'protocol': 'freedom',
      'streamSettings': {
        'sockopt': {'domainStrategy': settings.ipv6 ? 'UseIP' : 'UseIPv4'},
      },
    });
    cfg['outbounds'] = outbounds;
    final routing = (cfg['routing'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    final rules = [...(routing['rules'] as List? ?? const [])];
    routing['rules'] = [
      // Трафик выбранных программ из адаптера приходит сюда от имени sing-box — он уже отобран.
      ..._appRules(apps, _proxyInbounds, rules, defaultTag, direct, alwaysVpn: const ['skipit-sing-box']),
      ...rules,
    ];
    cfg['routing'] = routing;
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
