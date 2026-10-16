import 'dart:async';
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
import 'studio_visuals.dart';

void main() => runApp(const HzStudio());

class HzStudio extends StatelessWidget {
  const HzStudio({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HZ Studio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xff27ded6),
        scaffoldBackgroundColor: const Color(0xff050b14),
        fontFamily: null,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        cardTheme: CardThemeData(
          color: const Color(0xff081523),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: const BorderSide(color: Color(0xff133a4a)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xff071523),
          labelStyle: const TextStyle(color: Color(0xff9fc8cf)),
          helperStyle: const TextStyle(color: Color(0xff5f8390)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: Color(0xff1d4d5e)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: Color(0xff70fff0), width: 1.4),
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
      ),
      home: const StudioPage(),
    );
  }
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
  Uint8List? _processedWav;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _paused = false;
  late final StreamSubscription<Duration> _positionSubscription;
  late final StreamSubscription<Duration> _durationSubscription;
  late final StreamSubscription<void> _completeSubscription;
  int _generation = 0;
  final List<File> _tempFiles = [];

  static const presets = <(String, double, bool)>[
    ('La 440', 440, false),
    ('La 432', 432, false),
    ('174 Hz', 174, false),
    ('396 Hz', 396, false),
    ('528 Hz', 528, false),
    ('639 Hz', 639, false),
    ('741 Hz', 741, false),
    ('852 Hz', 852, false),
    ('963 Hz', 963, false),
    ('Schumann 7,83 Hz', 7.83, true),
  ];

  @override
  void initState() {
    super.initState();
    _positionSubscription = _player.onPositionChanged.listen((value) {
      if (mounted) setState(() => _position = value);
    });
    _durationSubscription = _player.onDurationChanged.listen((value) {
      if (mounted) setState(() => _duration = value);
    });
    _completeSubscription = _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() {
        _playing = false;
        _paused = false;
        _position = Duration.zero;
      });
    });
  }

  @override
  void dispose() {
    _generation++;
    _positionSubscription.cancel();
    _durationSubscription.cancel();
    _completeSubscription.cancel();
    _player.dispose();
    _frequency.dispose();
    _reference.dispose();
    _target.dispose();
    for (final f in _tempFiles) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
    super.dispose();
  }

  double? _number(TextEditingController c) =>
      double.tryParse(c.text.trim().replaceAll(',', '.'));

  Future<void> _stop() async {
    _generation++;
    try {
      await _player.stop();
    } catch (_) {}
    if (mounted) {
      setState(() {
        _playing = false;
        _paused = false;
        _position = Duration.zero;
      });
    }
  }

  Future<void> _togglePause() async {
    if (!_playing) return;
    try {
      if (_paused) {
        await _player.resume();
      } else {
        await _player.pause();
      }
      if (mounted) setState(() => _paused = !_paused);
    } catch (e) {
      if (mounted) setState(() => _error = 'Pause impossible : $e');
    }
  }

  String _clock(Duration value) {
    final seconds = value.inSeconds.clamp(0, 86400);
    return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _saveProcessed() async {
    final data = _processedWav;
    if (data == null) return;
    try {
      final target = await FilePicker.platform.saveFile(
        dialogTitle: 'Exporter l’extrait transformé',
        fileName: 'hz_studio_accordage.wav',
        type: FileType.custom,
        allowedExtensions: ['wav'],
        bytes: data,
      );
      if (target != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Extrait WAV exporté.')),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Export impossible : $e');
    }
  }

  void _choose(double freq, bool schumann) {
    _frequency.text = freq.toString().replaceAll('.', ',');
    setState(() {
      _schumann = schumann;
      _error = null;
    });
    if (_playing) _stop();
  }

  Future<void> _playBytes(Uint8List wav, {bool loop = false}) async {
    final gen = ++_generation;
    await _player.stop();
    if (mounted) setState(() {
      _position = Duration.zero;
      _duration = Duration.zero;
      _paused = false;
    });
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/hzstudio_${DateTime.now().microsecondsSinceEpoch}.wav',
    );
    await file.writeAsBytes(wav, flush: true);
    _tempFiles.add(file);
    await _player.setReleaseMode(loop ? ReleaseMode.loop : ReleaseMode.stop);
    if (!mounted || gen != _generation) return;
    await _player.play(DeviceFileSource(file.path));
    if (mounted && gen == _generation) {
      setState(() => _playing = true);
    }
    if (_tempFiles.length > 4) {
      final old = _tempFiles.removeAt(0);
      try {
        await old.delete();
      } catch (_) {}
    }
  }

  Future<void> _generate() async {
    final f = _number(_frequency);
    if (f == null || !f.isFinite || f < 0.1 || f > 15000) {
      setState(() => _error = 'Fréquence autorisée : 0,1 à 15 000 Hz.');
      return;
    }
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      final wav = await Isolate.run(() => makeWav(f, _volume, _wave, _schumann));
      if (mounted) await _playBytes(wav, loop: true);
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Lecture impossible : $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Uint8List> _decodeSelectedAudio(String path) async {
    if (Platform.isAndroid) {
      const channel = MethodChannel('hz_studio/audio_decode');
      final wavPath = await channel
          .invokeMethod<String>('decodePreview', {'path': path});
      if (wavPath == null) {
        throw const FormatException('Décodage Android indisponible.');
      }
      final file = File(wavPath);
      try {
        return await file.readAsBytes();
      } finally {
        try {
          await file.delete();
        } catch (_) {}
      }
    }
    if (Platform.isWindows) {
      final exe = File(
          '${File(Platform.resolvedExecutable).parent.path}\\ffmpeg.exe');
      if (!await exe.exists()) {
        throw const FormatException('ffmpeg.exe absent du dossier Windows.');
      }
      final dir = await getTemporaryDirectory();
      final output = File(
        '${dir.path}\\hz_decode_${DateTime.now().microsecondsSinceEpoch}.wav',
      );
      try {
        final process = await Process.run(exe.path, [
          '-hide_banner',
          '-loglevel',
          'error',
          '-nostdin',
          '-y',
          '-i',
          path,
          '-t',
          '20',
          '-vn',
          '-ac',
          '1',
          '-ar',
          '44100',
          '-c:a',
          'pcm_s16le',
          output.path,
        ]);
        if (process.exitCode != 0) {
          throw FormatException('FFmpeg : ${process.stderr}');
        }
        return await output.readAsBytes();
      } finally {
        if (await output.exists()) await output.delete();
      }
    }
    throw const FormatException('Plateforme non prise en charge.');
  }

  Future<void> _importAudio() async {
    await _stop();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final pick = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          'mp3',
          'mp2',
          'flac',
          'ogg',
          'opus',
          'wav',
          'aiff',
          'aif',
          'aac',
          'm4a',
          'wma',
          'ape',
          'wv',
          'tta',
          'ac3',
          'mka',
        ],
        withData: false,
      );
      if (pick == null || pick.files.isEmpty) return;
      final selected = pick.files.single;
      if (selected.path == null) {
        throw const FormatException(
          'Impossible de lire le chemin du fichier.',
        );
      }
      final bytes = await _decodeSelectedAudio(selected.path!);
      final pcm = await Isolate.run(() => readPcmWav(bytes));
      if (mounted) {
        setState(() {
          _imported = pcm;
          _filename = selected.name;
          _processedWav = null;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Import impossible : $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _playShifted() async {
    final a = _number(_reference);
    final b = _number(_target);
    if (_imported == null) {
      setState(() => _error = 'Importez d’abord une musique.');
      return;
    }
    if (a == null ||
        b == null ||
        !a.isFinite ||
        !b.isFinite ||
        a < 100 ||
        a > 1000 ||
        b < 100 ||
        b > 1000) {
      setState(() {
        _error = 'Références d’accordage autorisées : 100 à 1 000 Hz.';
      });
      return;
    }
    final ratio = b / a;
    if (ratio < .7 || ratio > 1.4) {
      setState(() {
        _error = 'Écart trop important pour cet algorithme (70–140 %).';
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final pcm = _imported!;
      final audio = await Isolate.run(
        () => shiftPitch(pcm.samples, ratio, pcm.sampleRate),
      );
      final wav = await Isolate.run(() => encodePcmWav(audio, pcm.sampleRate));
      if (mounted) {
        setState(() => _processedWav = wav);
        await _playBytes(wav);
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Traitement impossible : $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xff050b14), Color(0xff091725), Color(0xff050d18)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 940),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 110),
                children: [
                  _buildHeader(),
                  const SizedBox(height: 20),
                  if (_tab == 0) ..._generatorWidgets() else ..._playerWidgets(),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    _errorPanel(_error!),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(26),
          child: NavigationBar(
            height: 76,
            backgroundColor: const Color(0xee08131f),
            indicatorColor: const Color(0xff153845),
            selectedIndex: _tab,
            onDestinationSelected: (i) {
              _stop();
              setState(() {
                _tab = i;
                _error = null;
              });
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.tune),
                label: 'Générateur',
              ),
              NavigationDestination(
                icon: Icon(Icons.library_music),
                label: 'Lecteur',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: const LinearGradient(
          colors: [Color(0xff081524), Color(0xff102434), Color(0xff0d1a27)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: const Color(0xff173f4f)),
        boxShadow: const [
          BoxShadow(color: Color(0x2600ffe8), blurRadius: 26),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: const Color(0xff0b2534),
              border: Border.all(color: const Color(0xff1b5b6a)),
            ),
            child: const Icon(
              Icons.graphic_eq_rounded,
              color: Color(0xff70fff0),
              size: 34,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'HZ STUDIO',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 3,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _tab == 0
                      ? 'Générateur audio • fréquence, modulation et préréglages'
                      : 'Lecteur audio • import, accordage et aperçu du signal',
                  style: const TextStyle(
                    color: Color(0xff9dc0c8),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _smallInfoChip(
            icon: _busy ? Icons.hourglass_top : Icons.check_circle,
            label: _busy ? 'TRAITEMENT' : 'PRÊT',
          ),
        ],
      ),
    );
  }

  Widget _smallInfoChip({required IconData icon, required String label}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: const Color(0xff0b2432),
        border: Border.all(color: const Color(0xff215464)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: const Color(0xff70fff0), size: 16),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              letterSpacing: 1.1,
              color: Color(0xffd1fef9),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _generatorWidgets() {
    final f = _number(_frequency) ?? 432;
    final label = f.toStringAsFixed(f % 1 == 0 ? 0 : 2);
    return [
      _heroPanel(
        title: 'FRÉQUENCE ACTIVE',
        value: '$label Hz',
        subtitle: _schumann
            ? 'Mode Schumann : modulation 7,83 Hz sur porteuse audible'
            : 'Générateur de signal audio en direct',
        action: FilledButton.icon(
          onPressed: _busy ? null : (_playing ? _stop : _generate),
          icon: Icon(_playing ? Icons.stop : Icons.play_arrow),
          label: Text(
            _busy ? 'PRÉPARATION…' : (_playing ? 'ARRÊTER' : 'ÉCOUTER'),
          ),
        ),
      ),
      const SizedBox(height: 18),
      StudioSignalPanel(
        frequency: f,
        playing: _playing && _tab == 0,
        title: 'OSCILLOSCOPE GÉNÉRATEUR',
      ),
      const SizedBox(height: 18),
      _statGrid([
        _statCard('Forme d’onde', _wave, Icons.waves),
        _statCard('Volume', '${(_volume * 100).round()} %', Icons.volume_up),
        _statCard(
          'Mode',
          _schumann ? 'Schumann' : 'Standard',
          Icons.tune,
        ),
      ]),
      const SizedBox(height: 18),
      _sectionPanel(
        title: 'RÉGLAGES DU GÉNÉRATEUR',
        icon: Icons.settings_input_component,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _frequency,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Fréquence personnalisée (Hz)',
                helperText: 'De 0,1 à 15 000 Hz',
                prefixIcon: Icon(Icons.tune),
              ),
              onChanged: (_) {
                if (_playing) _stop();
                setState(() {
                  _schumann = false;
                  _error = null;
                });
              },
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _wave,
              decoration: const InputDecoration(
                labelText: 'Forme d’onde',
                prefixIcon: Icon(Icons.show_chart),
              ),
              items: ['Sinusoïde', 'Triangle', 'Carrée']
                  .map((w) => DropdownMenuItem(value: w, child: Text(w)))
                  .toList(),
              onChanged: (v) {
                if (v != null) {
                  setState(() => _wave = v);
                  if (_playing) _stop();
                }
              },
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Volume du générateur',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  '${(_volume * 100).round()} %',
                  style: const TextStyle(color: Color(0xff70fff0)),
                ),
              ],
            ),
            Slider(
              value: _volume,
              min: 0,
              max: .6,
              onChanged: (v) {
                setState(() => _volume = v);
                if (_playing) _stop();
              },
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      _sectionPanel(
        title: 'PRÉRÉGLAGES RAPIDES',
        icon: Icons.bolt,
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final p in presets)
              ActionChip(
                label: Text(p.$1),
                onPressed: () => _choose(p.$2, p.$3),
              ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      _notePanel(
        'Commencez avec un volume faible. Le mode Schumann emploie une modulation audible et non une émission directe d’infrasons.',
      ),
    ];
  }

  List<Widget> _playerWidgets() {
    final reference = _number(_reference) ?? 440;
    final target = _number(_target) ?? 432;
    final ratio = target / reference;
    return [
      _heroPanel(
        title: 'LECTEUR & ACCORDAGE',
        value: _filename ?? 'Aucun fichier',
        subtitle: _filename == null
            ? 'Importe une musique pour la traiter sans changer sa durée.'
            : 'Aperçu importé : ${_imported?.duration.toStringAsFixed(1) ?? '0'} s • formats multiples',
        action: OutlinedButton.icon(
          onPressed: _busy ? null : _importAudio,
          icon: const Icon(Icons.folder_open),
          label: const Text('IMPORTER UNE MUSIQUE'),
        ),
      ),
      const SizedBox(height: 18),
      StudioSignalPanel(
        frequency: ratio * 100,
        playing: _playing && _tab == 1,
        samples: _imported?.samples,
        title: 'APERÇU DU FICHIER',
      ),
      const SizedBox(height: 18),
      _sectionPanel(
        title: 'TRANSPORT AUDIO',
        icon: Icons.play_circle_outline,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Slider(
              value: _duration.inMilliseconds > 0
                  ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
                  : 0.0,
              onChanged: _playing && _duration.inMilliseconds > 0
                  ? (value) => _player.seek(Duration(
                      milliseconds: (_duration.inMilliseconds * value).round()))
                  : null,
            ),
            Row(children: [
              Text(_clock(_position)),
              const Spacer(),
              Text(_clock(_duration)),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: OutlinedButton.icon(
                onPressed: _playing ? _togglePause : null,
                icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
                label: Text(_paused ? 'REPRENDRE' : 'PAUSE'),
              )),
              const SizedBox(width: 10),
              Expanded(child: OutlinedButton.icon(
                onPressed: _playing ? _stop : null,
                icon: const Icon(Icons.stop),
                label: const Text('STOP'),
              )),
            ]),
          ],
        ),
      ),
      const SizedBox(height: 18),
      _statGrid([
        _statCard('Source', _reference.text, Icons.music_note),
        _statCard('Cible', _target.text, Icons.swap_horiz),
        _statCard('Ratio', ratio.toStringAsFixed(3), Icons.speed),
      ]),
      const SizedBox(height: 18),
      _sectionPanel(
        title: 'ACCORDAGE',
        icon: Icons.equalizer,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _reference,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Source',
                      prefixIcon: Icon(Icons.call_made),
                    ),
                    onChanged: (_) => setState(() => _processedWav = null),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(Icons.arrow_forward,
                      color: Color(0xff70fff0)),
                ),
                Expanded(
                  child: TextField(
                    controller: _target,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Cible',
                      prefixIcon: Icon(Icons.call_received),
                    ),
                    onChanged: (_) => setState(() => _processedWav = null),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ActionChip(
                  label: const Text('440 → 432'),
                  onPressed: () {
                    _reference.text = '440';
                    _target.text = '432';
                    setState(() => _processedWav = null);
                  },
                ),
                ActionChip(
                  label: const Text('432 → 440'),
                  onPressed: () {
                    _reference.text = '432';
                    _target.text = '440';
                    setState(() => _processedWav = null);
                  },
                ),
                ActionChip(
                  label: const Text('Copier 432'),
                  onPressed: () async {
                    await Clipboard.setData(const ClipboardData(text: '432'));
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('432 Hz copié.')),
                      );
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _busy ? null : (_playing ? _stop : _playShifted),
                icon: Icon(_playing ? Icons.stop : Icons.play_arrow),
                label: Text(
                  _busy ? 'TRAITEMENT…' : (_playing ? 'ARRÊTER' : 'ÉCOUTER L’EXTRAIT'),
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _processedWav == null || _busy ? null : _saveProcessed,
                icon: const Icon(Icons.save_alt),
                label: const Text('EXPORTER L’EXTRAIT EN WAV'),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      _notePanel(
        'V10 : MP3, FLAC, OGG, Opus, WAV, M4A et autres formats selon le décodeur disponible. Traitement et export WAV limités aux 20 premières secondes, en mono. La lecture intégrale et la stéréo viendront ensuite.',
      ),
    ];
  }

  Widget _heroPanel({
    required String title,
    required String value,
    required String subtitle,
    required Widget action,
  }) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: const LinearGradient(
          colors: [Color(0xff0d2b3a), Color(0xff132236), Color(0xff17152f)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: const Color(0xff1b5261)),
        boxShadow: const [
          BoxShadow(color: Color(0x2a00ffe4), blurRadius: 30),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Color(0xffa8d8df),
              letterSpacing: 2.4,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 42,
              height: 1,
              fontWeight: FontWeight.w900,
              color: Color(0xff70fff0),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            subtitle,
            style: const TextStyle(
              color: Color(0xffd0dee2),
              fontSize: 15,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 20),
          action,
        ],
      ),
    );
  }

  Widget _sectionPanel({
    required String title,
    required IconData icon,
    required Widget child,
  }) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: const Color(0xff70fff0)),
                const SizedBox(width: 10),
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.4,
                    color: Color(0xffd8fbf7),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }

  Widget _statGrid(List<Widget> children) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth > 740;
        if (wide) {
          return Row(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                Expanded(child: children[i]),
                if (i < children.length - 1) const SizedBox(width: 12),
              ],
            ],
          );
        }
        return Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              children[i],
              if (i < children.length - 1) const SizedBox(height: 12),
            ],
          ],
        );
      },
    );
  }

  Widget _statCard(String title, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        color: const Color(0xff081523),
        border: Border.all(color: const Color(0xff153b4b)),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: const Color(0xff0d2432),
            ),
            child: Icon(icon, color: const Color(0xff70fff0)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Color(0xff92b3bc),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xffe4faf6),
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _notePanel(String text) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: const Color(0xff081321),
        border: Border.all(color: const Color(0xff143241)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.info_outline, color: Color(0xff70fff0)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: Color(0xffafc8ce),
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorPanel(String text) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: const Color(0xff2a1116),
        border: Border.all(color: const Color(0xff6f2831)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded,
              color: Colors.orangeAccent),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Colors.orangeAccent, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

Uint8List makeWav(double frequency, double volume, String wave, bool schumann) {
  const rate = 44100;
  const seconds = 4;
  const frames = rate * seconds;
  final b = ByteData(44 + frames * 2);

  void word(int off, int v) => b.setUint32(off, v, Endian.little);

  void half(int off, int v) => b.setUint16(off, v, Endian.little);

  void ascii(int off, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(off + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  word(4, 36 + frames * 2);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  word(16, 16);
  half(20, 1);
  half(22, 1);
  word(24, rate);
  word(28, rate * 2);
  half(32, 2);
  half(34, 16);
  ascii(36, 'data');
  word(40, frames * 2);
  for (var i = 0; i < frames; i++) {
    final t = i / rate;
    final phase = 2 * math.pi * (schumann ? 220.0 : frequency) * t;
    final sinus = math.sin(phase);
    final sample = switch (wave) {
      'Carrée' => sinus >= 0 ? 1.0 : -1.0,
      'Triangle' => 2 / math.pi * math.asin(sinus),
      _ => sinus,
    };
    final mod =
        schumann ? 0.55 + 0.45 * math.sin(2 * math.pi * frequency * t) : 1.0;
    final fade = math.min(1.0, math.min(i / 400.0, (frames - i - 1) / 400.0));
    final v = (sample * mod * volume * fade * 32767)
        .round()
        .clamp(-32768, 32767);
    b.setInt16(44 + i * 2, v, Endian.little);
  }
  return b.buffer.asUint8List();
}
