"""Evaluate NEXT CTC on windows produced from complete input recordings."""
import json
import numpy as np
import soundfile as sf
import torch

from evaluate_ctc_fixed import score, view
from export_ctc_fpga import ROOT, load
from kws_common import decimate, log4, mel_powers, pcm48
from probe_vad_continuity import gated_features
from robust_common import utterances
from train_directional_ctc import PHRASES

DATA = ROOT.parent.parent / 'voice'


def raw_features(power):
    logs = log4(power)
    f = np.clip(logs - logs.max(1, keepdims=True) + 64, 0, 64)
    f[power.max(1) < 512] = 0
    n = len(f) // 2
    return ((f[:2*n:2] + f[1:2*n:2]) >> 1).astype(np.int8)


def prepare(row, manifest_root):
    audio, sr = sf.read(manifest_root / row['path'])
    if audio.ndim == 2:
        audio = audio.mean(1)
    pcm = np.r_[np.zeros(49152, dtype=np.int16), pcm48(audio, sr), np.zeros(73728, dtype=np.int16)]
    power = mel_powers(decimate(pcm))
    raw = raw_features(power)
    gate = gated_features(power, 'hysteresis')
    gate = np.r_[np.zeros((64, 16), dtype=np.int8), gate]
    pairs = list(utterances(gate, prequiet=6))
    if not pairs:
        return []
    active = max(1, np.count_nonzero(np.any(gate, axis=1)))
    output = []
    for start, end in pairs:
        coverage = np.count_nonzero(np.any(gate[start:end], axis=1)) / active
        # One representative endpoint per recording, chosen as the one
        # containing most of the speech energy, matching the board's one-shot VAD.
        end = min(end, start + 64)
        start = max(0, end - 48)
        x = np.zeros((48, 16), dtype=np.int8)
        source = raw[start:end]
        x[48-len(source):] = source
        x[:max(0, start - max(0, end - 48))] = 0
        output.append((x, coverage, start, end))
    return output


def main():
    torch.set_num_threads(2)
    manifest = DATA / 'data/manifest.json'
    rows = json.loads(manifest.read_text(encoding='utf-8'))
    manifest_root = manifest.parent.parent
    net = load()
    reports = {}
    for split in ['validation', 'test']:
        xs, labels, owners, meta = [], [], [], []
        for ri, row in enumerate(rows):
            if row['split'] != split:
                continue
            clips = prepare(row, manifest_root)
            if not clips:
                xs.append(np.zeros((8, 16), dtype=np.int8))
                meta.append([])
            else:
                clips.sort(key=lambda v: (v[1], v[3] - v[2]), reverse=True)
                xs.append(clips[0][0])
                meta.append(clips)
            labels.append(1 if row['label'] == 1 else 0)
        # Fold the three scale scores exactly as the RTL: it normalizes each
        # view back to the original utterance length before summing.
        views = [[view(x, p) for x in xs] for p in range(3)]
        scale_scores = [score(net, values) for values in views]
        scores = sum(np.trunc(s * np.array([len(x) for x in xs])[:, None] /
                              np.array([len(v) for v in values])[:, None]).astype(np.int64)
                     for s, values in zip(scale_scores, views))
        idx = PHRASES.index('下一张')
        pred = []
        details = []
        for x, row, label, clips in zip(xs, scores, labels, meta):
            rival = np.max(np.delete(row, idx))
            gap = int(row[idx] - rival)
            floor = int(row[idx]) * 10 >= -len(x) * 192
            accepted = row[idx] > rival and gap >= 1152 and floor
            pred.append(int(accepted))
            details.append(dict(label=label, frames=len(x), accepted=bool(accepted), gap=gap,
                                next_score=int(row[idx]), rival=int(rival),
                                segment_count=len(clips), segments=[list(v[1:]) for v in clips]))
        cm = np.zeros((2, 2), dtype=int)
        for y, p in zip(labels, pred):
            cm[y, p] += 1
        reports[split] = dict(confusion=cm.tolist(), correct=int(cm[1, 1]),
                              false_accepts=int(cm[0, 1]), total=len(labels), details=details)
        print(split, {k:v for k,v in reports[split].items() if k != 'details'}, flush=True)
    (ROOT / 'verification/recording_windows_next.json').write_text(
        json.dumps(reports, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()
