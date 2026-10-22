// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

String readMainSectionPath() {
  final hash = html.window.location.hash;
  if (hash.startsWith('#/') && hash.length > 1) return hash.substring(1);
  return html.window.location.pathname ?? '/';
}

void pushMainSectionPath(String path) {
  if (readMainSectionPath() == path) return;
  html.window.history.pushState(null, '', '#$path');
}

void replaceMainSectionPath(String path) {
  if (readMainSectionPath() == path) return;
  html.window.history.replaceState(null, '', '#$path');
}
