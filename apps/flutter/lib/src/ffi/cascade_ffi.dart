import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../model/job.dart';

// C ABI (see export/cshared/cascade.go and dist/libcascade.h).
typedef _StartC = LongLong Function(Int32, Pointer<Utf8>);
typedef _StartD = int Function(int, Pointer<Utf8>);
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

/// Thin, synchronous binding to libcascade. One instance == one running
/// service (engine + queue + browser-capture endpoint).
class Cascade {
  final DynamicLibrary _lib;
  final int _h;

  late final _HandleVoidD _stop = _lib.lookupFunction<_HandleVoidC, _HandleVoidD>('CascadeServiceStop');
  late final _HandleStrD _info = _lib.lookupFunction<_HandleStrC, _HandleStrD>('CascadeInfoJSON');
  late final _AddD _add = _lib.lookupFunction<_AddC, _AddD>('CascadeAdd');
  late final _IdActD _pause = _lib.lookupFunction<_IdActC, _IdActD>('CascadePause');
  late final _IdActD _resume = _lib.lookupFunction<_IdActC, _IdActD>('CascadeResume');
  late final _IdActD _cancel = _lib.lookupFunction<_IdActC, _IdActD>('CascadeCancel');
  late final _IdActD _remove = _lib.lookupFunction<_IdActC, _IdActD>('CascadeRemove');
  late final _HandleIntD _clearFinished = _lib.lookupFunction<_HandleIntC, _HandleIntD>('CascadeClearFinished');
  late final _HandleVoidD _cancelAll = _lib.lookupFunction<_HandleVoidC, _HandleVoidD>('CascadeCancelAll');
  late final _HandleStrD _status = _lib.lookupFunction<_HandleStrC, _HandleStrD>('CascadeStatusJSON');
  late final _HandleIntD _pairPending = _lib.lookupFunction<_HandleIntC, _HandleIntD>('CascadePairPending');
  late final _ResolveD _pairResolve = _lib.lookupFunction<_ResolveC, _ResolveD>('CascadePairResolve');
  late final _FreeD _free = _lib.lookupFunction<_FreeC, _FreeD>('CascadeFreeString');

  Cascade._(this._lib, this._h);

  /// Starts the service. [downloadDir] empty selects the platform default.
  factory Cascade.start({int maxConcurrent = 3, String downloadDir = '', String? libraryPath}) {
    final lib = DynamicLibrary.open(libraryPath ?? locateLibrary());
    final start = lib.lookupFunction<_StartC, _StartD>('CascadeServiceStart');
    final dir = downloadDir.toNativeUtf8();
    try {
      final h = start(maxConcurrent, dir);
      if (h == 0) throw StateError('CascadeServiceStart failed');
      return Cascade._(lib, h);
    } finally {
      malloc.free(dir);
    }
  }

  /// Finds libcascade for this platform: an explicit CASCADE_LIB path, the app
  /// bundle's Frameworks folder, or the repo's dist/ folder during development.
  static String locateLibrary() {
    final env = Platform.environment['CASCADE_LIB'];
    if (env != null && env.isNotEmpty) return env;
    final name = Platform.isMacOS
        ? 'libcascade.dylib'
        : Platform.isWindows
            ? 'cascade.dll'
            : 'libcascade.so';
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[
      '$exeDir/../Frameworks/$name', // macOS .app bundle
      '$exeDir/$name', // Windows/Linux next to the executable
      'dist/$name', // running from apps/flutter? no; from repo root
      '../../dist/$name', // running/testing from apps/flutter
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return File(c).absolute.path;
    }
    throw StateError('libcascade not found; set CASCADE_LIB or run `make lib`');
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
  bool remove(String id) => _idAct(_remove, id);
  int clearFinished() => _clearFinished(_h);
  void cancelAll() => _cancelAll(_h);

  List<JobStatus> statuses() {
    final raw = jsonDecode(_take(_status(_h))) as List<dynamic>;
    return raw.map((e) => JobStatus.fromJson(e as Map<String, dynamic>)).toList();
  }

  bool get pairPending => _pairPending(_h) != 0;
  void resolvePair(bool ok) => _pairResolve(_h, ok ? 1 : 0);

  void stop() => _stop(_h);
}
