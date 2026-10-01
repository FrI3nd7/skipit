import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/core_manager.dart';
import '../core/link_parser.dart';
import '../core/net.dart';
import '../core/paths.dart';
import '../core/ping.dart';
import '../core/singbox_config.dart';
import '../core/updates.dart';
import '../core/util.dart';
import '../core/windows.dart';
import '../core/xray_config.dart';
import '../models/app_rules.dart';
import '../models/routing.dart';
import '../models/server.dart';
import '../models/settings.dart';
import '../models/subscription.dart';
import '../version.dart';

enum ConnStatus { disconnected, connecting, connected, disconnecting }

class NeedAdminException implements Exception {
  @override
  String toString() => 'Для режима TUN нужны права администратора';
}

class AppState extends ChangeNotifier {
  AppSettings settings = AppSettings();
  final subscriptions = <Subscription>[];
  final servers = <ServerProfile>[];
  final routingProfiles = <RoutingProfile>[];
  AppRules appRules = AppRules();

  final log = LogBuffer();
  final stats = TrafficStats();
  final _messages = StreamController<String>.broadcast();
  Stream<String> get messages => _messages.stream;

  late final CoreProcess _xray = CoreProcess('xray', log)..onUnexpectedExit = _onCoreCrash;
  late final CoreProcess _singbox = CoreProcess('sing-box', log)..onUnexpectedExit = _onCoreCrash;

  ConnStatus status = ConnStatus.disconnected;

  /// Открытый раздел меню — живёт здесь, чтобы пережить перестройку окна при смене темы.
  int pageIndex = 0;

  /// Разделы меню по порядку: главная, маршрутизация, логи, настройки.
  static const routingPage = 1;

  void openPage(int index) {
    pageIndex = index;
    notifyListeners();
  }

  /// Какая маршрутизация сейчас действует — коротко, для главной.
  /// У серверов с JSON-конфигом провайдера работают его правила, выбранный профиль не применяется.
  /// [sites] — правила для сайтов и IP, [apps] — правила по программам (null, если их нет
  /// или режим подключения их не применяет).
  ({String sites, String? apps}) get routingSummary {
    final server = selectedServer;
    final sites = server != null && XrayConfig.providerConfig(server) != null ? 'Правила провайдера' : selectedRouting.name;
    final count = appRules.enabledMatches.length;
    final apps = !usesTun
        ? null
        : switch (appRules.mode) {
            AppRoutingMode.off => null,
            AppRoutingMode.allExcept => count == 0 ? null : 'Программ напрямую, мимо VPN: $count',
            AppRoutingMode.onlySelected => 'Через VPN только выбранные программы: $count',
          };
    return (sites: sites, apps: apps);
  }
  String? lastError;
  DateTime? connectedAt;
  bool pinging = false;
  final updatingSubs = <String>{};
  bool autostart = false;
  final isAdmin = WinSys.isAdmin();

  Timer? _statsTimer;
  Timer? _subsTimer;
  Timer? _saveTimer;
  final _crashTimes = <DateTime>[];

  // ---------------------------------------------------------------------------
  // Загрузка / сохранение
  // ---------------------------------------------------------------------------

