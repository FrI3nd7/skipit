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

  List<String> matchesFor(AppAction action) => entries
      .where((e) => e.enabled && e.action == action && e.match.isNotEmpty)
      .map((e) => e.match)
      .toSet()
      .toList();

  Map<String, dynamic> toJson() => {
        'mode': mode.name,
        'entries': entries.map((e) => e.toJson()).toList(),
      };

  factory AppRules.fromJson(Map<String, dynamic> j) => AppRules(
        mode: AppRoutingMode.values.asNameMap()[j['mode']] ?? AppRoutingMode.off,
        entries: ((j['entries'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(AppEntry.fromJson)
            .toList(),
      );
}
