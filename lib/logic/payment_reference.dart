String normalizeGcashReference(String? value) {
  final reference = value?.trim() ?? '';
  if (reference.isEmpty) {
    throw const FormatException('GCash reference number is required.');
  }
  if (!RegExp(r'^\d+$').hasMatch(reference)) {
    throw const FormatException(
      'GCash reference number must contain digits only.',
    );
  }
  return reference;
}
