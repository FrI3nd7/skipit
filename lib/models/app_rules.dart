import '../core/util.dart';

enum AppRoutingMode {
  /// Правила по приложениям не применяются.
  off,

  /// Все приложения через VPN, список — исключения (напрямую / блок / принудительно VPN).
  allExcept,

  /// Через VPN идут только приложения из списка, остальные — напрямую.
  onlySelected,
}

enum AppAction { proxy, direct, block }

class AppEntry {
  AppEntry({
    String? id,
    required this.match,
    required this.label,
    this.action = AppAction.proxy,
    this.enabled = true,
  }) : id = id ?? newId();

  final String id;

  /// Имя процесса без .exe, абсолютный путь или папка (заканчивается на `/`).
  /// Разделители — прямые слэши; в правила sing-box переводится в SingboxConfig.
  String match;
  String label;
  AppAction action;
  bool enabled;

  bool get isFolder => match.endsWith('/');
  bool get isPath => match.contains('/');

  /// Имя процесса: `C:\Apps\Telegram.exe` → `Telegram`.
  static String nameFromPath(String path) {
    final file = path.replaceAll('\\', '/').split('/').last.trim();
    return file.toLowerCase().endsWith('.exe') ? file.substring(0, file.length - 4) : file;
  }

  static String normalizePath(String path) {
    var s = path.trim();
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) s = s.substring(1, s.length - 1);
    return s.replaceAll('\\', '/');
  }

  /// Папка версии у программ, которые обновляются сами (Discord, Slack, Figma и другие): `app-1.0.9260`.
  static final _versionDir = RegExp(r'^app-\d+(\.\d+)+$', caseSensitive: false);

  /// Правило для программы, выбранной по её exe. Обычно это путь к файлу. Но у программ, которые
  /// обновляются сами, exe лежит в папке версии, и после обновления путь меняется — правило перестало
  /// бы совпадать, а программа молча пошла бы мимо него. Для них берётся папка программы целиком
  /// (`…/Discord/app-1.0.9260/Discord.exe` → `…/Discord/`): она не меняется и включает помощников.
  static String matchForExe(String path) {
    final s = normalizePath(path);
    final parts = s.split('/');
    final i = parts.indexWhere(_versionDir.hasMatch);
    return i > 0 ? '${parts.take(i).join('/')}/' : s;
  }

  static String normalizeFolder(String path) {
    final s = normalizePath(path);
    return s.endsWith('/') ? s : '$s/';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'match': match,
        'label': label,
        'action': action.name,
        'enabled': enabled,
      };

  factory AppEntry.fromJson(Map<String, dynamic> j) => AppEntry(
        id: j['id'] as String?,
        match: j['match'] as String? ?? '',
        label: j['label'] as String? ?? '',
        action: AppAction.values.asNameMap()[j['action']] ?? AppAction.proxy,
        enabled: parseBool(j['enabled'], true),
      );
}

class AppRules {
  AppRules({this.mode = AppRoutingMode.off, List<AppEntry>? entries}) : entries = entries ?? [];

  AppRoutingMode mode;
  final List<AppEntry> entries;

  /// Все включённые программы списка — смысл списка задаёт режим ([mode]).
  List<String> get enabledMatches =>
      entries.where((e) => e.enabled && e.match.isNotEmpty).map((e) => e.match).toSet().toList();

  /// «Отпечаток» правил в том виде, как они действуют на трафик: режим и включённые программы.
  /// По нему видно, отличаются ли правила в окне от тех, с которыми VPN сейчас подключён.
  /// Выключенные и переименованные записи на него не влияют, а при режиме «Выключено» список не важен.
  String get signature =>
      mode == AppRoutingMode.off ? 'off' : '${mode.name}|${(enabledMatches.map((m) => m.toLowerCase()).toList()..sort()).join('|')}';

  List<String> matchesFor(AppAction action) => entries
      .where((e) => e.enabled && e.action == action && e.match.isNotEmpty)
      .map((e) => e.match)
      .toSet()
      .toList();

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'entries': entries.map((e) => e.toJson()).toList(),
      };

  factory AppRules.fromJson(Map<String, dynamic> j) {
    final entries = <AppEntry>[];
    for (final e in ((j['entries'] as List?) ?? const []).whereType<Map<String, dynamic>>().map(AppEntry.fromJson)) {
      // Записи прежних версий с путём в папку версии (см. [AppEntry.matchForExe]) переводятся на папку
      // программы; получившиеся повторы (сама программа и её помощник) сливаются в одну запись.
      if (e.isPath && !e.isFolder) e.match = AppEntry.matchForExe(e.match);
      if (entries.every((x) => x.match.toLowerCase() != e.match.toLowerCase())) entries.add(e);
    }
    return AppRules(mode: AppRoutingMode.values.asNameMap()[j['mode']] ?? AppRoutingMode.off, entries: entries);
  }
}
