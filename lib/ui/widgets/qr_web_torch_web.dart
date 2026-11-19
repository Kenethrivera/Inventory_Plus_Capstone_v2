import 'dart:html' as html;

html.VideoElement? _activeScannerVideo() {
  html.VideoElement? active;

  // Flutter platform views can live inside the glass pane's shadow root.
  void search(dynamic root) {
    for (final node in root.querySelectorAll('*')) {
      if (node is html.VideoElement && node.srcObject != null && !node.paused) {
        active = node;
      }
      if (node is html.Element && node.shadowRoot != null) {
        search(node.shadowRoot);
      }
    }
  }

  search(html.document);
  return active;
}

Future<void> setQrWebTorch(bool enabled) async {
  final stream = _activeScannerVideo()?.srcObject;
  final tracks = stream?.getVideoTracks();
  if (tracks == null || tracks.isEmpty) {
    throw StateError('The scanner camera is not ready.');
  }

  final track = tracks.first;
  if (track.getCapabilities()['torch'] != true) {
    throw UnsupportedError('This browser camera does not support torch.');
  }

  await track.applyConstraints({
    'advanced': [
      {'torch': enabled},
    ],
  });
}
