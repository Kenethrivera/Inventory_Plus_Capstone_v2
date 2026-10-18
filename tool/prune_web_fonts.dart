import 'dart:convert';
import 'dart:io';

const _lucideFamilyPrefix = 'packages/lucide_icons_flutter/Lucide';
const _regularLucideFamily = 'packages/lucide_icons_flutter/Lucide';
final _weightedLucideReference = RegExp(
  r'LucideIcons(?:100|200|300|400|500|600)\.',
);

void main() {
  final weightedReferences = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .where(
        (file) => _weightedLucideReference.hasMatch(file.readAsStringSync()),
      )
      .map((file) => file.path)
      .toList(growable: false);

  if (weightedReferences.isNotEmpty) {
    stderr.writeln(
      '[WebBuild] Refusing to prune Lucide weight fonts because weighted '
      'icons are used in: ${weightedReferences.join(', ')}',
    );
    exitCode = 1;
    return;
  }

  final manifestFile = File('build/web/assets/FontManifest.json');
  if (!manifestFile.existsSync()) {
    stderr.writeln(
      '[WebBuild] FontManifest.json not found. Run flutter build web first.',
    );
    exitCode = 1;
    return;
  }

  final manifest = (jsonDecode(manifestFile.readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();

  final prunedManifest = manifest
      .where((entry) {
        final family = entry['family'] as String?;
        return family == null ||
            !family.startsWith(_lucideFamilyPrefix) ||
            family == _regularLucideFamily;
      })
      .toList(growable: false);

  manifestFile.writeAsStringSync(jsonEncode(prunedManifest));

  final weightDirectory = Directory(
    'build/web/assets/packages/lucide_icons_flutter/assets/build_font',
  );
  if (weightDirectory.existsSync()) {
    weightDirectory.deleteSync(recursive: true);
  }

  final removedFamilies = manifest.length - prunedManifest.length;
  stdout.writeln(
    '[WebBuild] Removed $removedFamilies unused Lucide font families.',
  );
}
