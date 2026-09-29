// Exercises the real libcascade through dart:ffi (no Flutter/Xcode needed):
// run `make lib` at the repo root first, then `flutter test` or `dart test`.
import 'dart:io';

import 'package:cascade_app/src/ffi/cascade_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('service starts, downloads a local file, reports status, stops', () async {
    final dir = Directory.systemTemp.createTempSync('cascade-ffi-');
    // A tiny local origin the core can fetch (byte ranges via HttpServer).
    final data = List<int>.generate(300 * 1024, (i) => i % 251);
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((req) {
      req.response.headers.set('Accept-Ranges', 'bytes');
      final range = req.headers.value('range');
      if (req.method == 'HEAD') {
        req.response.headers.contentLength = data.length;
        req.response.close();
        return;
      }
      if (range != null && range.startsWith('bytes=')) {
        final parts = range.substring(6).split('-');
        final start = int.parse(parts[0]);
        final end = parts[1].isEmpty ? data.length - 1 : int.parse(parts[1]);
        req.response.statusCode = 206;
        req.response.headers.set('Content-Range', 'bytes $start-$end/${data.length}');
        req.response.headers.contentLength = end - start + 1;
        req.response.add(data.sublist(start, end + 1));
      } else {
        req.response.headers.contentLength = data.length;
        req.response.add(data);
      }
      req.response.close();
    });

    final core = Cascade.start(maxConcurrent: 2, downloadDir: dir.path);
    addTearDown(() {
      core.stop();
      server.close(force: true);
      dir.deleteSync(recursive: true);
    });

    expect(core.info()['dir'], dir.path);
    expect(core.pairPending, isFalse);

    final id = core.add('http://127.0.0.1:${server.port}/f.bin', conns: 2);
    expect(id, isNotNull);

    final deadline = DateTime.now().add(const Duration(seconds: 10));
    var state = '';
    while (DateTime.now().isBefore(deadline)) {
      final sts = core.statuses();
      final j = sts.where((s) => s.id == id).toList();
      if (j.isNotEmpty) {
        state = j.first.state;
        if (state == 'done' || state == 'failed') break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(state, 'done');
    final out = File('${dir.path}/f.bin');
    expect(out.existsSync(), isTrue);
    expect(out.lengthSync(), data.length);
    expect(core.clearFinished(), 1);
    expect(core.statuses(), isEmpty);

    // Settings round trip: enable category folders + a site rule; a scheduled
    // add is reported pending with its startAt; startNow releases it.
    final settings = core.settings();
    expect(settings['downloadDir'], dir.path);
    expect(core.applySettings({
      'organizeByCategory': true,
      'siteRules': [{'host': '127.0.0.1', 'dir': 'Local'}],
      'limits': {'bytesPerSec': 0, 'windows': []},
    }), isTrue);
    expect(core.settings()['organizeByCategory'], isTrue);
    expect(core.applySettings({'limits': {'windows': [{'from': '99:00', 'to': '01:00'}]}}), isFalse);

    final later = DateTime.now().add(const Duration(hours: 1));
    final sid = core.addJson({'url': 'http://127.0.0.1:${server.port}/f.bin', 'conns': 1, 'startAt': later.millisecondsSinceEpoch ~/ 1000});
    expect(sid, isNotNull);
    final sched = core.statuses().firstWhere((s) => s.id == sid);
    expect(sched.isScheduled, isTrue);
    expect(core.startNow(sid!), isTrue);
    final deadline2 = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline2)) {
      final j = core.statuses().where((s) => s.id == sid).toList();
      if (j.isNotEmpty && j.first.state == 'done') break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    // Site rule routed it into Local/ (site rules beat categories).
    expect(File('${dir.path}/Local/f.bin').existsSync(), isTrue);
  });
}
