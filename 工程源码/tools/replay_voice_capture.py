"""Reproduce on-board inference from CRC-protected features, without guessing labels."""
from pathlib import Path
import argparse
import hashlib
import json
import sys

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'voice/tools'))
from kws_common import integer_infer, read_hex
from robust_common import normalized_windows
from decode_voice_capture import packets, REASONS


def replay(path, model, recognizer='normalized'):
    raw = path.read_bytes()
    blocks, bad = packets(raw)
    if bad or len(blocks) < 48:
        raise ValueError('Capture must contain at least 48 valid frames and no CRC errors')
    frames = [int.from_bytes(b[3:5], 'little') for b in blocks]
    if any(b != (a + 1) & 65535 for a, b in zip(frames, frames[1:])):
        raise ValueError('Capture has frame gaps; exact replay is unavailable')
    if any(b[71] & 1 for b in blocks):
        raise ValueError('Reporter overrun flag is set; obtain a fresh capture')
    f = np.array([list(b[12:28]) for b in blocks], dtype=np.int8)
    cfg = json.loads((model / 'config.json').read_text())
    w = read_hex(model / 'weights.mem', 8)
    bias = read_hex(model / 'bias.mem', 32)
    attempts = []
    start = None
    quiet = voiced = 0
    for i, row in enumerate(f):
        if row.any():
            if start is None:
                start = i
            voiced += 1
            quiet = 0
        elif start is not None:
            quiet += 1
        if start is None or quiet != 6:
            continue
        # The capture may begin during an existing utterance. Require an
        # observed quiet boundary before claiming an exact reconstruction.
        complete = start >= 6 and not f[start-6:start].any()
        seq = int.from_bytes(blocks[i][9:11], 'little')
        committed = next((b for b in blocks[i:] if
                          int.from_bytes(b[9:11], 'little') == seq and not b[11] & 8), None)
        item = dict(sequence=seq, start_frame=start, end_frame=i + 1,
                    start_seconds=round(start * .032, 3), voiced_frames=voiced,
                    duration_frames=i-start+1, complete=complete,
                    active_pattern=''.join('+' if a.any() else '.' for a in f[start:i-5]))
        if committed is not None:
            flags = committed[6]
            item['flags'] = flags
            item['reasons'] = [r for bit, r in enumerate(REASONS) if flags & (1 << bit)]
            # A zero logit block on a gate rejection is not model background.
            if complete and not flags & 15 and voiced >= 6 and i-start+1 <= (64 if recognizer=='sensitive' else 96):
                if recognizer=='sensitive':
                    window=np.zeros((48,16),dtype=np.int8)
                    lo=max(start,i+1-48)
                    window[lo-(i+1-48):]=f[lo:i+1]
                    inputs=window.reshape(1,768)
                else:inputs=normalized_windows(f,start,i+1)
                z = integer_infer(inputs,
                                  w[:36864].reshape(48, 768), bias[:48],
                                  w[36864:].reshape(3, 48), bias[48:], cfg['shift'])
                actual = np.frombuffer(committed[28:64], dtype='<i4').reshape(3, 3)
                if recognizer=='sensitive':
                    if np.any(actual[1:]):raise ValueError('Single-pass mode selected, but telemetry has additional logits')
                    actual=actual[:1]
                item.update(reference_logits=z.tolist(), hardware_logits=actual.tolist(),
                            exact_match=bool(np.array_equal(z, actual)))
        attempts.append(item)
        start = None
        quiet = voiced = 0
    compared = [a for a in attempts if 'exact_match' in a]
    return dict(raw_sha256=hashlib.sha256(raw).hexdigest(), model=str(model.resolve()),
                model_sha256={n: hashlib.sha256((model/n).read_bytes()).hexdigest()
                              for n in ['weights.mem', 'bias.mem', 'config.json']},
                valid_packets=len(blocks), inferred_attempts=len(compared),
                all_compared_logits_match=all(a['exact_match'] for a in compared) if compared else None,
                labels_confirmed=False, recognizer=recognizer, attempts=attempts)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('capture', type=Path)
    ap.add_argument('--model', type=Path)
    ap.add_argument('--recognizer',choices=['normalized','sensitive'],default='normalized')
    args = ap.parse_args()
    model=args.model or (ROOT/'voice/model' if args.recognizer=='sensitive' else ROOT/'voice/experiments/robust_normalized/model')
    report = replay(args.capture, model,args.recognizer)
    out = args.capture.with_suffix('.replay.json')
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf8')
    print(json.dumps(report, ensure_ascii=False, indent=2))
    if report['all_compared_logits_match'] is False:
        raise SystemExit('Hardware/reference mismatch: do not adapt this model until resolved')


if __name__ == '__main__':
    main()
