import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/ffi/cascade_ffi.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // The Go core owns the engine, the queue, the browser-capture endpoint and
  // pairing; this app is a thin shell over it via the C ABI.
  final core = Cascade.start(maxConcurrent: 3);
  runApp(CascadeApp(controller: CascadeController(core)));
}
