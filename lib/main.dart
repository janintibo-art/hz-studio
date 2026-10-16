import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

void main() => runApp(const HzStudio());

class HzStudio extends StatelessWidget {
  const HzStudio({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'HZ Studio', debugShowCheckedModeBanner: false,
    theme: ThemeData(useMaterial3: true, brightness: Brightness.dark,
      colorSchemeSeed: const Color(0xff27ded6), scaffoldBackgroundColor: const Color(0xff090e1e)),
    home: const StudioPage(),
  );
}

class StudioPage extends StatefulWidget {
  const StudioPage({super.key});
  @override
  State<StudioPage> createState() => _StudioPageState();
}

class _StudioPageState extends State<StudioPage> {
  final AudioPlayer _player = AudioPlayer();
  final TextEditingController _frequency = TextEditingController(text: '432');
  double _volume = 0.25;
  String _wave = 'Sinusoïde';
  bool _playing = false;
  bool _schumann = false;
  String? _error;
  int _generation = 0;
  final List<File> _tempFiles = [];

  static const presets = <(String, double, bool)>[
    ('La 440', 440, false), ('La 432', 432, false),
    ('174 Hz', 174, false), ('396 Hz', 396, false),
    ('528 Hz', 528, false), ('639 Hz', 639, false),
    ('741 Hz', 741, false), ('852 Hz', 852, false),
    ('963 Hz', 963, false), ('Schumann 7,83 Hz', 7.83, true),
  ];

  @override
  void dispose() {
    _generation++;
    _player.dispose();
    _frequency.dispose();
    for (final f in _tempFiles) { try { f.deleteSync(); } catch (_) {} }
    super.dispose();
  }

  void _choose(double value, bool schumann) {
    _frequency.text = value.toString().replaceAll('.', ',');
    setState(() { _schumann = schumann; _error = null; });
    if (_playing) _stop();
  }

  double? _parsedFrequency() => double.tryParse(_frequency.text.trim().replaceAll(',', '.'));

  Future<void> _stop() async {
    _generation++;
    try { await _player.stop(); } catch (_) {}
    if (mounted) setState(() => _playing = false);
  }

