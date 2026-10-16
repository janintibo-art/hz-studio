import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'audio_processing.dart';

class WavInfo {
  final int sampleRate;
  final int channels;
  final int dataOffset;
  final int frames;
  const WavInfo(this.sampleRate, this.channels, this.dataOffset, this.frames);
  double get duration => frames / sampleRate;
}

Future<WavInfo> inspectWav(String path) async {
  final f = await File(path).open();
  try {
    final h = await f.read(44);
    if (h.length != 44 || String.fromCharCodes(h.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(h.sublist(8, 12)) != 'WAVE' ||
        String.fromCharCodes(h.sublist(12, 16)) != 'fmt ' ||
        String.fromCharCodes(h.sublist(36, 40)) != 'data') {
      throw const FormatException('WAV PCM standard requis pour le traitement intégral.');
    }
    final b = ByteData.sublistView(Uint8List.fromList(h));
    final format = b.getUint16(20, Endian.little);
    final channels = b.getUint16(22, Endian.little);
    final rate = b.getUint32(24, Endian.little);
    final bits = b.getUint16(34, Endian.little);
    final count = b.getUint32(40, Endian.little);
    if (format != 1 || bits != 16 || channels < 1 || channels > 2 || rate < 8000 || rate > 96000) {
      throw const FormatException('Sortie attendue : PCM 16 bits mono/stéréo, 8–96 kHz.');
    }
    return WavInfo(rate, channels, 44, count ~/ (channels * 2));
  } finally {
    await f.close();
  }
}

Future<void> convertWholeWav(String source, String target, double ratio) async {
  final info = await inspectWav(source);
  final input = await File(source).open();
  final output = await File(target).open(mode: FileMode.write);
  final channels = info.channels;
  final frameBytes = channels * 2;
  final core = info.sampleRate * 4;
  final context = math.min(info.sampleRate ~/ 3, 16384);
  try {
    final header = ByteData(44);
    void w32(int p, int v) => header.setUint32(p, v, Endian.little);
    void w16(int p, int v) => header.setUint16(p, v, Endian.little);
    void ascii(int p, String text) {
      for (var i = 0; i < text.length; i++) { header.setUint8(p + i, text.codeUnitAt(i)); }
    }
    final size = info.frames * frameBytes;
    if (size > 0x7fffffff) throw const FormatException('Fichier WAV de sortie trop volumineux (> 2 Go).');
    ascii(0, 'RIFF'); w32(4, size + 36); ascii(8, 'WAVE');
    ascii(12, 'fmt '); w32(16, 16); w16(20, 1); w16(22, channels);
    w32(24, info.sampleRate); w32(28, info.sampleRate * frameBytes);
    w16(32, frameBytes); w16(34, 16); ascii(36, 'data'); w32(40, size);
    await output.writeFrom(header.buffer.asUint8List());
    for (var frame = 0; frame < info.frames; frame += core) {
      final start = math.max(0, frame - context);
      final end = math.min(info.frames, frame + core + context);
      await input.setPosition(info.dataOffset + start * frameBytes);
      final bytes = await input.read((end - start) * frameBytes);
      if (bytes.length != (end - start) * frameBytes) throw const FormatException('Lecture PCM incomplète.');
      final pcm = ByteData.sublistView(Uint8List.fromList(bytes));
      final processed = <Float32List>[];
      for (var c = 0; c < channels; c++) {
        final samples = Float32List(end - start);
        for (var i = 0; i < samples.length; i++) {
          samples[i] = pcm.getInt16((i * channels + c) * 2, Endian.little) / 32768;
        }
        processed.add(shiftPitch(samples, ratio, info.sampleRate));
      }
      final frames = math.min(core, info.frames - frame);
      final result = ByteData(frames * frameBytes);
      for (var i = 0; i < frames; i++) {
        for (var c = 0; c < channels; c++) {
          final sample = processed[c][frame - start + i];
          result.setInt16((i * channels + c) * 2,
              (sample * 32767).round().clamp(-32768, 32767), Endian.little);
        }
      }
      await output.writeFrom(result.buffer.asUint8List());
    }
  } finally {
    await input.close();
    await output.close();
  }
}

Future<PcmAudio> readPreviewFromFile(String path) async {
  final info = await inspectWav(path);
  final file = await File(path).open();
  try {
    await file.setPosition(info.dataOffset);
    final count = math.min(info.frames, info.sampleRate * 20);
    final bytes = await file.read(count * info.channels * 2);
    final bd = ByteData.sublistView(Uint8List.fromList(bytes));
    final out = Float32List(count);
    for (var i = 0; i < count; i++) {
      var sum = 0.0;
      for (var c = 0; c < info.channels; c++) {
        sum += bd.getInt16((i * info.channels + c) * 2, Endian.little) / 32768;
      }
      out[i] = sum / info.channels;
    }
    return PcmAudio(info.sampleRate, out);
  } finally {
    await file.close();
  }
}
