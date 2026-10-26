/// One download as reported by the core's status JSON (job.StatusJSON in Go,
/// the single definition every export uses):
/// [{"id","url","out","state","priority","bytes","total","retries","startAt","finishedAt","error"}].
class JobStatus {
  final String id;
  final String url;
  final String out;
  final String state; // pending | running | paused | done | failed | cancelled
  final int bytes;
  final int total;
  final int retries;
  final String? error;
  final DateTime? startAt; // scheduled start, when set
  final DateTime? finishedAt; // when a finished, failed or cancelled job ended

  const JobStatus({
    required this.id,
    required this.url,
    required this.out,
    required this.state,
    required this.bytes,
    required this.total,
    required this.retries,
    this.error,
    this.startAt,
    this.finishedAt,
  });

  factory JobStatus.fromJson(Map<String, dynamic> j) {
    DateTime? unix(dynamic v) =>
        v is num && v > 0 ? DateTime.fromMillisecondsSinceEpoch(v.toInt() * 1000) : null;
    return JobStatus(
      id: j['id'] as String? ?? '',
      url: j['url'] as String? ?? '',
      out: j['out'] as String? ?? '',
      state: j['state'] as String? ?? 'pending',
      bytes: (j['bytes'] as num?)?.toInt() ?? 0,
      total: (j['total'] as num?)?.toInt() ?? 0,
      retries: (j['retries'] as num?)?.toInt() ?? 0,
      error: j['error'] as String?,
      startAt: unix(j['startAt']),
      finishedAt: unix(j['finishedAt']),
    );
  }

  /// Insertion order: ids are "job-N" from the core.
  int get seq => int.tryParse(id.substring(id.lastIndexOf('-') + 1)) ?? 0;

  /// Pending and waiting for a scheduled time in the future.
  bool get isScheduled => state == 'pending' && startAt != null && startAt!.isAfter(DateTime.now());

  String get filename {
    final i = out.lastIndexOf('/');
    final name = i >= 0 ? out.substring(i + 1) : out;
    return name.isEmpty ? 'download' : name;
  }

  String get host => Uri.tryParse(url)?.host ?? '';

  double get fraction => total > 0 ? (bytes / total).clamp(0.0, 1.0) : 0.0;

  bool get isActive => !isTerminal;
  bool get isTerminal => state == 'done' || state == 'failed' || state == 'cancelled';

  /// List order: what is happening first, then what will happen, then what
  /// did; ties by insertion order.
  int get groupOrder => switch (state) {
    'running' => 0,
    'pending' when isScheduled => 2,
    'pending' => 1,
    'paused' => 3,
    'done' => 4,
    'failed' => 5,
    _ => 6,
  };
}

/// Sorts for the list: running, queued, scheduled, paused, then finished,
/// failed, cancelled; within a group by insertion order.
List<JobStatus> sortedForList(Iterable<JobStatus> jobs) {
  final l = jobs.toList();
  l.sort((a, b) {
    final g = a.groupOrder.compareTo(b.groupOrder);
    if (g != 0) return g;
    // Finished: newest first, so the latest download tops the history.
    if (a.isTerminal && b.isTerminal) return b.seq.compareTo(a.seq);
    return a.seq.compareTo(b.seq);
  });
  return l;
}

/// Decimal units like the browser, Finder and Explorer show them: 1 MB is
/// 1,000,000 bytes. One decimal under 100, none above ("9.6 MB", "148 MB").
String humanBytes(int n) {
  if (n < 1000) return '$n B';
  var v = n.toDouble();
  const suffix = ['kB', 'MB', 'GB', 'TB', 'PB'];
  var i = -1;
  while (v >= 1000 && i < suffix.length - 1) {
    v /= 1000;
    i++;
  }
  return '${v >= 100 ? v.round().toString() : v.toStringAsFixed(1)} ${suffix[i]}';
}

/// "148 of 286 MB": the unit once, on the total.
String humanProgress(int bytes, int total) {
  if (total <= 0) return humanBytes(bytes);
  var v = total.toDouble();
  var d = 1.0;
  const suffix = ['B', 'kB', 'MB', 'GB', 'TB', 'PB'];
  var i = 0;
  while (v >= 1000 && i < suffix.length - 1) {
    v /= 1000;
    d *= 1000;
    i++;
  }
  String f(double x) => x >= 100 || i == 0 ? x.round().toString() : x.toStringAsFixed(1);
  return '${f(bytes / d)} of ${f(v)} ${suffix[i]}';
}

String humanEta(double seconds) {
  if (!seconds.isFinite || seconds < 0) return '';
  final s = seconds.round();
  if (s < 60) return '$s s left';
  if (s < 3600) return '${s ~/ 60} min left';
  return '${s ~/ 3600} h ${(s % 3600) ~/ 60} min left';
}

/// "14:30" for today, "tomorrow 09:00", "Tue 14:30" within a week, else a date.
String fmtWhen(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  final now = DateTime.now();
  final hm = '${two(t.hour)}:${two(t.minute)}';
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final days = day.difference(today).inDays;
  if (days == 0) return hm;
  if (days == 1) return 'tomorrow $hm';
  if (days > 0 && days < 7) {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return '${names[t.weekday - 1]} $hm';
  }
  return '${t.year}-${two(t.month)}-${two(t.day)} $hm';
}

/// "just now", "2 min ago", "3 h ago", "yesterday", else a date.
String fmtAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 45) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  if (d.inDays == 1) return 'yesterday';
  if (d.inDays < 7) return '${d.inDays} days ago';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}';
}

/// "3rd" for a queue position.
String ordinal(int n) {
  if (n % 100 >= 11 && n % 100 <= 13) return '${n}th';
  return switch (n % 10) { 1 => '${n}st', 2 => '${n}nd', 3 => '${n}rd', _ => '${n}th' };
}
