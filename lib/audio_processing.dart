import 'dart:math' as math;
import 'dart:typed_data';

/// Audio PCM, volontairement limité au WAV non compressé 16 bits.
class PcmAudio {
  final int sampleRate;
  final Float32List samples;
  const PcmAudio(this.sampleRate, this.samples);
  double get duration => samples.length / sampleRate;
}

int _fourcc(Uint8List b, int p) => ByteData.sublistView(b).getUint32(p, Endian.little);

PcmAudio readPcmWav(Uint8List bytes) {
  if (bytes.length < 44 || String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
      String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
    throw const FormatException('Sélectionnez un fichier WAV valide.');
  }
  final bd = ByteData.sublistView(bytes);
  int? offset;
  int? byteCount;
  int? rate;
  int? channels;
  int? blockAlign;
  int? bits;
  int? format;
  var p = 12;
  while (p + 8 <= bytes.length) {
    final id = _fourcc(bytes, p);
    final size = bd.getUint32(p + 4, Endian.little);
    final start = p + 8;
    if (start + size > bytes.length) throw const FormatException('Fichier WAV incomplet.');
    if (id == 0x20746d66) { // 'fmt '
      if (size < 16) throw const FormatException('En-tête WAV invalide.');
      format = bd.getUint16(start, Endian.little);
      channels = bd.getUint16(start + 2, Endian.little);
      rate = bd.getUint32(start + 4, Endian.little);
      blockAlign = bd.getUint16(start + 12, Endian.little);
      bits = bd.getUint16(start + 14, Endian.little);
    } else if (id == 0x61746164) { // 'data'
      offset = start;
      byteCount = size;
    }
    p = start + size + (size & 1);
  }
  if (format != 1 || bits != 16 || (channels != 1 && channels != 2) ||
      rate == null || rate < 8000 || rate > 96000 ||
      blockAlign != channels! * 2 || offset == null || byteCount == null) {
    throw const FormatException('Format accepté : WAV PCM 16 bits, mono/stéréo, 8–96 kHz.');
  }
  final frames = byteCount ~/ blockAlign!;
  if (frames == 0) throw const FormatException('Le fichier audio est vide.');
  // On ne décode que 20 secondes pour éviter de saturer la mémoire mobile.
  final count = math.min(frames, rate * 20);
  final out = Float32List(count);
  for (var i = 0; i < count; i++) {
    var sum = 0.0;
    for (var ch = 0; ch < channels; ch++) {
      sum += bd.getInt16(offset + i * blockAlign + ch * 2, Endian.little) / 32768;
    }
    out[i] = sum / channels;
  }
  return PcmAudio(rate, out);
}

/// Pitch shift granulaire expérimental ; la sortie contient exactement le
/// même nombre d'échantillons que l'entrée (tempo/durée préservés).
/// ratio = fréquence cible / fréquence de référence.
Float32List shiftPitch(Float32List input, double ratio, int sampleRate) {
  if (ratio <= 0 || !ratio.isFinite) throw ArgumentError('Ratio incorrect');
  if ((ratio - 1).abs() < 1e-9) return Float32List.fromList(input);
  final length = input.length;
  final out = Float32List(length);
  final norm = Float32List(length);
  final grain = math.min(2048, math.max(256, sampleRate ~/ 20));
  final hop = grain ~/ 4;
  // Overlap-add avec fenêtres de Hann : la position temporelle de chaque
  // grain reste constante, seul son contenu est lu à une vitesse différente.
  for (var center = 0; center < length + grain; center += hop) {
    final left = center - grain ~/ 2;
    for (var j = 0; j < grain; j++) {
      final dst = left + j;
      if (dst < 0 || dst >= length) continue;
      final src = center + (j - grain / 2) * ratio;
      if (src < 0 || src >= length - 1) continue;
      final si = src.floor();
      final frac = src - si;
      final sample = input[si] * (1 - frac) + input[si + 1] * frac;
      final win = 0.5 - 0.5 * math.cos(2 * math.pi * j / (grain - 1));
      out[dst] += sample * win;
      norm[dst] += win;
    }
  }
  for (var i = 0; i < length; i++) {
    out[i] = norm[i] > 1e-8 ? (out[i] / norm[i]).clamp(-1.0, 1.0) : 0;
  }
  return out;
}

Uint8List encodePcmWav(Float32List samples, int rate) {
  final bd = ByteData(44 + samples.length * 2);
  void u32(int p, int v) => bd.setUint32(p, v, Endian.little);
  void u16(int p, int v) => bd.setUint16(p, v, Endian.little);
  void ascii(int p, String s) { for (var i = 0; i < s.length; i++) { bd.setUint8(p + i, s.codeUnitAt(i)); } }
  ascii(0, 'RIFF'); u32(4, 36 + samples.length * 2); ascii(8, 'WAVE');
  ascii(12, 'fmt '); u32(16, 16); u16(20, 1); u16(22, 1);
  u32(24, rate); u32(28, rate * 2); u16(32, 2); u16(34, 16);
  ascii(36, 'data'); u32(40, samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    bd.setInt16(44 + i * 2, (samples[i] * 32767).round().clamp(-32768, 32767), Endian.little);
  }
  return bd.buffer.asUint8List();
}
