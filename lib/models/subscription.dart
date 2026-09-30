import '../core/util.dart';

class Subscription {
  Subscription({
    String? id,
    required this.url,
    this.name = '',
    this.lastUpdated,
    this.updateIntervalHours = 12,
    this.upload,
    this.download,
    this.total,
    this.expire,
    this.supportUrl,
    this.webPageUrl,
    this.announce,
    this.error,
    this.expanded = true,
  }) : id = id ?? newId();

  final String id;
  String url;
  String name;
  DateTime? lastUpdated;
  int updateIntervalHours;
  int? upload;
  int? download;
  int? total;
  DateTime? expire;
  String? supportUrl;
  String? webPageUrl;
  String? announce;
  String? error;
  bool expanded;

  String get displayName {
    if (name.isNotEmpty) return name;
    final host = Uri.tryParse(url)?.host ?? '';
    return host.isNotEmpty ? host : url;
  }

  int get used => (upload ?? 0) + (download ?? 0);

  bool get isDue {
    if (updateIntervalHours <= 0) return false;
    final last = lastUpdated;
    return last == null ||
        DateTime.now().difference(last) >= Duration(hours: updateIntervalHours);
  }

  /// Метаданные из HTTP-заголовков или строк `#key: value` в теле (формат Happ).
  void applyMeta(Map<String, String> meta) {
    final title = meta['profile-title'];
    if (title != null && title.trim().isNotEmpty) {
      name = decodeMaybeBase64Prefixed(title);
    }

    final info = meta['subscription-userinfo'];
    if (info != null) {
      upload = download = total = null;
      expire = null;
      for (final part in info.split(RegExp('[;,]'))) {
        final kv = part.split('=');
        if (kv.length != 2) continue;
        final value = asInt(kv[1]);
        switch (kv[0].trim().toLowerCase()) {
          case 'upload':
            upload = value;
          case 'download':
            download = value;
          case 'total':
            total = value;
          case 'expire':
            expire = value != null && value > 0
                ? DateTime.fromMillisecondsSinceEpoch(value * 1000)
                : null;
        }
      }
    }

    final interval = asInt(meta['profile-update-interval']);
    if (interval != null && interval > 0) updateIntervalHours = interval;

    supportUrl = meta['support-url'] ?? supportUrl;
    webPageUrl = meta['profile-web-page-url'] ?? webPageUrl;
    final announceValue = meta['announce'];
    announce = announceValue == null ? null : decodeMaybeBase64Prefixed(announceValue);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'name': name,
        'lastUpdated': lastUpdated?.toIso8601String(),
        'updateIntervalHours': updateIntervalHours,
        'upload': upload,
        'download': download,
        'total': total,
        'expire': expire?.toIso8601String(),
        'supportUrl': supportUrl,
        'webPageUrl': webPageUrl,
        'announce': announce,
        'error': error,
        'expanded': expanded,
      };

  factory Subscription.fromJson(Map<String, dynamic> j) => Subscription(
        id: j['id'] as String?,
        url: j['url'] as String? ?? '',
        name: j['name'] as String? ?? '',
        lastUpdated: DateTime.tryParse(j['lastUpdated'] as String? ?? ''),
        updateIntervalHours: asInt(j['updateIntervalHours']) ?? 12,
        upload: asInt(j['upload']),
        download: asInt(j['download']),
        total: asInt(j['total']),
        expire: DateTime.tryParse(j['expire'] as String? ?? ''),
        supportUrl: j['supportUrl'] as String?,
        webPageUrl: j['webPageUrl'] as String?,
        announce: j['announce'] as String?,
        error: j['error'] as String?,
        expanded: parseBool(j['expanded'], true),
      );
}
