"""HZ Studio V12: WASAPI loopback -> pitch shift -> separate output.

Prototype only. No interception/decryption of streaming media.
"""
import argparse
import json
import math
import sys


def outputs():
    import sounddevice as sd
    devices = sd.query_devices()
    default = int(sd.default.device[1])
    result = []
    for i, d in enumerate(devices):
        if d['max_output_channels'] > 0 and d['hostapi'] >= 0:
            result.append({'id': i, 'name': d['name'], 'default': i == default})
    return result, default


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--list', action='store_true')
    parser.add_argument('--output', type=int)
    parser.add_argument('--ratio', type=float, default=432 / 440)
    args = parser.parse_args()
    if args.list:
        devices, _ = outputs()
        print(json.dumps(devices, ensure_ascii=False), flush=True)
        return 0

    import numpy as np
    import soundcard as sc
    import sounddevice as sd
    from pedalboard import Pedalboard, PitchShift

    devices, default = outputs()
    chosen = next((d for d in devices if d['id'] == args.output), None)
    if chosen is None:
        raise ValueError('Choisir une sortie audio valide.')
    if chosen['id'] == default:
        raise ValueError('Sortie par défaut interdite : risque de boucle audio.')
    if not (0.7 <= args.ratio <= 1.4) or not math.isfinite(args.ratio):
        raise ValueError('Rapport d’accordage invalide.')

    # Capture the default playback endpoint using its Windows WASAPI loopback.
    speaker = sc.default_speaker()
    if speaker is None:
        raise RuntimeError('Aucune sortie système à capturer.')
    mic = sc.get_microphone(id=str(speaker.id), include_loopback=True)
    if mic is None:
        raise RuntimeError('Loopback WASAPI non disponible.')
    rate = 48000
    block = 4096
    shift = Pedalboard([PitchShift(semitones=12 * math.log2(args.ratio))])
    print('READY', flush=True)
    print('Capture:', speaker.name, flush=True)
    print('Destination:', chosen['name'], flush=True)
    print('Utiliser uniquement la destination séparée.', flush=True)
    with mic.recorder(samplerate=rate, channels=2, blocksize=block) as recorder:
        with sd.OutputStream(samplerate=rate, channels=2, device=args.output,
                             blocksize=block, dtype='float32') as stream:
            print('RUNNING', flush=True)
            while True:
                buffer = recorder.record(numframes=block).astype(np.float32)
                if buffer.ndim == 1:
                    buffer = np.column_stack((buffer, buffer))
                # pedalboard expects channels first, contiguous samples.
                processed = shift(buffer.T.copy(), rate, reset=False)
                stream.write(np.clip(processed.T, -1, 1).astype(np.float32))


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
    except Exception as e:
        print('ERROR: ' + str(e), file=sys.stderr, flush=True)
        sys.exit(1)
