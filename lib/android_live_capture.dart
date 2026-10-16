import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AndroidLiveCapturePanel extends StatefulWidget {
  const AndroidLiveCapturePanel({super.key});

  @override
  State<AndroidLiveCapturePanel> createState() => _AndroidLiveCapturePanelState();
}

class _AndroidLiveCapturePanelState extends State<AndroidLiveCapturePanel> {
  static const _channel = MethodChannel('hz_studio/android_live');
  Timer? _timer;
  bool _working = false;
  bool _running = false;
  double _level = 0;
  String _message = 'Appuyer sur DÉMARRER pour autoriser la capture.';

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 450), (_) => _status());
    _status();
  }

  Future<void> _status() async {
    if (!mounted) return;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('status');
      if (!mounted || result == null) return;
      setState(() {
        _running = result['running'] == true;
        _level = ((result['level'] as num?)?.toDouble() ?? 0).clamp(0, 1);
        _message = result['message'] as String? ?? 'Statut indisponible';
      });
    } catch (e) {
      if (mounted) setState(() => _message = 'Module Android indisponible : $e');
    }
  }

  Future<void> _start() async {
    setState(() => _working = true);
    try {
      final accepted = await _channel.invokeMethod<bool>('start') ?? false;
      if (!accepted && mounted) setState(() => _message = 'Autorisation refusée.');
      await Future<void>.delayed(const Duration(milliseconds: 650));
      await _status();
    } catch (e) {
      if (mounted) setState(() => _message = 'Démarrage impossible : $e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _stop() async {
    setState(() => _working = true);
    try {
      await _channel.invokeMethod<bool>('stop');
      await _status();
    } catch (e) {
      if (mounted) setState(() => _message = 'Arrêt impossible : $e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const cyan = Color(0xff70fff0);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('LIVE AUDIO • ANDROID', style: TextStyle(fontSize: 23, fontWeight: FontWeight.w900, letterSpacing: 1.3)),
      const SizedBox(height: 12),
      const Text('V13 : diagnostic de capture audio des autres applications compatibles. Autorisation Android obligatoire. Aucune musique n’est enregistrée et aucun traitement 432 Hz n’est encore diffusé.', style: TextStyle(color: Color(0xff9ac2cb), height: 1.5)),
      const SizedBox(height: 20),
      Card(child: Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('NIVEAU AUDIO CAPTURÉ', style: TextStyle(color: cyan, fontWeight: FontWeight.w700, letterSpacing: 1.8)),
        const SizedBox(height: 16),
        LinearProgressIndicator(value: _level, minHeight: 16, borderRadius: BorderRadius.circular(12), color: cyan, backgroundColor: const Color(0xff1b3545)),
        const SizedBox(height: 12),
        Text('${(_level * 100).round()} %  •  ${_running ? 'SESSION ACTIVE' : 'ARRÊTÉ'}', style: const TextStyle(color: cyan)),
        const SizedBox(height: 16),
        FilledButton.icon(onPressed: _working ? null : (_running ? _stop : _start), icon: Icon(_running ? Icons.stop : Icons.fiber_manual_record), label: Text(_running ? 'ARRÊTER LA CAPTURE' : 'DEMANDER L’AUTORISATION ET DÉMARRER')),
        const SizedBox(height: 12),
        Text(_message, style: const TextStyle(color: Color(0xffb3d6dd))),
      ]))),
      const SizedBox(height: 16),
      const Text('Test : lancez une radio ou une vidéo dans une application qui autorise la capture. Si le niveau reste à zéro, l’application source peut bloquer la capture. Ce module ne contourne pas les protections audio.', style: TextStyle(color: Color(0xff8cadb6), height: 1.5)),
    ]);
  }
}
