import 'package:flutter_test/flutter_test.dart';
import 'package:hz_studio/main.dart';

void main() {
  test('WAV header and size', () {
    final wav = makeWav(432, 0.2, 'Sinusoïde', false);
    expect(wav.length, 44 + 44100 * 4 * 2);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
  });
}
