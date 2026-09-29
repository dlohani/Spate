/// One download as reported by the core's status JSON:
/// [{"id","url","out","state","priority","bytes","total","retries","error"}].
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
  });

  /// Pending and waiting for a scheduled time in the future.
  bool get isScheduled => state == 'pending' && startAt != null && startAt!.isAfter(DateTime.now());

  factory JobStatus.fromJson(Map<String, dynamic> j) => JobStatus(
        id: j['id'] as String? ?? '',
        url: j['url'] as String? ?? '',
        out: j['out'] as String? ?? '',
        state: j['state'] as String? ?? 'pending',
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
        total: (j['total'] as num?)?.toInt() ?? 0,
        retries: (j['retries'] as num?)?.toInt() ?? 0,
        error: j['error'] as String?,
        startAt: (j['startAt'] as num?) != null && (j['startAt'] as num) > 0
            ? DateTime.fromMillisecondsSinceEpoch((j['startAt'] as num).toInt() * 1000)
            : null,
      );

  String get filename {
    final i = out.lastIndexOf('/');
    final name = i >= 0 ? out.substring(i + 1) : out;
    return name.isEmpty ? 'download' : name;
  }

  String get host => Uri.tryParse(url)?.host ?? '';

  double get fraction => total > 0 ? (bytes / total).clamp(0.0, 1.0) : 0.0;

  bool get isActive => state == 'running' || state == 'pending';
  bool get isTerminal => state == 'done' || state == 'failed' || state == 'cancelled';
}

String humanBytes(int n) {
  const unit = 1024;
  if (n < unit) return '$n B';
  var v = n.toDouble();
  const suffix = ['KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
  var i = -1;
  while (v >= unit && i < suffix.length - 1) {
    v /= unit;
    i++;
  }
  return '${v.toStringAsFixed(1)} ${suffix[i]}';
}

String humanEta(double seconds) {
  if (!seconds.isFinite || seconds < 0) return '--';
  final s = seconds.round();
  if (s < 60) return '${s}s';
  if (s < 3600) return '${s ~/ 60}m ${s % 60}s';
  return '${s ~/ 3600}h ${(s % 3600) ~/ 60}m';
}
