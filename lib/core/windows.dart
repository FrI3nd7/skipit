import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'paths.dart';

const _internetSettingsKey =
    r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
String get _runValue => AppPaths.appName;
const urlScheme = 'skipit';

/// Состояние системного прокси до подключения — чтобы вернуть как было.
class SystemProxyState {
  SystemProxyState({required this.enabled, this.server = '', this.override = ''});

  final bool enabled;
  final String server;
  final String override;

  Map<String, dynamic> toJson() =>
      {'enabled': enabled, 'server': server, 'override': override};

  factory SystemProxyState.fromJson(Map<String, dynamic> j) => SystemProxyState(
        enabled: j['enabled'] == true,
        server: j['server'] as String? ?? '',
        override: j['override'] as String? ?? '',
      );
}

class WinSys {
  // ---------- права ----------

  static bool isAdmin() {
    try {
      final shell32 = DynamicLibrary.open('shell32.dll');
      final fn = shell32.lookupFunction<Int32 Function(), int Function()>('IsUserAnAdmin');
      return fn() != 0;
    } catch (_) {
      return false;
    }
  }

  /// Перезапуск приложения с UAC. true — пользователь согласился.
  static Future<bool> relaunchAsAdmin(List<String> extraArgs) async {
    final args = ['--elevated', ...extraArgs].map((a) => "'${a.replaceAll("'", "''")}'").join(',');
    final script =
        "Start-Process -FilePath '${AppPaths.exe.replaceAll("'", "''")}' -ArgumentList $args -Verb RunAs";
    final r = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', script]);
    return r.exitCode == 0;
  }

  // ---------- системный прокси ----------

  static Future<String?> _regQuery(String key, String value) async {
    final r = await Process.run('reg', ['query', key, '/v', value]);
    if (r.exitCode != 0) return null;
    for (final line in (r.stdout as String).split(RegExp(r'\r?\n'))) {
      final m = RegExp('^\\s*${RegExp.escape(value)}\\s+REG_\\w+\\s*(.*)\$').firstMatch(line);
      if (m != null) return m.group(1)!.trim();
    }
    return null;
  }

  static Future<void> _regSet(String key, String value, String type, String data) =>
      Process.run('reg', ['add', key, '/v', value, '/t', type, '/d', data, '/f']);

  static Future<void> _regDelete(String key, String value) =>
      Process.run('reg', ['delete', key, '/v', value, '/f']);

  static Future<SystemProxyState> readProxy() async {
    final enable = await _regQuery(_internetSettingsKey, 'ProxyEnable');
    return SystemProxyState(
      enabled: enable != null && enable != '0x0',
      server: await _regQuery(_internetSettingsKey, 'ProxyServer') ?? '',
      override: await _regQuery(_internetSettingsKey, 'ProxyOverride') ?? '',
    );
  }

  static Future<void> setProxy(String server) async {
    await _regSet(_internetSettingsKey, 'ProxyServer', 'REG_SZ', server);
    await _regSet(_internetSettingsKey, 'ProxyOverride', 'REG_SZ',
        'localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.2*;172.30.*;172.31.*;192.168.*;<local>');
    await _regSet(_internetSettingsKey, 'ProxyEnable', 'REG_DWORD', '1');
    _refreshInternetSettings();
  }

  static Future<void> restoreProxy(SystemProxyState? prev) async {
    if (prev == null || !prev.enabled) {
      await _regSet(_internetSettingsKey, 'ProxyEnable', 'REG_DWORD', '0');
    } else {
      await _regSet(_internetSettingsKey, 'ProxyEnable', 'REG_DWORD', '1');
    }
    if (prev != null && prev.server.isNotEmpty) {
      await _regSet(_internetSettingsKey, 'ProxyServer', 'REG_SZ', prev.server);
    }
    if (prev != null && prev.override.isNotEmpty) {
      await _regSet(_internetSettingsKey, 'ProxyOverride', 'REG_SZ', prev.override);
    }
    _refreshInternetSettings();
  }

  /// InternetSetOption(SETTINGS_CHANGED / REFRESH), чтобы браузеры сразу подхватили прокси.
  static void _refreshInternetSettings() {
    try {
      final wininet = DynamicLibrary.open('wininet.dll');
      final fn = wininet.lookupFunction<
          Int32 Function(Pointer<Void>, Uint32, Pointer<Void>, Uint32),
          int Function(Pointer<Void>, int, Pointer<Void>, int)>('InternetSetOptionW');
      fn(nullptr, 39, nullptr, 0);
      fn(nullptr, 37, nullptr, 0);
    } catch (_) {}
  }

  // ---------- автозапуск и ссылки ----------

  static Future<bool> isAutostartEnabled() async => await _regQuery(_runKey, _runValue) != null;

  static Future<void> setAutostart(bool enabled) async {
    if (enabled) {
      await _regSet(_runKey, _runValue, 'REG_SZ', '"${AppPaths.exe}" --autostart');
    } else {
      await _regDelete(_runKey, _runValue);
    }
  }

  /// Регистрирует `skipit://` — ссылки вида skipit://add/<url подписки> откроются в приложении.
  static Future<void> registerUrlScheme() async {
    // Тестовая сборка ссылки на себя не переключает — они остаются за установленной программой.
    if (AppPaths.isDev) return;
    final base = 'HKCU\\Software\\Classes\\$urlScheme';
    await _regSet(base, '', 'REG_SZ', 'URL:SkipIt');
    await _regSet(base, 'URL Protocol', 'REG_SZ', '');
    await _regSet('$base\\shell\\open\\command', '', 'REG_SZ', '"${AppPaths.exe}" "%1"');
  }

  // ---------- диалоги и процессы ----------

  static Future<String?> _powershell(String script) async {
    final r = await Process.run(
      'powershell',
      ['-NoProfile', '-STA', '-Command', '[Console]::OutputEncoding=[Text.Encoding]::UTF8; $script'],
      stdoutEncoding: utf8,
    );
    final out = (r.stdout as String).trim();
    return r.exitCode == 0 && out.isNotEmpty ? out : null;
  }

  static Future<String?> pickFile({String filter = 'Все файлы (*.*)|*.*'}) => _powershell(
        'Add-Type -AssemblyName System.Windows.Forms; '
        '\$d = New-Object System.Windows.Forms.OpenFileDialog; '
        "\$d.Filter = '$filter'; "
        "if (\$d.ShowDialog() -eq 'OK') { \$d.FileName }",
      );

  static Future<String?> pickFolder() => _powershell(
        'Add-Type -AssemblyName System.Windows.Forms; '
        '\$d = New-Object System.Windows.Forms.FolderBrowserDialog; '
        "if (\$d.ShowDialog() -eq 'OK') { \$d.SelectedPath }",
      );

  /// Запущенные программы (имя + путь) для выбора в правилах приложений.
  /// Напрямую через WinAPI (EnumProcesses + QueryFullProcessImageName) — мгновенно, без запуска PowerShell.
  /// Системные процессы из папки Windows отфильтрованы: для правил VPN они не нужны.
  static Future<List<({String name, String path})>> runningApps() async {
    final windowsDir = '${(Platform.environment['WINDIR'] ?? r'C:\Windows').toLowerCase()}\\';
    final ownDir = File(AppPaths.exe).parent.path.toLowerCase();
    final byPath = <String, String>{};
    for (final p in _processes()) {
      final lower = p.path.toLowerCase();
      if (!lower.startsWith(windowsDir) && !lower.startsWith(ownDir)) byPath.putIfAbsent(lower, () => p.path);
    }
    final apps = [
      for (final path in byPath.values)
        (name: path.split('\\').last.replaceAll(RegExp(r'\.exe$', caseSensitive: false), ''), path: path),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return apps;
  }

  /// PID процессов, запущенных из папки [dir] (например, зависшие ядра из core).
  static List<int> processesUnder(String dir) {
    final prefix = '${dir.toLowerCase()}\\';
    return [
      for (final p in _processes())
        if (p.path.toLowerCase().startsWith(prefix)) p.pid,
    ];
  }

  /// Все процессы, к которым есть доступ: PID и полный путь к exe.
  static List<({int pid, String path})> _processes() {
    final k32 = DynamicLibrary.open('kernel32.dll');
    final getHeap = k32.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>('GetProcessHeap');
    final heapAlloc = k32.lookupFunction<Pointer<Void> Function(Pointer<Void>, Uint32, IntPtr),
        Pointer<Void> Function(Pointer<Void>, int, int)>('HeapAlloc');
    final heapFree = k32.lookupFunction<Int32 Function(Pointer<Void>, Uint32, Pointer<Void>),
        int Function(Pointer<Void>, int, Pointer<Void>)>('HeapFree');
    final enumProcesses = k32.lookupFunction<Int32 Function(Pointer<Uint32>, Uint32, Pointer<Uint32>),
        int Function(Pointer<Uint32>, int, Pointer<Uint32>)>('K32EnumProcesses');
    final openProcess = k32.lookupFunction<Pointer<Void> Function(Uint32, Int32, Uint32),
        Pointer<Void> Function(int, int, int)>('OpenProcess');
    final queryImageName = k32.lookupFunction<Int32 Function(Pointer<Void>, Uint32, Pointer<Uint16>, Pointer<Uint32>),
        int Function(Pointer<Void>, int, Pointer<Uint16>, Pointer<Uint32>)>('QueryFullProcessImageNameW');
    final closeHandle = k32.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('CloseHandle');

    const heapZeroMemory = 0x8;
    const processQueryLimitedInformation = 0x1000;
    const maxPids = 8192;
    const bufChars = 1024;
    final heap = getHeap();
    final pids = heapAlloc(heap, heapZeroMemory, maxPids * 4).cast<Uint32>();
    final needed = heapAlloc(heap, heapZeroMemory, 4).cast<Uint32>();
    final buf = heapAlloc(heap, heapZeroMemory, bufChars * 2).cast<Uint16>();
    final size = heapAlloc(heap, heapZeroMemory, 4).cast<Uint32>();

    final result = <({int pid, String path})>[];
    try {
      if (enumProcesses(pids, maxPids * 4, needed) == 0) return result;
      for (final pid in pids.asTypedList(needed.value ~/ 4)) {
        if (pid == 0) continue;
        final h = openProcess(processQueryLimitedInformation, 0, pid);
        if (h.address == 0) continue;
        size.value = bufChars;
        if (queryImageName(h, 0, buf, size) != 0) {
          result.add((pid: pid, path: String.fromCharCodes(buf.asTypedList(size.value))));
        }
        closeHandle(h);
      }
    } finally {
      for (final p in [pids.cast<Void>(), needed.cast<Void>(), buf.cast<Void>(), size.cast<Void>()]) {
        heapFree(heap, 0, p);
      }
    }
    return result;
  }
  static Future<void> openUrl(String url) => Process.run('explorer', [url]);

  /// Сетевой адаптер, через который сейчас идёт трафик в интернет (лучший маршрут до 8.8.8.8).
  /// Напрямую через WinAPI (GetBestInterface + GetIfEntry2) — мгновенно, без запуска PowerShell.
  /// null — определить не удалось.
  static ({String alias, String description, int type, bool hardware})? defaultRouteAdapter() {
    try {
      final iphlp = DynamicLibrary.open('iphlpapi.dll');
      final k32 = DynamicLibrary.open('kernel32.dll');
      final getHeap = k32.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>('GetProcessHeap');
      final heapAlloc = k32.lookupFunction<Pointer<Void> Function(Pointer<Void>, Uint32, IntPtr),
          Pointer<Void> Function(Pointer<Void>, int, int)>('HeapAlloc');
      final heapFree = k32.lookupFunction<Int32 Function(Pointer<Void>, Uint32, Pointer<Void>),
          int Function(Pointer<Void>, int, Pointer<Void>)>('HeapFree');
      final getBestInterface = iphlp.lookupFunction<Uint32 Function(Uint32, Pointer<Uint32>),
          int Function(int, Pointer<Uint32>)>('GetBestInterface');
      final getIfEntry2 =
          iphlp.lookupFunction<Uint32 Function(Pointer<Uint8>), int Function(Pointer<Uint8>)>('GetIfEntry2');

      // Раскладка MIB_IF_ROW2: индекс, имя (Alias), описание, тип и флаги адаптера.
      const rowSize = 1352, offIndex = 8, offAlias = 28, offDescription = 542, offType = 1128, offFlags = 1152;
      const nameChars = 257;
      final heap = getHeap();
      final index = heapAlloc(heap, 0x8, 4).cast<Uint32>();
      final row = heapAlloc(heap, 0x8, rowSize).cast<Uint8>();
      try {
        if (getBestInterface(0x08080808, index) != 0) return null;
        (row + offIndex).cast<Uint32>().value = index.value;
        if (getIfEntry2(row) != 0) return null;
        String text(int offset) {
          final chars = (row + offset).cast<Uint16>().asTypedList(nameChars);
          final end = chars.indexOf(0);
          return String.fromCharCodes(end < 0 ? chars : chars.sublist(0, end));
        }

        return (
          alias: text(offAlias),
          description: text(offDescription),
          type: (row + offType).cast<Uint32>().value,
          hardware: (row + offFlags).value & 1 != 0,
        );
      } finally {
        heapFree(heap, 0, index.cast());
        heapFree(heap, 0, row.cast());
      }
    } catch (_) {
      return null;
    }
  }

  /// Другой VPN, который сейчас забирает весь трафик: маршрут в интернет идёт через виртуальный
  /// туннельный адаптер (Wintun, WireGuard, TAP, PPP). Свой адаптер не считается. При любой ошибке —
  /// пустой список: проверка не должна мешать подключению.
  static List<String> otherVpnAdapters() {
    final a = defaultRouteAdapter();
    if (a == null || a.hardware || a.alias == AppPaths.appName) return const [];
    // Типы адаптеров: 23 — PPP, 53 — виртуальный (Wintun/WireGuard), 131 — туннель.
    final tunnel = const {23, 53, 131}.contains(a.type) ||
        RegExp(r'\b(tap|tun|vpn|wintun|wireguard|openvpn)\b', caseSensitive: false).hasMatch(a.description);
    return tunnel ? [a.description.isNotEmpty ? a.description : a.alias] : const [];
  }

  /// Поднялся ли наш TUN-адаптер: трафик в интернет уже идёт через него.
  static bool ownTunActive() => defaultRouteAdapter()?.alias == AppPaths.appName;

  static Future<void> killPid(int pid) async {
    await Process.run('taskkill', ['/F', '/T', '/PID', '$pid']);
  }
}
