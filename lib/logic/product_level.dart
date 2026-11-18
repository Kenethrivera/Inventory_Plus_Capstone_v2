const int maxProductLevel = 10;

bool isValidProductLevel(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) return true;
  final level = int.tryParse(normalized);
  return level != null &&
      level >= 1 &&
      level <= maxProductLevel &&
      normalized == level.toString();
}
