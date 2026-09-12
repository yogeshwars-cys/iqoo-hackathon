/// bytes.dart — tiny, dependency-free byte helpers shared by the security
/// code. Hex is always lowercase: the canonical digest, signature and public
/// key fields are compared as strings on the desktop, and a case mismatch
/// must never be the reason a valid capsule is rejected.

library;

import 'dart:typed_data';

String toHex(List<int> bytes) {
  const digits = '0123456789abcdef';
  final out = StringBuffer();
  for (final b in bytes) {
    out
      ..write(digits[(b >> 4) & 0xf])
      ..write(digits[b & 0xf]);
  }
  return out.toString();
}

/// Strict: rejects odd lengths and non-hex characters rather than guessing.
Uint8List fromHex(String hex) {
  if (hex.length.isOdd) {
    throw const FormatException('Hex string has an odd length.');
  }
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) throw const FormatException('Invalid hex character.');
    out[i] = byte;
  }
  return out;
}

/// Length-constant comparison, for tags and MACs checked in Dart.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Best-effort overwrite of a buffer that held key material or plaintext.
/// Dart gives no guarantee the GC has not copied it, so this narrows the
/// window rather than closing it.
void wipe(Uint8List bytes) => bytes.fillRange(0, bytes.length, 0);
