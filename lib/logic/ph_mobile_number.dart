const philippineMobileExample = '+639XXXXXXXXX';

/// Returns the ten-digit part for existing +63, 63, or 09 numbers.
String philippineMobileDigits(String? stored) {
  final value = stored?.trim() ?? '';
  if (value.startsWith('+63')) return value.substring(3);
  if (value.startsWith('63') && value.length == 12) return value.substring(2);
  if (value.startsWith('0') && value.length == 11) return value.substring(1);
  return value;
}

String? philippineMobileError(String? digits) {
  final value = digits?.trim() ?? '';
  if (value.isEmpty) return 'Mobile number is required.';
  if (!RegExp(r'^9[0-9]{9}$').hasMatch(value)) {
    return 'Enter 10 digits starting with 9 after +63.';
  }
  return null;
}

String philippineMobileE164(String digits) => '+63${digits.trim()}';
