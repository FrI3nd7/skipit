import 'dart:io';

class AppPaths {
  static late Directory dataDir;
  static late Directory coreDir;
  static late Directory geoDir;

  static Future<void> init() async {
    final appData =
        Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
    dataDir = Directory('$appData\\SkipIt');
    await dataDir.create(recursive: true);
    geoDir = Directory('${dataDir.path}\\geo');
    await geoDir.create(recursive: true);
    coreDir = _findCoreDir();
  }

  /// Ядра лежат в папке `core` рядом с exe (релиз) или в корне проекта (flutter run).
  static Directory _findCoreDir() {
    final exeDir = File(Platform.resolvedExecutable).parent;
    final candidates = [
      Directory('${exeDir.path}\\core'),
      Directory('${Directory.current.path}\\core'),
    ];
    for (final dir in candidates) {
      if (File('${dir.path}\\skipit-xray.exe').existsSync()) return dir;
    }
    return candidates.first;
  }

  static String get exe => Platform.resolvedExecutable;
  // У ядер свои имена: другие VPN-клиенты (например, Happ) закрывают чужие процессы xray.exe.
  static String get xrayExe => '${coreDir.path}\\skipit-xray.exe';
  static String get singboxExe => '${coreDir.path}\\skipit-sing-box.exe';
  static String get configFile => '${dataDir.path}\\config.json';
  static String get tunConfigFile => '${dataDir.path}\\tun.json';
  static String get testConfigFile => '${dataDir.path}\\test.json';
  static String get stateFile => '${dataDir.path}\\state.json';
  static String get logFile => '${dataDir.path}\\app.log';
  static String get geoipFile => '${geoDir.path}\\geoip.dat';
  static String get geositeFile => '${geoDir.path}\\geosite.dat';
}
