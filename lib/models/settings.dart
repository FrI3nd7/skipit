import '../core/util.dart';
import '../core/windows.dart';

enum ConnectionMode {
  /// Виртуальный адаптер (sing-box TUN): весь трафик системы, нужны права администратора.
  tun,

  /// TUN + системный прокси: браузеры идут через HTTP-порт (точнее маршрутизация по доменам),
  /// остальное ловит TUN. Нужны права администратора.
  mixed,

  /// Системный прокси Windows (HTTP) — только программы, которые его уважают.
  systemProxy,

  /// Только локальные SOCKS/HTTP-порты, система не трогается.
  proxyOnly,
}

enum PingType { tcp, realDelay }

enum AppTheme { dark, light, system }

/// Канал обновлений SkipIt: только релизы или ещё и пре-релизы (бета).
enum UpdateChannel { stable, beta }

class AppSettings {
  ConnectionMode mode = ConnectionMode.mixed;
  int socksPort = 10808;
  int httpPort = 10809;
  int apiPort = 10813;
  bool allowLan = false;
  bool ipv6 = false;
  bool sniffing = true;
  int mtu = 9000;
  bool autoSelect = false;
  bool autoReconnect = true;
  bool connectOnStart = false;
  String testUrl = 'https://www.gstatic.com/generate_204';
  PingType pingType = PingType.realDelay;
  String logLevel = 'warning';
  String userAgent = 'SkipIt/1.0';
  bool sendHwid = true;
  String hwid = newId();
  bool updateSubsOnStart = true;
  bool updateViaProxy = true;
  bool sidebarCollapsed = false;
  bool closeToTray = true;
  bool preferJson = true;
  UpdateChannel updateChannel = UpdateChannel.stable;
  AppTheme theme = AppTheme.dark;

  String? selectedServerId;
  String? selectedRoutingId;

  /// Состояние, которое нужно восстановить после сбоя.
  bool systemProxyActive = false;
  SystemProxyState? previousProxy;
  int? lastXrayPid;
  int? lastSingboxPid;

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        // Метка: режим уже выбран с «Смешанным» по умолчанию (см. fromJson).
        'mixedDefault': true,
        'socksPort': socksPort,
        'httpPort': httpPort,
        'apiPort': apiPort,
        'allowLan': allowLan,
        'ipv6': ipv6,
        'sniffing': sniffing,
        'mtu': mtu,
        'autoSelect': autoSelect,
        'autoReconnect': autoReconnect,
        'connectOnStart': connectOnStart,
        'testUrl': testUrl,
        'pingType': pingType.name,
        'logLevel': logLevel,
        'userAgent': userAgent,
        'sendHwid': sendHwid,
        'hwid': hwid,
        'updateSubsOnStart': updateSubsOnStart,
        'updateViaProxy': updateViaProxy,
        'sidebarCollapsed': sidebarCollapsed,
        'closeToTray': closeToTray,
        'preferJson': preferJson,
        'updateChannel': updateChannel.name,
        'theme': theme.name,
        'selectedServerId': selectedServerId,
        'selectedRoutingId': selectedRoutingId,
        'systemProxyActive': systemProxyActive,
        'previousProxy': previousProxy?.toJson(),
        'lastXrayPid': lastXrayPid,
        'lastSingboxPid': lastSingboxPid,
      };

  static AppSettings fromJson(Map<String, dynamic> j) {
    final s = AppSettings();
    s.mode = ConnectionMode.values.asNameMap()[j['mode']] ?? s.mode;
    // Раньше по умолчанию был TUN — один раз переводим такие настройки на «Смешанный».
    if (j['mixedDefault'] != true && s.mode == ConnectionMode.tun) s.mode = ConnectionMode.mixed;
    s.socksPort = asInt(j['socksPort']) ?? s.socksPort;
    s.httpPort = asInt(j['httpPort']) ?? s.httpPort;
    s.apiPort = asInt(j['apiPort']) ?? s.apiPort;
    s.allowLan = parseBool(j['allowLan'], s.allowLan);
    s.ipv6 = parseBool(j['ipv6'], s.ipv6);
    s.sniffing = parseBool(j['sniffing'], s.sniffing);
    s.mtu = asInt(j['mtu']) ?? s.mtu;
    s.autoSelect = parseBool(j['autoSelect'], s.autoSelect);
    s.autoReconnect = parseBool(j['autoReconnect'], s.autoReconnect);
    s.connectOnStart = parseBool(j['connectOnStart'], s.connectOnStart);
    s.testUrl = j['testUrl'] as String? ?? s.testUrl;
    s.pingType = PingType.values.asNameMap()[j['pingType']] ?? s.pingType;
    s.logLevel = j['logLevel'] as String? ?? s.logLevel;
    s.userAgent = j['userAgent'] as String? ?? s.userAgent;
    s.sendHwid = parseBool(j['sendHwid'], s.sendHwid);
    s.hwid = j['hwid'] as String? ?? s.hwid;
    s.updateSubsOnStart = parseBool(j['updateSubsOnStart'], s.updateSubsOnStart);
    s.updateViaProxy = parseBool(j['updateViaProxy'], s.updateViaProxy);
    s.sidebarCollapsed = parseBool(j['sidebarCollapsed'], s.sidebarCollapsed);
    s.closeToTray = parseBool(j['closeToTray'], s.closeToTray);
    s.preferJson = parseBool(j['preferJson'], s.preferJson);
    s.updateChannel = UpdateChannel.values.asNameMap()[j['updateChannel']] ?? s.updateChannel;
    s.theme = AppTheme.values.asNameMap()[j['theme']] ?? s.theme;
    s.selectedServerId = j['selectedServerId'] as String?;
    s.selectedRoutingId = j['selectedRoutingId'] as String?;
    s.systemProxyActive = parseBool(j['systemProxyActive']);
    final prev = j['previousProxy'];
    s.previousProxy = prev is Map<String, dynamic> ? SystemProxyState.fromJson(prev) : null;
    s.lastXrayPid = asInt(j['lastXrayPid']);
    s.lastSingboxPid = asInt(j['lastSingboxPid']);
    return s;
  }
}