  /// Читает сохранённые настройки и подписки. Вызывается до показа окна: по настройкам решается,
  /// нужно ли сначала перезапуститься с правами администратора.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    await _load();
  }

  bool _loaded = false;

  /// Настройка «Запускать от имени администратора» включена, а прав нет — нужно перезапуститься.
  /// После отказа в окне Windows (ключ --no-elevate) повторно не спрашиваем.
  bool needsElevation(List<String> args) =>
      settings.runAsAdmin && !isAdmin && !args.contains('--elevated') && !args.contains('--no-elevate');

  Future<void> init(List<String> args) async {
    unawaited(log.open(AppPaths.logDir));
    await load();
    // Окно должно узнать о данных сразу, даже если дальше что-то пойдёт не так.
    notifyListeners();

    // Каждый шаг запуска изолирован: сбой одного не должен оставлять окно пустым.
    Future<void> step(String name, Future<void> Function() f) async {
      try {
        await f();
      } catch (e) {
        log.add('app', 'Сбой при запуске ($name): $e');
      }
    }

    await step('восстановление', _recoverAfterCrash);
    // Установщик прошлого обновления больше не нужен.
    await step('уборка обновлений', () async {
      final dir = Directory('${File(AppPaths.exe).parent.path}\\update');
      if (dir.existsSync()) await dir.delete(recursive: true);
    });
    await step('ссылки skipit://', WinSys.registerUrlScheme);
    await step('автозапуск', () async => autostart = await WinSys.isAutostartEnabled());
    unawaited(step('версии ядер', detectCoreVersions));
    // Тихая проверка обновлений через несколько секунд после запуска.
    Timer(const Duration(seconds: 8), () => step('обновления', () => checkUpdates(silent: true)));
    notifyListeners();

    // Раз в минуту смотрим, не пора ли обновить подписки (проверка дешёвая — сравнение времени).
    _subsTimer = Timer.periodic(const Duration(minutes: 1), (_) => _updateDueSubscriptions());
    if (settings.updateSubsOnStart) unawaited(_updateDueSubscriptions(force: true));

    await handleArgs(args);
    final wantConnect = args.contains('--connect') ||
        (settings.connectOnStart && (args.contains('--autostart') || args.contains('--elevated')));
    if (wantConnect && selectedServer != null) unawaited(connect());
  }

  /// true — файл данных есть, но прочитать его не удалось. Тогда ничего не сохраняем,
  /// чтобы не затереть подписки пустым состоянием.
  bool _stateUnreadable = false;

  /// Читает файл, переживая кратковременные блокировки (антивирус, выходящая копия программы).
  static Future<String> _readWithRetry(File file) async {
    for (var attempt = 1;; attempt++) {
      try {
        return await file.readAsString();
      } on FileSystemException {
        if (attempt >= 15) rethrow;
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
  }

  Future<void> _load() async {
    final file = File(AppPaths.stateFile);
    if (file.existsSync()) {
      String text;
      try {
        text = await _readWithRetry(file);
      } catch (e) {
        _stateUnreadable = true;
        log.add('app', 'Файл данных занят или недоступен, сохранение отключено до перезапуска: $e');
        text = '';
      }
      if (text.isNotEmpty) try {
        final j = jsonDecode(text) as Map<String, dynamic>;
        settings = AppSettings.fromJson(j['settings'] as Map<String, dynamic>? ?? const {});
        subscriptions.addAll(((j['subscriptions'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(Subscription.fromJson));
        servers.addAll(((j['servers'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ServerProfile.fromJson));
        routingProfiles.addAll(((j['routing'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(RoutingProfile.fromJson));
        appRules = AppRules.fromJson(j['apps'] as Map<String, dynamic>? ?? const {});
      } catch (e) {
        // Файл повреждён: откладываем копию и продолжаем с чистого листа.
        log.add('app', 'Не удалось разобрать файл данных, копия сохранена как state.json.broken: $e');
        try {
          await file.copy('${file.path}.broken');
        } catch (_) {}
      }
    }
    routingProfiles.removeWhere((r) => RoutingProfile.legacyPresetIds.contains(r.id));
    if (!routingProfiles.any((r) => r.id == RoutingProfile.globalPresetId)) {
      routingProfiles.insert(0, RoutingProfile.global());
    }
    if (!routingProfiles.any((r) => r.id == settings.selectedRoutingId)) {
      settings.selectedRoutingId = RoutingProfile.globalPresetId;
    }
  }

  @visibleForTesting
  Future<void> loadForTest() => _load();

  void save() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), saveNow);
  }

  Future<void> saveNow() async {
    _saveTimer?.cancel();
    final data = {
      'settings': settings.toJson(),
      'subscriptions': subscriptions.map((e) => e.toJson()).toList(),
      'servers': servers.map((e) => e.toJson()).toList(),
      'routing': routingProfiles.map((e) => e.toJson()).toList(),
      'apps': appRules.toJson(),
    };
    if (_stateUnreadable) return;
    final text = const JsonEncoder.withIndent('  ').convert(data);
    // Пишем во временный файл и подменяем; если файл занят — несколько попыток, потом прямая запись.
    for (var attempt = 1; attempt <= 10; attempt++) {
      try {
        final tmp = File('${AppPaths.stateFile}.tmp');
        await tmp.writeAsString(text, flush: true);
        await tmp.rename(AppPaths.stateFile);
        return;
      } on FileSystemException catch (e) {
        if (attempt == 10) {
          try {
            await File(AppPaths.stateFile).writeAsString(text, flush: true);
          } catch (_) {
            log.add('app', 'Не удалось сохранить данные: $e');
          }
          return;
        }
        await Future.delayed(const Duration(milliseconds: 150));
      }
    }
  }

  void changed() {
    save();
    notifyListeners();
  }

  /// Уборка своих зависших адаптеров, начатая при запуске (см. [_recoverAfterCrash]).
  Future<void>? _tunCleanup;

  /// Если прошлый запуск упал — вернуть системный прокси и добить процессы ядра.
  Future<void> _recoverAfterCrash() async {
    // Ядра, оставшиеся от прошлого запуска (например, после принудительного закрытия), держат порты.
    for (final pid in WinSys.processesUnder(AppPaths.coreDir.path)) {
      await WinSys.killPid(pid);
    }
    if (settings.systemProxyActive) {
      await WinSys.restoreProxy(settings.previousProxy);
      settings.systemProxyActive = false;
    }
    settings.lastXrayPid = settings.lastSingboxPid = null;
    await saveNow();
    // Свои адаптеры, зависшие после сбоя (ядра уже остановлены выше). В фоне: запуск окна не ждёт,
    // но подключение дождётся конца уборки — иначе она могла бы удалить только что созданный адаптер.
    _tunCleanup = WinSys.removeOwnTunAdapters();
  }

  Future<void> shutdown() async {
    await disconnect();
    await saveNow();
    log.close();
  }

  void toast(String msg) => _messages.add(msg);

  // ---------------------------------------------------------------------------
  // Выборки
  // ---------------------------------------------------------------------------

  ServerProfile? get selectedServer {
    final id = settings.selectedServerId;
    for (final s in servers) {
      if (s.id == id) return s;
    }
    return null;
  }

  RoutingProfile get selectedRouting => routingProfiles.firstWhere(
        (r) => r.id == settings.selectedRoutingId,
        orElse: () => routingProfiles.firstWhere((r) => r.id == RoutingProfile.globalPresetId),
      );

  List<ServerProfile> serversOf(String? subscriptionId) =>
      servers.where((s) => s.subscriptionId == subscriptionId).toList();

  Subscription? subscriptionById(String? id) {
    for (final s in subscriptions) {
      if (s.id == id) return s;
    }
    return null;
  }

  bool get usesTun => settings.mode == ConnectionMode.tun || settings.mode == ConnectionMode.mixed;

  /// TUN поднимает само ядро Xray, sing-box не запускается (пробный режим).
  bool get xrayTun => usesTun && settings.tunCore == TunCore.xray;
  bool get isConnected => status == ConnStatus.connected;
  bool get isBusy => status == ConnStatus.connecting || status == ConnStatus.disconnecting;

  // ---------------------------------------------------------------------------
  // Импорт
  // ---------------------------------------------------------------------------

  /// Ссылки, пришедшие извне (клик по skipit:// на сайте, второй запуск программы). Их не импортируем
  /// молча — окно спрашивает подтверждение: иначе любой сайт мог бы подсунуть свою подписку и сервер.
  final pendingLinks = <String>[];

  Future<void> handleArgs(List<String> args) async {
    final links = [for (final a in args) if (a.contains('://')) a];
    if (links.isEmpty) return;
    pendingLinks.addAll(links);
    notifyListeners();
  }

  /// Ответ пользователя на запрос о внешней ссылке.
  Future<void> resolvePendingLink(String link, {required bool accept}) async {
    pendingLinks.remove(link);
    notifyListeners();
    if (accept) await importText(link);
  }

  /// Вставка из буфера, диплинк или ручной ввод. Возвращает краткий итог.
  Future<String> importText(String text) async {
    final r = LinkParser.parseText(text);
    final parts = <String>[];

    if (r.servers.isNotEmpty) {
      servers.addAll(r.servers);
      settings.selectedServerId ??= r.servers.first.id;
      parts.add('серверов: ${r.servers.length}');
    }
    for (final rd in r.routing) {
      parts.add(_applyRoutingDeeplink(rd));
    }
    for (final url in r.subscriptionUrls) {
      final existing = subscriptions.where((s) => s.url == url).firstOrNull;
      if (existing != null) {
        await updateSubscription(existing);
        parts.add('подписка обновлена');
      } else {
        final sub = Subscription(url: url);
        subscriptions.add(sub);
        await updateSubscription(sub);
        parts.add(sub.error == null ? 'подписка «${sub.displayName}»' : 'подписка с ошибкой: ${sub.error}');
      }
    }
    changed();

    final summary = parts.isEmpty
        ? (r.errors.isNotEmpty ? r.errors.first : 'Ничего не найдено')
        : 'Добавлено: ${parts.join(', ')}${r.errors.isNotEmpty ? ' (ошибок: ${r.errors.length})' : ''}';
    for (final e in r.errors) {
      log.add('import', e);
    }
    toast(summary);
    return summary;
  }

  String _applyRoutingDeeplink(RoutingDeeplink rd, {String? subscriptionId}) {
    if (rd.off) {
      setRouting(RoutingProfile.globalPresetId);
      return 'маршрутизация отключена';
    }
    final p = rd.profile!..subscriptionId = subscriptionId;
    final idx = routingProfiles.indexWhere((e) =>
        (subscriptionId != null && e.subscriptionId == subscriptionId) ||
        (e.name == p.name && !e.id.startsWith('preset-')));
    if (idx >= 0) {
      p.id = routingProfiles[idx].id;
      routingProfiles[idx] = p;
    } else {
      routingProfiles.add(p);
    }
    if (rd.activate || subscriptionId != null) setRouting(p.id);
    return 'маршрутизация «${p.name}»';
  }

  // ---------------------------------------------------------------------------
  // Подписки
  // ---------------------------------------------------------------------------

  Future<void> _updateDueSubscriptions({bool force = false}) async {
    for (final s in List.of(subscriptions)) {
      if (!force && !s.isDue) continue;
      // После неудачи повторяем не чаще раза в 5 минут, а не каждую минуту.
      final failed = _subRetryAfter[s.id];
      if (!force && failed != null && DateTime.now().isBefore(failed)) continue;
      await updateSubscription(s, silent: true);
      if (s.error != null) {
        _subRetryAfter[s.id] = DateTime.now().add(const Duration(minutes: 5));
      } else {
        _subRetryAfter.remove(s.id);
        if (!force) log.add('subscription', '«${s.displayName}» обновлена автоматически');
      }
    }
  }

  final _subRetryAfter = <String, DateTime>{};

  /// Загрузка подписки с общим ограничением по времени: зависший запрос не должен навсегда
  /// блокировать следующие обновления. Если через VPN не получилось — пробуем напрямую.
  Future<FetchedSubscription> _fetchSubscription(Subscription sub) async {
    const limit = Duration(seconds: 45);
    final viaProxy = isConnected && settings.updateViaProxy ? (_session ?? settings).httpPort : null;
    if (viaProxy != null) {
      try {
        return await Net.fetchSubscription(sub.url, settings, proxyPort: viaProxy).timeout(limit);
      } catch (e) {
        log.add('subscription', '${sub.displayName}: через VPN не удалось ($e), пробую напрямую');
      }
    }
    return Net.fetchSubscription(sub.url, settings).timeout(limit);
  }

  Future<void> updateAllSubscriptions() => _updateDueSubscriptions(force: true);

  Future<void> updateSubscription(Subscription sub, {bool silent = false}) async {
    if (!updatingSubs.add(sub.id)) return;
    notifyListeners();
    try {
      final fetched = await _fetchSubscription(sub);
      sub.applyMeta(fetched.meta);
      sub.lastUpdated = DateTime.now();
      sub.error = null;

      final old = {for (final s in serversOf(sub.id)) s.link: s};
      // Если формат сменился (ссылки → JSON), ссылки не совпадут — узнаём сервер по названию,
      // чтобы не сбросить выбор и замеры задержки.
      final oldByName = {for (final s in serversOf(sub.id)) s.name: s};
      final fresh = <ServerProfile>[];
      for (final s in fetched.result.servers) {
        final prev = old[s.link] ?? oldByName[s.name];
        fresh.add(prev == null
            ? (s..subscriptionId = sub.id)
            : ServerProfile(
                id: prev.id,
                name: s.name,
                protocol: s.protocol,
                address: s.address,
                port: s.port,
                link: s.link,
                outbound: s.outbound,
                subscriptionId: sub.id,
                delayMs: prev.delayMs,
                warning: s.warning,
              ));
      }
      if (fresh.isEmpty && fetched.result.servers.isEmpty) {
        sub.error = fetched.result.errors.isNotEmpty ? fetched.result.errors.first : 'Подписка пуста';
      } else {
        final insertAt = servers.indexWhere((s) => s.subscriptionId == sub.id);
        servers.removeWhere((s) => s.subscriptionId == sub.id);
        servers.insertAll(insertAt < 0 ? servers.length : insertAt, fresh);
        if (selectedServer == null && fresh.isNotEmpty) settings.selectedServerId = fresh.first.id;
      }

      // Провайдер может прислать профиль маршрутизации заголовком `routing`.
      final routingLink = fetched.meta['routing'];
      if (routingLink != null && RoutingProfile.isDeeplink(routingLink)) {
        final rd = RoutingProfile.parseDeeplink(routingLink);
        if (rd != null) _applyRoutingDeeplink(rd, subscriptionId: sub.id);
      }
      if (!silent) toast('Подписка «${sub.displayName}» обновлена — серверов: ${fresh.length}');
    } catch (e) {
      sub.error = describeNetError(e);
      log.add('subscription', '${sub.displayName}: $e');
      if (!silent) toast('Не удалось обновить «${sub.displayName}»: ${sub.error}');
    } finally {
      updatingSubs.remove(sub.id);
      changed();
    }
  }

  void deleteSubscription(Subscription sub) {
    subscriptions.remove(sub);
    servers.removeWhere((s) => s.subscriptionId == sub.id);
    routingProfiles.removeWhere((r) => r.subscriptionId == sub.id);
    if (selectedServer == null) settings.selectedServerId = servers.firstOrNull?.id;
    changed();
  }

  void deleteServer(ServerProfile s) {
    servers.remove(s);
    if (settings.selectedServerId == s.id) settings.selectedServerId = servers.firstOrNull?.id;
    changed();
  }

  // ---------------------------------------------------------------------------
  // Пинг
  // ---------------------------------------------------------------------------

  Future<void> ping(List<ServerProfile> list) async {
    if (pinging || list.isEmpty) return;
    pinging = true;
    for (final s in list) {
      s.delayMs = null;
    }
    notifyListeners();
    void onResult(ServerProfile s, int ms) {
      s.delayMs = ms;
      notifyListeners();
    }

    try {
      if (settings.pingType == PingType.tcp) {
        await Pinger.tcpAll(list, onResult);
      } else {
        await Pinger.realDelayAll(list, settings.testUrl, log, onResult);
      }
    } catch (e) {
      toast('Ошибка проверки: $e');
    } finally {
      pinging = false;
      changed();
    }
  }

  ServerProfile? bestOf(List<ServerProfile> list) {
    final ok = list.where((s) => (s.delayMs ?? -1) > 0).toList()
      ..sort((a, b) => a.delayMs!.compareTo(b.delayMs!));
    return ok.firstOrNull;
  }

  // ---------------------------------------------------------------------------
  // Подключение
  // ---------------------------------------------------------------------------

  Future<void> selectServer(String id) async {
    settings.selectedServerId = id;
    changed();
    if (isConnected) await reconnect();
  }

  void setRouting(String id) {
    settings.selectedRoutingId = id;
    changed();
    if (isConnected) unawaited(reconnect());
  }

  Future<void> setMode(ConnectionMode mode) async {
    settings.mode = mode;
    changed();
    if (isConnected) await reconnect();
  }

  /// Смена ядра TUN с главной: как и смена режима, сразу переподключает, если TUN сейчас работает.
  Future<void> setTunCore(TunCore core) async {
    if (settings.tunCore == core) return;
    settings.tunCore = core;
    changed();
    if (isConnected && usesTun) await reconnect();
  }

  Future<void> toggle({bool ignoreOtherVpn = false}) async {
    if (isBusy) return;
    isConnected ? await disconnect() : await connect(ignoreOtherVpn: ignoreOtherVpn);
  }

  Future<void> reconnect() async {
    await disconnect(keepError: true);
    await connect();
  }

  /// Правила по приложениям, с которыми поднят текущий TUN (null — TUN не запущен).
  String? _appliedAppRules;

  /// Правила по приложениям в окне отличаются от тех, что сейчас действуют: нужно переподключение.
  /// Считается сравнением, а не флажком «что-то трогали»: вернули всё как было или переподключились
  /// любым способом — и просьба применить исчезает сама.
  bool get appRulesPending => _appliedAppRules != null && _appliedAppRules != appRules.signature;

  /// Настройки текущего подключения: те же, что в [settings], но с реально занятыми портами
  /// (если порт из настроек держит другая программа, берётся свободный).
  AppSettings? _session;

  /// Свободен ли локальный порт (его никто не слушает).
  static Future<bool> _portFree(int port) async {
    try {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await s.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Порт для подключения: из настроек, а если он занят — ближайший свободный.
  /// В режиме «Только порты» порты видит пользователь, поэтому там занятый порт — ошибка.
  Future<int> _pickPort(int preferred, Set<int> taken, String what) async {
    if (!taken.contains(preferred) && await _portFree(preferred)) return preferred;
    if (settings.mode == ConnectionMode.proxyOnly) {
      throw CoreException('Порт $preferred ($what) уже занят другой программой — например, другим VPN-клиентом. '
          'Закройте её или смените порт в Настройки → Дополнительно.');
    }
    for (var p = preferred + 1000; p < preferred + 1100; p++) {
      if (!taken.contains(p) && await _portFree(p)) {
        log.add('app', 'Порт $preferred ($what) занят другой программой, использую $p');
        return p;
      }
    }
    throw CoreException('Не нашлось свободного порта для $what');
  }

  /// Другие подключённые VPN, которые помешают (проверяется перед подключением).
  /// В режиме «Только порты» система не меняется — там мешать нечему.
  List<VpnConflict> findVpnConflicts() =>
      settings.mode == ConnectionMode.proxyOnly ? const [] : WinSys.vpnConflicts();

  /// Закрывает мешающие VPN по выбору пользователя.
  Future<void> closeVpnConflicts(List<VpnConflict> conflicts) async {
    log.add('app', 'Закрываю мешающие VPN: ${conflicts.map((c) => c.name).join(', ')}');
    await WinSys.closeVpnConflicts(conflicts);
  }

  /// Подключение попросили не из окна (значок в трее), а нужен вопрос пользователю —
  /// окно увидит этот флаг и само проведёт проверку с диалогом.
  bool connectRequested = false;

  void requestConnect() {
    connectRequested = true;
    notifyListeners();
  }

  /// [ignoreOtherVpn] — пользователь уже предупреждён о другом VPN и решил подключаться всё равно.
  Future<void> connect({bool ignoreOtherVpn = false}) async {
    if (isBusy || isConnected) return;
    lastError = null;
    tunFailed = false;
    status = ConnStatus.connecting;
    notifyListeners();
    // Каждое подключение — отдельный отрезок журнала (раздел «Логи»).
    log.startSession(selectedServer?.name ?? 'Сервер не выбран', detail: xrayTun ? '${settings.mode.label} · Xray' : settings.mode.label);
    log.add('app', 'Подключение…');
    try {
      if (usesTun && !isAdmin) throw NeedAdminException();

      // Два VPN с TUN одновременно дерутся за маршруты — сеть ломается до перезагрузки.
      if (usesTun && !ignoreOtherVpn) {
        final other = WinSys.otherVpnAdapters();
        if (other.isNotEmpty) {
          throw CoreException('Включён другой VPN (${other.join(', ')}). Отключите его и подключитесь снова — '
              'два VPN одновременно мешают друг другу и ломают сеть.');
        }
      }

      if (settings.autoSelect && selectedServer != null) {
        final group = serversOf(selectedServer!.subscriptionId);
        await ping(group);
        final best = bestOf(group);
        if (best != null) settings.selectedServerId = best.id;
      }
      final server = selectedServer;
      if (server == null) throw CoreException('Сначала добавьте и выберите сервер');

      final routing = selectedRouting;
      // У серверов с JSON-конфигом провайдера действуют его правила, профиль не применяется.
      final provider = XrayConfig.providerConfig(server);
      if (provider != null) {
        if (XrayConfig.configNeedsGeoFiles(provider)) await _ensureGeoFiles(routing, force: true);
      } else {
        await _ensureGeoFiles(routing);
      }

      // Порты проверяются ДО запуска: иначе «порт открыт» мог бы означать чужую программу
      // (например, Happ на тех же 10808/10809), а не наш Xray.
      final session = AppSettings.fromJson(settings.toJson());
      final taken = <int>{};
      session.socksPort = await _pickPort(settings.socksPort, taken, 'SOCKS');
      taken.add(session.socksPort);
      session.httpPort = await _pickPort(settings.httpPort, taken, 'HTTP');
      taken.add(session.httpPort);
      session.apiPort = await _pickPort(settings.apiPort, taken, 'статистика');
      _session = session;

      final config = XrayConfig.build(server: server, routing: routing, settings: session);
      final xrayTun = this.xrayTun;
      if (xrayTun) {
        final domestic = Uri.tryParse(routing.domesticDnsAddress);
        XrayConfig.addTun(config, settings: session, apps: appRules, directDomains: [
          if (domestic != null && domestic.scheme == 'https' && InternetAddress.tryParse(domestic.host) == null)
            domestic.host,
        ]);
        _appliedAppRules = appRules.signature;
        await _tunCleanup;
      }
      await File(AppPaths.configFile).writeAsString(const JsonEncoder.withIndent('  ').convert(config));
      await _xray.start(AppPaths.xrayExe, ['run', '-c', AppPaths.configFile],
          env: {'XRAY_LOCATION_ASSET': AppPaths.geoDir.path});
      settings.lastXrayPid = _xray.pid;
      await saveNow();

      if (!await waitForPort(session.socksPort, alive: () => _xray.running)) {
        throw CoreException('Xray не запустился:\n${log.tail(8, source: 'xray')}');
      }
      // Ядро могло открыть порт и тут же упасть на следующей ошибке конфига — проверяем, что оно живо.
      await Future.delayed(const Duration(milliseconds: 250));
      if (!_xray.running) throw CoreException('Xray завершился сразу после запуска:\n${log.tail(8, source: 'xray')}');

      if (xrayTun) {
        // Адаптер поднимает сам Xray: ждём, пока трафик пойдёт через него.
        final deadline = DateTime.now().add(Duration(seconds: ignoreOtherVpn ? 5 : 12));
        while (_xray.running && !WinSys.ownTunActive() && DateTime.now().isBefore(deadline)) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
        if (!_xray.running || (!ignoreOtherVpn && !WinSys.ownTunActive())) {
          tunFailed = true;
          throw CoreException(_tunFailure('xray'));
        }
      } else if (usesTun) {
        final domains = <String>[
          if (InternetAddress.tryParse(server.address) == null && server.address.isNotEmpty) server.address,
        ];
        _appliedAppRules = appRules.signature;
        await _tunCleanup;
        final tun = SingboxConfig.build(settings: session, routing: routing, apps: appRules, serverDomains: domains);
        await File(AppPaths.tunConfigFile).writeAsString(const JsonEncoder.withIndent('  ').convert(tun));
        final logStart = log.lines.length;
        await _singbox.start(AppPaths.singboxExe, ['run', '-c', AppPaths.tunConfigFile]);
        settings.lastSingboxPid = _singbox.pid;
        // «Подключено» сообщаем, только когда трафик действительно пошёл через наш адаптер. Обычно это
        // доли секунды. Если Windows не может включить адаптер, sing-box через 10 секунд пишет об этом
        // предупреждение — дальше не ждём и сразу сообщаем об ошибке, а не держим человека минуту.
        // (Если пользователь решил подключаться при чужом VPN, маршрут может остаться за тем VPN —
        // тогда достаточно, что sing-box жив.)
        final deadline = DateTime.now().add(Duration(seconds: ignoreOtherVpn ? 5 : 12));
        bool stuck() => log.lines.skip(logStart).any((l) => l.source == 'sing-box' && _adapterTrouble(l.text));
        while (_singbox.running && !WinSys.ownTunActive() && !stuck() && DateTime.now().isBefore(deadline)) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
        if (!_singbox.running || stuck() || (!ignoreOtherVpn && !WinSys.ownTunActive())) {
          tunFailed = true;
          throw CoreException(_tunFailure('sing-box'));
        }
      }
      if (settings.mode == ConnectionMode.systemProxy || settings.mode == ConnectionMode.mixed) {
        if (!settings.systemProxyActive) settings.previousProxy = await WinSys.readProxy();
        await WinSys.setProxy('127.0.0.1:${session.httpPort}');
        settings.systemProxyActive = true;
      }
      await saveNow();

      status = ConnStatus.connected;
      connectedAt = DateTime.now();
      log.add('app', 'Подключено');
      stats.reset();
      _statsTimer?.cancel();
      _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
        await stats.poll(session.apiPort);
        notifyListeners();
      });
      notifyListeners();
    } catch (e) {
      lastError = e.toString();
      log.add('app', 'Ошибка подключения: $e');
      await _teardown();
      log.endSession();
      status = ConnStatus.disconnected;
      notifyListeners();
      if (e is NeedAdminException) rethrow;
    }
  }

  /// sing-box сообщает, что Windows не отдаёт ему сетевой адаптер.
  static bool _adapterTrouble(String line) {
    final l = line.toLowerCase();
    return l.contains('configure tun interface') || l.contains('open interface take too much time');
  }

  /// Последняя ошибка — не поднялся адаптер TUN: на главной предлагается режим «Прокси».
  bool tunFailed = false;

  /// Скрыть сообщение об ошибке на главной (крестик или истёкшее время показа).
  void clearError() {
    if (lastError == null) return;
    lastError = null;
    tunFailed = false;
    notifyListeners();
  }

  /// Понятное объяснение, почему не поднялся TUN, по последним строкам ядра, которое его поднимает.
  String _tunFailure(String core) {
    final tail = log.tail(8, source: core);
    final lower = tail.toLowerCase();
    if (_adapterTrouble(lower) || tail.trim().isEmpty) {
      return 'Windows не смогла включить сетевой адаптер VPN — это сбой на стороне Windows, не настроек. '
          'Обычно помогает перезагрузка компьютера. Прямо сейчас можно подключиться в режиме «Прокси»: '
          'он работает без адаптера.';
    }
    if (lower.contains('access is denied')) {
      return 'Windows не разрешила создать сетевой адаптер VPN — запустите SkipIt от имени администратора.';
    }
    return 'Не удалось поднять TUN:\n$tail';
  }

  Future<void> disconnect({bool keepError = false}) async {
    if (status == ConnStatus.disconnected) return;
    status = ConnStatus.disconnecting;
    notifyListeners();
    await _teardown();
    log.add('app', 'Отключено');
    log.endSession();
    if (!keepError) lastError = null;
    status = ConnStatus.disconnected;
    connectedAt = null;
    notifyListeners();
  }

  Future<void> _teardown() async {
    _statsTimer?.cancel();
    _statsTimer = null;
    if (settings.systemProxyActive) {
      await WinSys.restoreProxy(settings.previousProxy);
      settings.systemProxyActive = false;
    }
    await _singbox.stop();
    await _xray.stop();
    _session = null;
    _appliedAppRules = null;
    settings.lastXrayPid = settings.lastSingboxPid = null;
    await saveNow();
  }

  /// Ядро завершилось само. Сначала сразу отключаемся — иначе TUN продолжает перехватывать трафик
  /// и отправлять его в пустоту, и у пользователя пропадает интернет. Переподключаемся не больше
  /// одного раза за 5 минут и только если ядро успело нормально поработать: частые падения
  /// обычно значат, что его закрывает другая программа, и повторы лишь дёргают сеть.
  void _onCoreCrash(int code) {
    if (status != ConnStatus.connected) return;
    final now = DateTime.now();
    final uptime = connectedAt == null ? Duration.zero : now.difference(connectedAt!);
    _crashTimes
      ..add(now)
      ..removeWhere((t) => now.difference(t) > const Duration(minutes: 5));
    final retry = settings.autoReconnect && _crashTimes.length <= 1 && uptime > const Duration(seconds: 30);
    log.add('app', 'Ядро завершилось (код $code) через ${uptime.inSeconds} с работы${retry ? ', переподключаюсь' : ''}');
    unawaited(() async {
      await disconnect(keepError: true);
      if (retry) {
        await Future.delayed(const Duration(seconds: 3));
        await connect();
      } else {
        lastError = 'Ядро VPN неожиданно закрылось, подключение остановлено. Если запущен другой VPN-клиент '
            '(например, Happ) — закройте его: он может закрывать ядро SkipIt.';
        notifyListeners();
      }
    }());
  }

  Future<void> _ensureGeoFiles(RoutingProfile routing, {bool force = false}) async {
    if (!force && !XrayConfig.needsGeoFiles(routing)) return;
    if (File(AppPaths.geoipFile).existsSync() && File(AppPaths.geositeFile).existsSync()) return;
    await updateGeoFiles(routing);
  }

  bool updatingGeo = false;

  Future<void> updateGeoFiles([RoutingProfile? routing]) async {
    final r = routing ?? selectedRouting;
    updatingGeo = true;
    notifyListeners();
    try {
      final proxy = isConnected ? (_session ?? settings).httpPort : null;
      log.add('app', 'Загрузка geoip/geosite…');
      await Net.download(r.geoipUrl, AppPaths.geoipFile, proxyPort: proxy);
      await Net.download(r.geositeUrl, AppPaths.geositeFile, proxyPort: proxy);
      log.add('app', 'Геофайлы обновлены');
    } finally {
      updatingGeo = false;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // Версии и обновления
  // ---------------------------------------------------------------------------

  /// Версии вложенных ядер: CoreSpec.name → версия (null — ядро не найдено). Только для показа:
  /// ядра обновляются вместе с программой, сама она их не скачивает.
  final coreVersions = <String, String?>{};

  /// Найденная новая версия SkipIt (null — обновлений нет или ещё не проверяли).
  Release? appUpdate;
  bool checkingUpdates = false;
  DateTime? lastUpdateCheck;

  Future<void> detectCoreVersions() async {
    for (final core in CoreSpec.all) {
      coreVersions[core.name] = await Updates.installedVersion(core);
    }
    notifyListeners();
  }

  int? get _updateProxy => isConnected ? (_session ?? settings).httpPort : null;

  /// [silent] — фоновая проверка при запуске: сообщает только о найденном обновлении.
  Future<void> checkUpdates({bool silent = false}) async {
    if (checkingUpdates) return;
    // Тестовая сборка не обновляется из релизов: установщик заменил бы установленную программу.
    if (AppPaths.isDev || appRepo.isEmpty) {
      if (!silent) toast('Тестовая сборка не обновляется из релизов');
      return;
    }
    checkingUpdates = true;
    appUpdate = null;
    notifyListeners();
    try {
      final r = await Updates.latest(appRepo,
          proxyPort: _updateProxy, prerelease: settings.updateChannel == UpdateChannel.beta);
      // Релиз без установщика — значит, GitHub его ещё собирает: не предлагаем, пока не будет готов.
      if (Updates.compare(r.version, appVersion) > 0 && await Updates.hasInstaller(r, proxyPort: _updateProxy)) {
        appUpdate = r;
      }
      lastUpdateCheck = DateTime.now();
      if (appUpdate != null) {
        toast('Доступна новая версия SkipIt: ${appUpdate!.version}');
      } else if (!silent) {
        toast('У вас последняя версия');
      }
    } catch (e) {
      log.add('update', 'Проверка обновлений: $e');
      if (!silent) {
        toast(e is UpdateLimitedException ? '$e' : 'Не удалось проверить обновления: ${describeNetError(e)}');
      }
    } finally {
      checkingUpdates = false;
      notifyListeners();
    }
  }

  bool downloadingAppUpdate = false;

  /// Скачивает установщик новой версии SkipIt из релиза на GitHub и сверяет его контрольную сумму.
  Future<String?> downloadAppUpdate() async {
    final release = appUpdate;
    if (release == null || downloadingAppUpdate) return null;
    downloadingAppUpdate = true;
    notifyListeners();
    try {
      // Программа обычно работает с правами администратора и запускает установщик с ними же. Поэтому
      // качаем его не во временную папку пользователя (там файл успела бы подменить любая программа),
      // а в папку рядом с программой: в Program Files писать могут только администраторы.
      var dir = Directory.systemTemp;
      if (isAdmin) {
        try {
          final own = Directory('${File(AppPaths.exe).parent.path}\\update');
          await own.create(recursive: true);
          dir = own;
        } catch (_) {}
      }
      final path = '${dir.path}\\${release.installerName}';
      await Net.download(release.installerUrl, path, proxyPort: _updateProxy);
      // Запускаем только то, что совпало с контрольной суммой из релиза.
      final expected = await Updates.expectedSha256(release, proxyPort: _updateProxy);
      await Updates.verify(path, expected);
      log.add('update', 'Скачан установщик ${release.version}${expected != null ? ', контрольная сумма совпала' : ''}');
      return path;
    } finally {
      downloadingAppUpdate = false;
      notifyListeners();
    }
  }

  Future<void> setAutostart(bool v) async {
    await WinSys.setAutostart(v);
    autostart = v;
    notifyListeners();
  }

  @override
  void dispose() {
    _subsTimer?.cancel();
    _statsTimer?.cancel();
    _messages.close();
    super.dispose();
  }
}
