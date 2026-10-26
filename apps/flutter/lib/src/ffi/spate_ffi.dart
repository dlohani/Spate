import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../model/job.dart';

// C ABI (see export/cshared/spate.go and dist/libspate.h).
typedef _StartC = LongLong Function(Pointer<Utf8>);
typedef _StartD = int Function(Pointer<Utf8>);
typedef _HandleVoidC = Void Function(LongLong);
typedef _HandleVoidD = void Function(int);
typedef _HandleStrC = Pointer<Utf8> Function(LongLong);
typedef _HandleStrD = Pointer<Utf8> Function(int);
typedef _HandleIntC = Int32 Function(LongLong);
typedef _HandleIntD = int Function(int);
typedef _AddC = Pointer<Utf8> Function(LongLong, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _AddD = Pointer<Utf8> Function(int, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int);
typedef _IdActC = Int32 Function(LongLong, Pointer<Utf8>);
typedef _IdActD = int Function(int, Pointer<Utf8>);
typedef _ResolveC = Void Function(LongLong, Int32);
typedef _ResolveD = void Function(int, int);
typedef _FreeC = Void Function(Pointer<Utf8>);
typedef _FreeD = void Function(Pointer<Utf8>);
typedef _StrActC = Pointer<Utf8> Function(LongLong, Pointer<Utf8>);
typedef _StrActD = Pointer<Utf8> Function(int, Pointer<Utf8>);
typedef _HandleLongC = LongLong Function(LongLong);
typedef _HandleLongD = int Function(int);
typedef _HandleULongC = UnsignedLongLong Function(LongLong);
typedef _HandleULongD = int Function(int);
typedef _StrC = Pointer<Utf8> Function();
typedef _StrD = Pointer<Utf8> Function();

/// A failure reported by the core, with the reason it gave.
class SpateException implements Exception {
  final String message;
  const SpateException(this.message);

  /// True when the core refused to start because another instance answers
  /// on the capture ports (the shell should hand over to it and exit).
  bool get alreadyRunning => message.contains('already running');

  @override
  String toString() => 'SpateException: $message';
}

/// Reads and frees SpateLastError from an opened library.
String _lastErrorOf(DynamicLibrary lib) {
  final f = lib.lookupFunction<_StrC, _StrD>('SpateLastError');
  final free = lib.lookupFunction<_FreeC, _FreeD>('SpateFreeString');
  final p = f();
  try {
    return p.toDartString();
  } finally {
    free(p);
  }
}

/// Thin, synchronous binding to libspate. One instance == one running
/// service (engine + queue + browser-capture endpoint).
class Spate {
  final DynamicLibrary _lib;
  final int _h;

  late final _HandleVoidD _stop = _lib.lookupFunction<_HandleVoidC, _HandleVoidD>('SpateServiceStop');
  late final _HandleStrD _info = _lib.lookupFunction<_HandleStrC, _HandleStrD>('SpateInfoJSON');
  late final _AddD _add = _lib.lookupFunction<_AddC, _AddD>('SpateAdd');
  late final _IdActD _pause = _lib.lookupFunction<_IdActC, _IdActD>('SpatePause');
  late final _IdActD _resume = _lib.lookupFunction<_IdActC, _IdActD>('SpateResume');
  late final _IdActD _cancel = _lib.lookupFunction<_IdActC, _IdActD>('SpateCancel');
  late final _IdActD _remove = _lib.lookupFunction<_IdActC, _IdActD>('SpateRemove');
  late final _IdActD _discard = _lib.lookupFunction<_IdActC, _IdActD>('SpateDiscard');
  late final _HandleIntD _clearFinished = _lib.lookupFunction<_HandleIntC, _HandleIntD>('SpateClearFinished');
  late final _HandleVoidD _cancelAll = _lib.lookupFunction<_HandleVoidC, _HandleVoidD>('SpateCancelAll');
  late final _HandleStrD _status = _lib.lookupFunction<_HandleStrC, _HandleStrD>('SpateStatusJSON');
  late final _HandleIntD _pairPending = _lib.lookupFunction<_HandleIntC, _HandleIntD>('SpatePairPending');
  late final _ResolveD _pairResolve = _lib.lookupFunction<_ResolveC, _ResolveD>('SpatePairResolve');
  late final _FreeD _free = _lib.lookupFunction<_FreeC, _FreeD>('SpateFreeString');
  late final _StrActD _addJson = _lib.lookupFunction<_StrActC, _StrActD>('SpateAddJSON');
  late final _HandleStrD _settingsJson = _lib.lookupFunction<_HandleStrC, _HandleStrD>('SpateSettingsJSON');
  late final _IdActD _settingsApply = _lib.lookupFunction<_IdActC, _IdActD>('SpateSettingsApply');
  late final _IdActD _startNow = _lib.lookupFunction<_IdActC, _IdActD>('SpateStartNow');
  late final _HandleLongD _currentLimit = _lib.lookupFunction<_HandleLongC, _HandleLongD>('SpateCurrentLimit');
  late final _HandleIntD _showPending = _lib.lookupFunction<_HandleIntC, _HandleIntD>('SpateShowPending');
  late final _HandleULongD _queueVersion = _lib.lookupFunction<_HandleULongC, _HandleULongD>('SpateQueueVersion');
  late final Pointer<Utf8> Function() _version =
      _lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('SpateVersion');

  /// The core's version, stamped from the repo's VERSION file at build time.
  String get version => _take(_version());

  Spate._(this._lib, this._h);

  /// Starts the service. [downloadDir] empty selects the platform default;
  /// [maxConcurrent] 0 takes the value from settings. [settingsPath] points
  /// the core at a settings file other than the per-user one, and
  /// [allowMultiple] skips the single-instance guard (both for tests).
  factory Spate.start({
    int maxConcurrent = 0,
    String downloadDir = '',
    String settingsPath = '',
    bool allowMultiple = false,
    String? libraryPath,
  }) {
    final lib = DynamicLibrary.open(libraryPath ?? locateLibrary());
    final start = lib.lookupFunction<_StartC, _StartD>('SpateServiceStartJSON');
    final spec = jsonEncode({
      'maxConcurrent': maxConcurrent,
      'downloadDir': downloadDir,
      'settingsPath': settingsPath,
      'allowMultiple': allowMultiple,
    }).toNativeUtf8();
    try {
      final h = start(spec);
      if (h == 0) {
        final why = _lastErrorOf(lib);
        throw SpateException(why.isEmpty ? 'SpateServiceStart failed' : why);
      }
      return Spate._(lib, h);
    } finally {
      malloc.free(spec);
    }
  }

  /// The reason the most recent failed call gave, or null when the last call
  /// succeeded. Read it right after an operation returned null or false.
  String? get lastError {
    final s = _lastErrorOf(_lib);
    return s.isEmpty ? null : s;
  }

  /// Advances whenever the queue changes (jobs added, removed or changing
  /// state). Equal to the last value seen means [statuses] would return the
  /// same list, except for progress bytes of running jobs.
  int get queueVersion => _queueVersion(_h);

  /// Asks an already running instance to show its window (a second launch
  /// calls this after [Spate.start] fails, then exits). True if one answered.
  static bool requestShow({String? libraryPath}) {
    try {
      final lib = DynamicLibrary.open(libraryPath ?? locateLibrary());
      final f = lib.lookupFunction<Int32 Function(), int Function()>('SpateRequestShow');
      return f() != 0;
    } catch (_) {
      return false;
    }
  }

  /// True once when another launch asked this instance to show its window.
  bool get showPending => _showPending(_h) != 0;

  /// Finds libspate for this platform: an explicit SPATE_LIB path, the app
  /// bundle's Frameworks folder, or the repo's dist/ folder during development.
  static String locateLibrary() {
    final env = Platform.environment['SPATE_LIB'];
    if (env != null && env.isNotEmpty) return env;
    final name = Platform.isMacOS
        ? 'libspate.dylib'
        : Platform.isWindows
            ? 'spate.dll'
            : 'libspate.so';
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[
      '$exeDir/../Frameworks/$name', // macOS .app bundle
      '$exeDir/$name', // Windows/Linux next to the executable
      '$exeDir/lib/$name', // Linux Flutter bundle's lib/ directory
      'dist/$name', // running from the repo root
      '../../dist/$name', // running/testing from apps/flutter
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return File(c).absolute.path;
    }
    throw StateError('libspate not found; set SPATE_LIB or run `make lib`');
  }

  String _take(Pointer<Utf8> p) {
    try {
      return p.toDartString();
    } finally {
      _free(p);
    }
  }

  Map<String, dynamic> info() => jsonDecode(_take(_info(_h))) as Map<String, dynamic>;

  /// Enqueues a download; returns the job id or null on error.
  String? add(String url, {String dir = '', String sha256 = '', int conns = 8}) {
    final u = url.toNativeUtf8();
    final d = dir.toNativeUtf8();
    final s = sha256.toNativeUtf8();
    try {
      final id = _take(_add(_h, u, d, s, conns));
      return id.isEmpty ? null : id;
    } finally {
      malloc.free(u);
      malloc.free(d);
      malloc.free(s);
    }
  }

  bool _idAct(_IdActD f, String id) {
    final p = id.toNativeUtf8();
    try {
      return f(_h, p) == 0;
    } finally {
      malloc.free(p);
    }
  }

  bool pause(String id) => _idAct(_pause, id);
  bool resume(String id) => _idAct(_resume, id);
  bool cancel(String id) => _idAct(_cancel, id);
  /// Removes the row; files on disk are kept.
  bool remove(String id) => _idAct(_remove, id);

  /// Removes the row and deletes the partial download (stops it first);
  /// a finished file is never deleted.
  bool discard(String id) => _idAct(_discard, id);
  int clearFinished() => _clearFinished(_h);
  void cancelAll() => _cancelAll(_h);

  List<JobStatus> statuses() {
    final raw = jsonDecode(_take(_status(_h))) as List<dynamic>;
    return raw.map((e) => JobStatus.fromJson(e as Map<String, dynamic>)).toList();
  }

  bool get pairPending => _pairPending(_h) != 0;
  void resolvePair(bool ok) => _pairResolve(_h, ok ? 1 : 0);

  /// Enqueues a download from a spec: url, dir, sha256, conns, priority,
  /// startAt (Unix seconds; 0 = now). Returns the job id or null.
  String? addJson(Map<String, dynamic> spec) {
    final p = jsonEncode(spec).toNativeUtf8();
    try {
      final id = _take(_addJson(_h, p));
      return id.isEmpty ? null : id;
    } finally {
      malloc.free(p);
    }
  }

  /// The persisted settings document (see internal/settings).
  Map<String, dynamic> settings() => jsonDecode(_take(_settingsJson(_h))) as Map<String, dynamic>;

  /// Applies and persists settings; omitted fields keep their current values.
  bool applySettings(Map<String, dynamic> doc) => _idAct(_settingsApply, jsonEncode(doc));

  /// Drops a pending job's scheduled start so it runs as soon as possible.
  bool startNow(String id) => _idAct(_startNow, id);

  /// Bytes/sec cap currently in force (0 = unlimited).
  int get currentLimit => _currentLimit(_h);

  void stop() => _stop(_h);
}
