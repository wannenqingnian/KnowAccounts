/// Source text may contain card numbers. Keep only the tail of long numeric
/// identifiers before persisting or parsing, including spaced/full-width input.
String sanitizeSourceText(String text) => text.replaceAllMapped(
  RegExp(r'(?<![0-9０-９])(?:[0-9０-９][ \t-]?){12,}[0-9０-９](?![0-9０-９])'),
  (match) {
    final digits = String.fromCharCodes(
      match[0]!.runes
          .where((c) => (c >= 48 && c <= 57) || (c >= 0xff10 && c <= 0xff19))
          .map((c) => c >= 0xff10 ? c - 0xff10 + 48 : c),
    );
    return '尾号 ${digits.substring(digits.length - 4)}';
  },
);
