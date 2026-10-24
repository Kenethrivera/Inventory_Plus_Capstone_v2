String normalizeGcashReference(String? value) {
  final reference = value?.trim() ?? '';
  if (!RegExp(r'^\d{10,13}$').hasMatch(reference)) {
    throw const FormatException('GCash reference must be 10–13 digits.');
  }
  return reference;
}
