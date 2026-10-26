/// Mutable mirror of the core's settings document (internal/settings). Edited
/// by the Settings screen and sent back as JSON with applySettings.
class Category {
  String name;
  List<String> extensions;
  String dir;
  Category({required this.name, required this.extensions, required this.dir});
  factory Category.fromJson(Map<String, dynamic> j) => Category(
        name: j['name'] as String? ?? '',
        extensions: ((j['extensions'] as List?) ?? const []).map((e) => e.toString()).toList(),
        dir: j['dir'] as String? ?? '',
      );
  Map<String, dynamic> toJson() => {'name': name, 'extensions': extensions, 'dir': dir};
}

class SiteRule {
  String host;
  String dir;
  SiteRule({required this.host, required this.dir});
  factory SiteRule.fromJson(Map<String, dynamic> j) =>
      SiteRule(host: j['host'] as String? ?? '', dir: j['dir'] as String? ?? '');
  Map<String, dynamic> toJson() => {'host': host, 'dir': dir};
}

class TimeWindow {
  List<int> days; // 0 = Sunday; empty = every day
  String from; // HH:MM
  String to; // HH:MM
  TimeWindow({List<int>? days, this.from = '22:00', this.to = '06:00'}) : days = days ?? [];
  static List<int> _days(dynamic v) => ((v as List?) ?? const []).map((e) => (e as num).toInt()).toList();
  factory TimeWindow.fromJson(Map<String, dynamic> j) =>
      TimeWindow(days: _days(j['days']), from: j['from'] as String? ?? '22:00', to: j['to'] as String? ?? '06:00');
  Map<String, dynamic> toJson() => {'days': days, 'from': from, 'to': to};
}

class LimitWindow {
  TimeWindow window;
  int bytesPerSec;
  LimitWindow({required this.window, this.bytesPerSec = 0});
  factory LimitWindow.fromJson(Map<String, dynamic> j) =>
      LimitWindow(window: TimeWindow.fromJson(j), bytesPerSec: (j['bytesPerSec'] as num?)?.toInt() ?? 0);
  Map<String, dynamic> toJson() => {...window.toJson(), 'bytesPerSec': bytesPerSec};
}

class Recurring {
  String id;
  String url;
  String dir;
  String every; // hourly | daily | weekly
  DateTime nextAt;
  bool enabled;
  Recurring({this.id = '', required this.url, this.dir = '', this.every = 'daily', DateTime? nextAt, this.enabled = true})
      : nextAt = nextAt ?? DateTime.now().add(const Duration(days: 1));
  factory Recurring.fromJson(Map<String, dynamic> j) => Recurring(
        id: j['id'] as String? ?? '',
        url: j['url'] as String? ?? '',
        dir: j['dir'] as String? ?? '',
        every: j['every'] as String? ?? 'daily',
        nextAt: DateTime.tryParse(j['nextAt'] as String? ?? '')?.toLocal(),
        enabled: j['enabled'] as bool? ?? true,
      );
  Map<String, dynamic> toJson() => {
        'id': id, 'url': url, 'dir': dir, 'every': every,
        'nextAt': nextAt.toUtc().toIso8601String(), 'enabled': enabled,
      };
}

class AppSettings {
  String downloadDir;
  bool organizeByCategory;
  List<Category> categories;
  List<SiteRule> siteRules;
  int limitBytesPerSec;
  List<LimitWindow> limitWindows;
  bool queueWindowEnabled;
  TimeWindow queueWindow;
  List<Recurring> recurring;
  int maxConcurrent;
  int defaultConns;

  AppSettings({
    required this.downloadDir,
    required this.organizeByCategory,
    required this.categories,
    required this.siteRules,
    required this.limitBytesPerSec,
    required this.limitWindows,
    required this.queueWindowEnabled,
    required this.queueWindow,
    required this.recurring,
    required this.maxConcurrent,
    this.defaultConns = 8,
  });

  factory AppSettings.fromJson(Map<String, dynamic> j) {
    final limits = (j['limits'] as Map<String, dynamic>?) ?? const {};
    final qw = (j['queueWindow'] as Map<String, dynamic>?) ?? const {};
    return AppSettings(
      downloadDir: j['downloadDir'] as String? ?? '',
      organizeByCategory: j['organizeByCategory'] as bool? ?? false,
      categories: ((j['categories'] as List?) ?? const []).map((e) => Category.fromJson(e as Map<String, dynamic>)).toList(),
      siteRules: ((j['siteRules'] as List?) ?? const []).map((e) => SiteRule.fromJson(e as Map<String, dynamic>)).toList(),
      limitBytesPerSec: (limits['bytesPerSec'] as num?)?.toInt() ?? 0,
      limitWindows: ((limits['windows'] as List?) ?? const []).map((e) => LimitWindow.fromJson(e as Map<String, dynamic>)).toList(),
      queueWindowEnabled: qw['enabled'] as bool? ?? false,
      queueWindow: TimeWindow.fromJson(qw),
      recurring: ((j['recurring'] as List?) ?? const []).map((e) => Recurring.fromJson(e as Map<String, dynamic>)).toList(),
      maxConcurrent: (j['maxConcurrent'] as num?)?.toInt() ?? 3,
      defaultConns: (j['defaultConns'] as num?)?.toInt() ?? 8,
    );
  }

  Map<String, dynamic> toJson() => {
        'downloadDir': downloadDir,
        'organizeByCategory': organizeByCategory,
        'categories': categories.map((c) => c.toJson()).toList(),
        'siteRules': siteRules.map((r) => r.toJson()).toList(),
        'limits': {'bytesPerSec': limitBytesPerSec, 'windows': limitWindows.map((w) => w.toJson()).toList()},
        'queueWindow': {'enabled': queueWindowEnabled, ...queueWindow.toJson()},
        'recurring': recurring.map((r) => r.toJson()).toList(),
        'maxConcurrent': maxConcurrent,
        'defaultConns': defaultConns,
      };
}
