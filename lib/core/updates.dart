import 'dart:convert';
import 'dart:io';

import 'paths.dart';

class Release {
  Release(this.tag, this.pageUrl, this.assets, {this.prerelease = false});
  final String tag;
  final String pageUrl;
  final Map<String, String> assets; // имя файла → ссылка на скачивание
  final bool prerelease;

  static Release fromJson(Map<String, dynamic> j, String repo) => Release(
        j['tag_name'] as String? ?? '',
        j['html_url'] as String? ?? 'https://github.com/$repo/releases',
        {
          for (final a in (j['assets'] as List? ?? const []))
            if (a is Map) '${a['name']}': '${a['browser_download_url']}',
        },
        prerelease: j['prerelease'] == true,
      );

  String get version => tag.startsWith('v') ? tag.substring(1) : tag;

  String? assetMatching(RegExp pattern) {
    for (final e in assets.entries) {
      if (pattern.hasMatch(e.key)) return e.value;
    }
    return null;
  }
}

/// Ядро, которое умеем обновлять: откуда брать релиз и какой архив нужен для Windows x64.
class CoreSpec {
  const CoreSpec(this.name, this.exe, this.repo, this.assetPattern, this.versionPattern);
  final String name;
  final String exe;
  final String repo;
  final String assetPattern;
  final String versionPattern;

  String get path => '${AppPaths.coreDir.path}\\$exe';

  static const xray = CoreSpec('Xray-core', 'xray.exe', 'XTLS/Xray-core', r'^Xray-windows-64\.zip$', r'Xray ([\d.]+)');
  static const singbox = CoreSpec(
      'sing-box', 'sing-box.exe', 'SagerNet/sing-box', r'^sing-box-[\d.]+-windows-amd64\.zip$', r'sing-box version ([\d.]+)');
  static const all = [xray, singbox];
}

class Updates {
  static HttpClient _client(int? proxyPort) {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    if (proxyPort != null) c.findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort';
    return c;
  }

  static Future<Object?> _getJson(String url, int? proxyPort) async {
    final client = _client(proxyPort);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, 'SkipIt-updater');
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final res = await req.close().timeout(const Duration(seconds: 20));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode == 404) throw const HttpException('релизов пока нет');
      if (res.statusCode != 200) throw HttpException('GitHub ответил ${res.statusCode}');
      return jsonDecode(body);
    } finally {
      client.close(force: true);
    }
  }

  /// Последний релиз из раздела Releases. [prerelease] — канал «Бета»: учитываются и пре-релизы
  /// (берётся самая новая версия среди всех опубликованных, черновики пропускаются).
  static Future<Release> latest(String repo, {int? proxyPort, bool prerelease = false}) async {
    if (!prerelease) {
      final j = await _getJson('https://api.github.com/repos/$repo/releases/latest', proxyPort);
      return Release.fromJson(j as Map<String, dynamic>, repo);
    }
    final list = await _getJson('https://api.github.com/repos/$repo/releases?per_page=30', proxyPort) as List;
    final releases = [
      for (final r in list)
        if (r is Map<String, dynamic> && r['draft'] != true) Release.fromJson(r, repo),
    ];
    if (releases.isEmpty) throw const HttpException('релизов пока нет');
    releases.sort((a, b) => compare(b.version, a.version));
    return releases.first;
  }

  /// Версия установленного ядра (`xray version` / `sing-box version`).
  static Future<String?> installedVersion(CoreSpec core) async {
    if (!File(core.path).existsSync()) return null;
    try {
      final r = await Process.run(core.path, ['version'], stdoutEncoding: utf8);
      return RegExp(core.versionPattern).firstMatch(r.stdout as String)?.group(1);
    } catch (_) {
      return null;
    }
  }

  /// Сравнение версий вида 1.2.3, 1.0.0a, v26.3.27: сначала числа, потом буквенный суффикс.
  static int compare(String a, String b) {
    List<int> nums(String v) =>
        RegExp(r'\d+').allMatches(v.split(RegExp(r'[-+]')).first).map((m) => int.parse(m.group(0)!)).toList();
    final x = nums(a), y = nums(b);
    for (var i = 0; i < (x.length > y.length ? x.length : y.length); i++) {
      final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
      if (d != 0) return d.sign;
    }
    String suffix(String v) => RegExp(r'[a-z]+', caseSensitive: false).firstMatch(v.replaceAll(RegExp(r'^v'), ''))?.group(0) ?? '';
    final sa = suffix(a), sb = suffix(b);
    // «1.0.0» новее, чем «1.0.0a» (буква — предварительная версия).
    if (sa.isEmpty && sb.isNotEmpty) return 1;
    if (sa.isNotEmpty && sb.isEmpty) return -1;
    return sa.compareTo(sb).sign;
  }

  /// Скачивает архив ядра, распаковывает и заменяет exe. Ядро должно быть остановлено.
  static Future<void> installCore(CoreSpec core, Release release, {int? proxyPort}) async {
    final url = release.assetMatching(RegExp(core.assetPattern));
    if (url == null) throw Exception('В релизе ${core.name} ${release.tag} нет сборки для Windows x64');
    final tmp = Directory('${Directory.systemTemp.path}\\skipit-update-${DateTime.now().millisecondsSinceEpoch}');
    await tmp.create(recursive: true);
    try {
      final zip = File('${tmp.path}\\core.zip');
      final client = _client(proxyPort);
      try {
        final req = await client.getUrl(Uri.parse(url));
        req.headers.set(HttpHeaders.userAgentHeader, 'SkipIt-updater');
        final res = await req.close();
        if (res.statusCode != 200) throw HttpException('Загрузка ${core.name}: HTTP ${res.statusCode}');
        await res.pipe(zip.openWrite());
      } finally {
        client.close(force: true);
      }
      final out = '${tmp.path}\\x';
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "Expand-Archive -LiteralPath '${zip.path}' -DestinationPath '$out' -Force",
      ]);
      if (r.exitCode != 0) throw Exception('Не удалось распаковать архив ${core.name}');
      final exe = Directory(out)
          .listSync(recursive: true)
          .whereType<File>()
          .firstWhere((f) => f.path.toLowerCase().endsWith('\\${core.exe}'),
              orElse: () => throw Exception('В архиве нет ${core.exe}'));
      await AppPaths.coreDir.create(recursive: true);
      // Старый файл переименовываем, а не удаляем — если копирование сорвётся, его можно вернуть.
      final target = File(core.path);
      final backup = File('${core.path}.old');
      if (backup.existsSync()) await backup.delete();
      if (target.existsSync()) await target.rename(backup.path);
      try {
        await exe.copy(core.path);
      } catch (e) {
        if (backup.existsSync()) await backup.rename(core.path);
        rethrow;
      }
    } finally {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }
}
