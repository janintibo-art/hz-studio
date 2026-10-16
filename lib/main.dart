import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'audio_processing.dart';

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
  final TextEditingController _reference = TextEditingController(text: '440');
  final TextEditingController _target = TextEditingController(text: '432');
  double _volume = 0.25;
  String _wave = 'Sinusoïde';
  bool _playing = false;
  bool _schumann = false;
  bool _busy = false;
  int _tab = 0;
  String? _error;
  String? _filename;
  PcmAudio? _imported;
  int _generation = 0;
  final List<File> _tempFiles = [];
  static const presets = <(String, double, bool)>[
    ('La 440', 440, false), ('La 432', 432, false), ('174 Hz', 174, false),
    ('396 Hz', 396, false), ('528 Hz', 528, false), ('639 Hz', 639, false),
    ('741 Hz', 741, false), ('852 Hz', 852, false), ('963 Hz', 963, false),
    ('Schumann 7,83 Hz', 7.83, true),
  ];

  @override
  void dispose() {
    _generation++;
    _player.dispose();
    _frequency.dispose(); _reference.dispose(); _target.dispose();
    for (final f in _tempFiles) { try { f.deleteSync(); } catch (_) {} }
    super.dispose();
  }

  double? _number(TextEditingController c) => double.tryParse(c.text.trim().replaceAll(',', '.'));
  Future<void> _stop() async {
    _generation++;
    try { await _player.stop(); } catch (_) {}
    if (mounted) setState(() => _playing = false);
  }
  void _choose(double freq, bool schumann) {
    _frequency.text = freq.toString().replaceAll('.', ',');
    setState(() { _schumann = schumann; _error = null; });
    if (_playing) _stop();
  }
  Future<void> _playBytes(Uint8List wav, {bool loop = false}) async {
    final gen = ++_generation;
    await _player.stop();
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/hzstudio_${DateTime.now().microsecondsSinceEpoch}.wav');
    await file.writeAsBytes(wav, flush: true);
    _tempFiles.add(file);
    await _player.setReleaseMode(loop ? ReleaseMode.loop : ReleaseMode.stop);
    if (!mounted || gen != _generation) return;
    await _player.play(DeviceFileSource(file.path));
    if (mounted && gen == _generation) setState(() => _playing = true);
    if (_tempFiles.length > 4) {
      final old = _tempFiles.removeAt(0);
      try { await old.delete(); } catch (_) {}
    }
  }
  Future<void> _generate() async {
    final f = _number(_frequency);
    if (f == null || !f.isFinite || f < 0.1 || f > 15000) {
      setState(() => _error = 'Fréquence autorisée : 0,1 à 15 000 Hz.'); return;
    }
    setState(() { _error = null; _busy = true; });
    try {
      final wav = await Isolate.run(() => makeWav(f, _volume, _wave, _schumann));
      if (mounted) await _playBytes(wav, loop: true);
    } catch (e) { if (mounted) setState(() => _error = 'Lecture impossible : $e'); }
    finally { if (mounted) setState(() => _busy = false); }
  }
  Future<Uint8List> _decodeSelectedAudio(String path) async {
    if (Platform.isAndroid) {
      const channel = MethodChannel('hz_studio/audio_decode');
      final wavPath = await channel.invokeMethod<String>('decodePreview', {'path': path});
      if (wavPath == null) throw const FormatException('Décodage Android indisponible.');
      final file = File(wavPath);
      try { return await file.readAsBytes(); } finally { try { await file.delete(); } catch (_) {} }
    }
    if (Platform.isWindows) {
      final exe = File('${File(Platform.resolvedExecutable).parent.path}\\ffmpeg.exe');
      if (!await exe.exists()) throw const FormatException('ffmpeg.exe absent du dossier Windows.');
      final dir = await getTemporaryDirectory();
      final output = File('${dir.path}\\hz_decode_${DateTime.now().microsecondsSinceEpoch}.wav');
      try {
        final process = await Process.run(exe.path, [
          '-hide_banner', '-loglevel', 'error', '-nostdin', '-y', '-i', path,
          '-t', '20', '-vn', '-ac', '1', '-ar', '44100', '-c:a', 'pcm_s16le', output.path,
        ]);
        if (process.exitCode != 0) throw FormatException('FFmpeg : ${process.stderr}');
        return await output.readAsBytes();
      } finally { if (await output.exists()) await output.delete(); }
    }
    throw const FormatException('Plateforme non prise en charge.');
  }

  Future<void> _importAudio() async {
    await _stop();
    setState(() { _busy = true; _error = null; });
    try {
      final pick = await FilePicker.platform.pickFiles(type: FileType.custom,
        allowedExtensions: ['mp3', 'mp2', 'flac', 'ogg', 'opus', 'wav', 'aiff', 'aif', 'aac', 'm4a', 'wma', 'ape', 'wv', 'tta', 'ac3', 'mka'],
        withData: false);
      if (pick == null || pick.files.isEmpty) return;
      final selected = pick.files.single;
      if (selected.path == null) throw const FormatException('Impossible de lire le chemin du fichier.');
      final bytes = await _decodeSelectedAudio(selected.path!);
      final pcm = await Isolate.run(() => readPcmWav(bytes));
      if (mounted) setState(() { _imported = pcm; _filename = selected.name; _error = null; });
    } catch (e) { if (mounted) setState(() => _error = 'Import impossible : $e'); }
    finally { if (mounted) setState(() => _busy = false); }
  }
  Future<void> _playShifted() async {
    final a = _number(_reference);
    final b = _number(_target);
    if (_imported == null) { setState(() => _error = 'Importez d’abord une musique.'); return; }
    if (a == null || b == null || !a.isFinite || !b.isFinite || a < 100 || a > 1000 || b < 100 || b > 1000) {
      setState(() => _error = 'Références d’accordage autorisées : 100 à 1 000 Hz.'); return;
    }
    final ratio = b / a;
    if (ratio < .7 || ratio > 1.4) {
      setState(() => _error = 'Écart trop important pour cet algorithme (70–140 %).'); return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      final pcm = _imported!;
      final audio = await Isolate.run(() => shiftPitch(pcm.samples, ratio, pcm.sampleRate));
      final wav = await Isolate.run(() => encodePcmWav(audio, pcm.sampleRate));
      if (mounted) await _playBytes(wav);
    } catch (e) { if (mounted) setState(() => _error = 'Traitement impossible : $e'); }
    finally { if (mounted) setState(() => _busy = false); }
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Row(children: [Icon(Icons.graphic_eq, color: Color(0xff27ded6)), SizedBox(width: 10), Text('HZ STUDIO', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 2))])),
    bottomNavigationBar: NavigationBar(selectedIndex: _tab, onDestinationSelected: (i) { _stop(); setState(() { _tab = i; _error = null; }); },
      destinations: const [NavigationDestination(icon: Icon(Icons.waves), label: 'Générateur'), NavigationDestination(icon: Icon(Icons.library_music), label: 'Lecteur')]),
    body: SafeArea(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760),
      child: ListView(padding: const EdgeInsets.all(20), children: [
        if (_tab == 0) ..._generatorWidgets() else ..._playerWidgets(),
        if (_error != null) Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Text(_error!, style: const TextStyle(color: Colors.orangeAccent))),
      ])))));

  List<Widget> _generatorWidgets() {
    final f = _number(_frequency);
    final label = f == null ? '—' : '${f.toStringAsFixed(f % 1 == 0 ? 0 : 2)} Hz';
    return [
      const Text('Laboratoire de fréquences', style: TextStyle(color: Colors.white70)),
      const SizedBox(height: 22),
      Container(padding: const EdgeInsets.all(24), decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xff102e40), Color(0xff17152e)]), borderRadius: BorderRadius.circular(24)),
        child: Column(children: [
          const Text('FRÉQUENCE ACTIVE', style: TextStyle(letterSpacing: 2, color: Colors.white70)),
          const SizedBox(height: 18), FittedBox(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 58, color: Color(0xff71fff0)))),
          const SizedBox(height: 16), Text(_schumann ? 'Modulation à 7,83 Hz sur porteuse audible de 220 Hz' : 'Générateur de signal audio', textAlign: TextAlign.center),
          const SizedBox(height: 22), FilledButton.icon(onPressed: _busy ? null : (_playing ? _stop : _generate),
            icon: Icon(_playing ? Icons.stop : Icons.play_arrow), label: Text(_busy ? 'PRÉPARATION…' : (_playing ? 'ARRÊTER' : 'ÉCOUTER'))),
        ])),
      const SizedBox(height: 22),
      TextField(controller: _frequency, keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Fréquence personnalisée (Hz)', helperText: '0,1 à 15 000 Hz'),
        onChanged: (_) { if (_playing) _stop(); setState(() { _schumann = false; _error = null; }); }),
      const SizedBox(height: 20), const Text('PRÉRÉGLAGES', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.5)),
      const SizedBox(height: 12), Wrap(spacing: 8, runSpacing: 8, children: [for (final p in presets) ActionChip(label: Text(p.$1), onPressed: () => _choose(p.$2, p.$3))]),
      const SizedBox(height: 24), Row(children: [const Expanded(child: Text('Volume')), Text('${(_volume * 100).round()} %')]),
      Slider(value: _volume, min: 0, max: .6, onChanged: (v) { setState(() => _volume = v); if (_playing) _stop(); }),
      DropdownButtonFormField<String>(initialValue: _wave,
        decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Forme d’onde'),
        items: ['Sinusoïde', 'Triangle', 'Carrée'].map((w) => DropdownMenuItem(value: w, child: Text(w))).toList(),
        onChanged: (v) { if (v != null) { setState(() => _wave = v); if (_playing) _stop(); } }),
      const SizedBox(height: 20), const Text('Commencez avec un volume faible. Le mode Schumann utilise une modulation audible, pas une émission directe d’infrasons.', style: TextStyle(color: Colors.white54, fontSize: 12)),
    ];
  }
  List<Widget> _playerWidgets() => [
    const Text('LECTEUR ET ACCORDAGE', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.5)),
    const SizedBox(height: 10),
    const Text('Modifiez la hauteur musicale d’un extrait sans changer sa durée. Premier algorithme expérimental : de légers artefacts peuvent être audibles.', style: TextStyle(color: Colors.white70)),
    const SizedBox(height: 22),
    OutlinedButton.icon(onPressed: _busy ? null : _importAudio, icon: const Icon(Icons.folder_open), label: const Text('IMPORTER UNE MUSIQUE')),
    const SizedBox(height: 12),
    Text(_filename == null ? 'Aucun fichier chargé' : '$_filename • ${_imported!.duration.toStringAsFixed(1)} s max.', style: const TextStyle(color: Color(0xff71fff0))),
    const SizedBox(height: 16),
    const Text('ACCORDAGE (HZ)', style: TextStyle(letterSpacing: 1.5)),
    const SizedBox(height: 12), Row(children: [
      Expanded(child: TextField(controller: _reference, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Source'))),
      const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Icon(Icons.arrow_forward)),
      Expanded(child: TextField(controller: _target, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Cible'))),
    ]),
    const SizedBox(height: 12), Wrap(spacing: 8, children: [
      ActionChip(label: const Text('440 → 432'), onPressed: () { _reference.text = '440'; _target.text = '432'; setState(() {}); }),
      ActionChip(label: const Text('432 → 440'), onPressed: () { _reference.text = '432'; _target.text = '440'; setState(() {}); }),
    ]),
    const SizedBox(height: 20), FilledButton.icon(onPressed: _busy ? null : (_playing ? _stop : _playShifted),
      icon: Icon(_playing ? Icons.stop : Icons.play_arrow), label: Text(_busy ? 'TRAITEMENT…' : (_playing ? 'ARRÊTER' : 'ÉCOUTER L’EXTRAIT'))),
    const SizedBox(height: 22),
    const Text('V8 : MP3, FLAC, OGG, Opus, WAV, M4A et autres formats selon le décodeur disponible. Aperçu de 20 secondes, converti en mono. La lecture intégrale, la stéréo et l’export viendront ensuite.', style: TextStyle(color: Colors.white54, fontSize: 12)),
  ];
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
