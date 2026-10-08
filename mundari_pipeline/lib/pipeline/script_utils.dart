// lib/pipeline/script_utils.dart

/// A simple block-offset transliterator from Devanagari to Odia.
///
/// Removes most punctuation and standardizes spaces.
String transliterateDevaToOdia(String text) {
  final buffer = StringBuffer();
  for (int i = 0; i < text.length; i++) {
    int codeUnit = text.codeUnitAt(i);
    if (codeUnit >= 0x0900 && codeUnit <= 0x097F) {
      // Offset from Devanagari block to Odia block is +0x0200
      int odiaRune = codeUnit + 0x0200;

      // Phonetic corrections to align with Mundari tokens.txt
      if (codeUnit == 0x092F) {
        odiaRune = 0x0B5F; // Devanagari YA (य) -> Odia Yya (ୟ), not Ja (ଯ)
      } else if (odiaRune == 0x0B08) {
        odiaRune = 0x0B07; // ଈ -> ଇ
      } else if (odiaRune == 0x0B35) {
        odiaRune = 0x0B2C; // ଵ -> ବ
      }
      
      buffer.writeCharCode(odiaRune);
    } else {
      // Keep spaces or other standard characters
      buffer.writeCharCode(codeUnit);
    }
  }

  String result = buffer.toString();

  // Smooth virama/halants (୍) for character-level MMS-TTS
  // Removes vocoder phase discontinuities on conjuncts (e.g. ଫ୍ଲ -> ଫଲ, ସ୍ଟ -> ସଟ)
  result = result.replaceAll('୍', '');

  // Strip punctuation (including danda ୤ / \U+0B64, commas, etc.)
  result = result.replaceAll(RegExp(r'[^\w\s\u0B00-\u0B7F]'), ' ');

  // Collapse multiple spaces
  result = result.replaceAll(RegExp(r'\s+'), ' ');
  return result.trim();
}

/// Splits an Odia/Mundari sentence into natural clauses of roughly [targetLength]
/// (15-20 characters), preferring natural boundaries (spaces, punctuation)
/// without splitting words.
List<String> splitIntoClauses(String text, {int targetLength = 18}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return const [];

  final clauses = <String>[];
  final words = trimmed.split(RegExp(r'\s+'));
  final current = <String>[];

  for (final word in words) {
    if (word.isEmpty) continue;

    final candidate = [...current, word].join(' ');
    if (current.isNotEmpty && candidate.length > targetLength) {
      clauses.add(current.join(' ').trim());
      current.clear();
      current.add(word);
    } else {
      current.add(word);
    }

    // Flush immediately if word ends with clausal or terminal punctuation
    if (word.endsWith('।') ||
        word.endsWith(',') ||
        word.endsWith('?') ||
        word.endsWith('!') ||
        word.endsWith('୤') ||
        word.endsWith(';')) {
      clauses.add(current.join(' ').trim());
      current.clear();
    }
  }

  if (current.isNotEmpty) {
    final remaining = current.join(' ').trim();
    if (remaining.isNotEmpty) {
      clauses.add(remaining);
    }
  }

  return clauses.where((c) => c.isNotEmpty).toList();
}
