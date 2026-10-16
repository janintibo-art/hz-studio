import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

class LiveAudioPanel extends StatefulWidget {
  const LiveAudioPanel({super.key});

  @override
  State<LiveAudioPanel> createState() => _LiveAudioPanelState();
}

class _LiveAudioPanelState extends State<LiveAudioPanel> {
  Process? _process;
  List<Map<String, dynamic>> _devices = [];
  int? _selected;
  double _source = 440;
  double _target = 432;
  bool _loading = false;
  String _status = 'Arrêté';

  String get _exe =>
      '${File(Platform.resolvedExecutable).parent.path}\\hz_live_bridge.exe';

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) _loadDevices();
  }

  Future<void> _loadDevices() async {
    if (!Platform.isWindows || _loading || _process != null) return;
    setState(() { _loading = true; _status = 'Recherche des sorties audio…'; });
    try {
      if (!await File(_exe).exists()) {
        throw const FormatException('Moteur Live absent du dossier Windows.');
      }
      final result = await Process.run(_exe, ['--list']);
      if (result.exitCode != 0) throw FormatException('${result.stderr}');
      final data = (jsonDecode('${result.stdout}') as List).cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        _devices = data;
        if (!_devices.any((e) => e['id'] == _selected && e['default'] != true)) {
          _selected = null;
        }
        _status = 'Sélectionnez une sortie différente de la sortie Windows par défaut.';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'Erreur : $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _start() async {
    if (_selected == null || _loading || _process != null) return;
    setState(() { _loading = true; _status = 'Démarrage du moteur…'; });
    try {
      final process = await Process.start(_exe, [
        '--output', '$_selected', '--ratio', '${_target / _source}',
      ]);
      if (!mounted) { process.kill(); return; }
      _process = process;
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        if (mounted && identical(_process, process) && line.isNotEmpty) {
          setState(() => _status = line);
        }
      });
      process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        if (mounted && identical(_process, process) && line.isNotEmpty) {
          setState(() => _status = line);
        }
      });
      process.exitCode.then((code) {
        if (mounted && identical(_process, process)) {
          setState(() { _process = null; _status = 'Moteur arrêté (code $code).'; });
        }
      });
      setState(() => _status = 'Connexion en cours…');
    } catch (e) {
      if (mounted) setState(() => _status = 'Impossible de démarrer : $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _stop() {
    _process?.kill();
    _process = null;
    if (mounted) setState(() => _status = 'Arrêté');
  }

  @override
  void dispose() {
    _process?.kill();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const cyan = Color(0xff70fff0);
    if (!Platform.isWindows) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(children: [
            Icon(Icons.smartphone, color: cyan, size: 44),
            SizedBox(height: 14),
            Text('LIVE AUDIO — WINDOWS', style: TextStyle(fontWeight: FontWeight.bold)),
            SizedBox(height: 12),
            Text('La capture audio des autres applications Android est limitée par le système et par chaque application. Cette fonction est pour le moment réservée au PC.', textAlign: TextAlign.center),
          ]),
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('LIVE AUDIO', style: TextStyle(fontSize: 25, fontWeight: FontWeight.w900, letterSpacing: 2)),
      const SizedBox(height: 8),
      const Text('Prototype Windows : capture WASAPI du son diffusé par le PC et accordage à durée constante.', style: TextStyle(color: Color(0xffa3c5cb))),
      const SizedBox(height: 18),
      Card(child: Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('ROUTAGE AUDIO', style: TextStyle(color: cyan, fontWeight: FontWeight.bold, letterSpacing: 2)),
        const SizedBox(height: 12),
        const Text('1. Laissez Spotify, le navigateur ou une autre application jouer sur la sortie Windows par défaut.\n2. Branchez un autre périphérique, par exemple un casque USB.\n3. Sélectionnez ce second périphérique ci-dessous.\n4. Pour éviter d’entendre le son original, utilisez un périphérique de capture qui ne s’écoute pas en parallèle.'),
        const SizedBox(height: 16),
        DropdownButtonFormField<int>(
          value: _selected,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Destination du son traité'),
          items: _devices.where((d) => d['default'] != true).map((d) => DropdownMenuItem<int>(
            value: d['id'] as int,
            child: Text('${d['name']}', overflow: TextOverflow.ellipsis),
          )).toList(),
          onChanged: _process == null && !_loading ? (v) => setState(() => _selected = v) : null,
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(onPressed: _loading || _process != null ? null : _loadDevices,
          icon: const Icon(Icons.refresh), label: const Text('ACTUALISER LES PÉRIPHÉRIQUES')),
      ]))),
      const SizedBox(height: 14),
      Card(child: Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('ACCORDAGE EN DIRECT', style: TextStyle(color: cyan, fontWeight: FontWeight.bold, letterSpacing: 2)),
        const SizedBox(height: 18),
        Text('Source : ${_source.round()} Hz'),
        Slider(value: _source, min: 400, max: 480, divisions: 80, onChanged: _process == null ? (v) => setState(() => _source = v) : null),
        Text('Cible : ${_target.round()} Hz'),
        Slider(value: _target, min: 400, max: 480, divisions: 80, onChanged: _process == null ? (v) => setState(() => _target = v) : null),
        Text('Rapport ${(_target / _source).toStringAsFixed(5)} • traitement expérimental', style: const TextStyle(color: Color(0xffa3c5cb))),
        const SizedBox(height: 18),
        SizedBox(width: double.infinity, child: FilledButton.icon(
          onPressed: _loading ? null : (_process != null ? _stop : (_selected == null ? null : _start)),
          icon: Icon(_process != null ? Icons.stop : Icons.play_arrow),
          label: Text(_process != null ? 'ARRÊTER LE LIVE' : 'DÉMARRER LE LIVE'),
        )),
        const SizedBox(height: 12),
        Text(_status, style: const TextStyle(color: cyan)),
      ]))),
      const SizedBox(height: 14),
      const Text('Bêta : il peut y avoir de la latence, des artefacts et des incompatibilités de périphériques. Capture uniquement le son que Windows autorise à capter. Aucun contournement de DRM. Le réglage ne s’applique pas à la sortie audio système d’origine.', style: TextStyle(color: Color(0xff8cadb6), height: 1.5)),
    ]);
  }
}