  Future<void> _start() async {
    final freq = _parsedFrequency();
    if (freq == null || !freq.isFinite || freq < 0.1 || freq > 15000) {
      setState(() => _error = 'Entrez une fréquence entre 0,1 et 15 000 Hz.');
      return;
    }
    final generation = ++_generation;
    setState(() { _error = null; _playing = false; });
    try {
      await _player.stop();
      // Un morceau PCM boucle en conservant la vitesse normale du lecteur.
      final bytes = await Future<Uint8List>(() => makeWav(freq, _volume, _wave, _schumann));
      if (!mounted || generation != _generation) return;
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/hzstudio_$generation.wav');
      await file.writeAsBytes(bytes, flush: true);
      _tempFiles.add(file);
      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.play(DeviceFileSource(file.path));
      if (mounted && generation == _generation) setState(() => _playing = true);
      if (_tempFiles.length > 3) {
        final old = _tempFiles.removeAt(0);
        try { await old.delete(); } catch (_) {}
      }
    } catch (e) {
      if (mounted && generation == _generation) setState(() => _error = 'Lecture impossible : $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = _parsedFrequency();
    final label = f == null ? '—' : '${f.toStringAsFixed(f % 1 == 0 ? 0 : 2)} Hz';
    return Scaffold(body: SafeArea(child: Center(child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: ListView(padding: const EdgeInsets.all(22), children: [
        const Row(children: [Icon(Icons.graphic_eq, color: Color(0xff27ded6), size: 35),
          SizedBox(width: 10), Text('HZ STUDIO', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 26, letterSpacing: 3))]),
        const SizedBox(height: 5),
        const Text('Laboratoire de fréquences • Android & Windows', style: TextStyle(color: Colors.white60)),
        const SizedBox(height: 25),
        Container(padding: const EdgeInsets.all(24), decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xff102e40), Color(0xff17152e)]),
          borderRadius: BorderRadius.circular(24)), child: Column(children: [
            const Text('FRÉQUENCE ACTIVE', style: TextStyle(color: Colors.white70, letterSpacing: 2)),
            const SizedBox(height: 12),
            FittedBox(child: Text(label, style: const TextStyle(fontSize: 58, color: Color(0xff71fff0), fontWeight: FontWeight.w900))),
            const SizedBox(height: 12),
            Text(_schumann ? 'Modulation Schumann sur porteuse audible de 220 Hz' : 'Générateur de signal audio',
              textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 18),
            Wrap(spacing: 10, children: [
              FilledButton.icon(onPressed: _playing ? _stop : _start,
                icon: Icon(_playing ? Icons.stop : Icons.play_arrow),
                label: Text(_playing ? 'ARRÊTER' : 'ÉCOUTER')),
            ]),
          ])),
        const SizedBox(height: 22),
        TextField(controller: _frequency, keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Fréquence personnalisée (Hz)',
            border: OutlineInputBorder(), prefixIcon: Icon(Icons.tune), helperText: 'De 0,1 à 15 000 Hz • virgule ou point'),
          onChanged: (_) { if (_playing) _stop(); setState(() { _schumann = false; _error = null; }); }),
        const SizedBox(height: 20),
        const Text('PRÉRÉGLAGES', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.5)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 6, children: [for (final p in presets)
          ActionChip(label: Text(p.$1), onPressed: () => _choose(p.$2, p.$3))]),
        const SizedBox(height: 23),
        Row(children: [const Expanded(child: Text('Volume du générateur')),
          Text('${(_volume * 100).round()} %')]),
        Slider(value: _volume, min: 0, max: 0.6, onChanged: (v) {
          setState(() => _volume = v); if (_playing) _stop();
        }),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(initialValue: _wave,
          decoration: const InputDecoration(labelText: 'Forme d’onde', border: OutlineInputBorder()),
          items: ['Sinusoïde', 'Triangle', 'Carrée'].map((w) => DropdownMenuItem(value: w, child: Text(w))).toList(),
          onChanged: (v) { if (v != null) { setState(() => _wave = v); if (_playing) _stop(); } }),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 16),
          child: Text(_error!, style: const TextStyle(color: Colors.orangeAccent))),
        const SizedBox(height: 25),
        const Text('V1 — Générateur fonctionnel. Lecture de fichiers avec changement de hauteur sans modification du tempo et capture audio des autres applications : étapes suivantes.',
          style: TextStyle(color: Colors.white60, height: 1.45)),
        const SizedBox(height: 10),
        const Text('Commencez avec un volume faible. 7,83 Hz est ici une modulation audible, et non une reproduction directe des infrasons.',
          style: TextStyle(color: Colors.white54, fontSize: 12)),
      ]),
    ))));
  }
}

Uint8List makeWav(double frequency, double volume, String wave, bool schumann) {
  const rate = 44100;
  const seconds = 4;
  const frames = rate * seconds;
  final b = ByteData(44 + frames * 2);
  void word(int off, int v) => b.setUint32(off, v, Endian.little);
  void half(int off, int v) => b.setUint16(off, v, Endian.little);
  void ascii(int off, String s) { for (var i = 0; i < s.length; i++) { b.setUint8(off + i, s.codeUnitAt(i)); } }
  ascii(0, 'RIFF'); word(4, 36 + frames * 2); ascii(8, 'WAVE'); ascii(12, 'fmt ');
  word(16, 16); half(20, 1); half(22, 1); word(24, rate); word(28, rate * 2);
  half(32, 2); half(34, 16); ascii(36, 'data'); word(40, frames * 2);
  for (var i = 0; i < frames; i++) {
    final t = i / rate;
    final phase = 2 * math.pi * (schumann ? 220.0 : frequency) * t;
    final sinus = math.sin(phase);
    final sample = switch (wave) {
      'Carrée' => sinus >= 0 ? 1.0 : -1.0,
      'Triangle' => 2 / math.pi * math.asin(sinus),
      _ => sinus,
    };
    final mod = schumann ? 0.55 + 0.45 * math.sin(2 * math.pi * frequency * t) : 1.0;
    final fade = math.min(1.0, math.min(i / 400.0, (frames - i - 1) / 400.0));
    final v = (sample * mod * volume * fade * 32767).round().clamp(-32768, 32767);
    b.setInt16(44 + i * 2, v, Endian.little);
  }
  return b.buffer.asUint8List();
}
