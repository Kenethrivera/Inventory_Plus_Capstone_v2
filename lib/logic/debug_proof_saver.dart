// Picks the right platform implementation at compile time:
// - dart.library.io available  -> mobile/desktop (writes a real file)
// - dart.library.html available -> web (triggers a browser download)
// - neither -> stub (no-op), so this never breaks a build on an
//   unexpected target.
export 'debug_proof_saver_stub.dart'
    if (dart.library.io) 'debug_proof_saver_io.dart'
    if (dart.library.html) 'debug_proof_saver_web.dart';
