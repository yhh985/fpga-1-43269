"""Independent integer L1 symmetric2 DTW pilot; training prototypes only.

Algorithm references: Sakoe-Chiba constrained DTW, symmetric2 path normalization.
No source from dtw-python is copied or imported. This pilot does not change RTL.
"""
import os
os.environ.setdefault('OPENBLAS_NUM_THREADS', '1')
from pathlib import Path
import argparse
import hashlib
import json
import sys
import numpy as np
from scipy.cluster.vq import kmeans2
from kws_common import integer_infer, read_hex
from robust_common import decisions, normalized_windows

ROOT = Path(__file__).resolve().parents[2]
EXP = ROOT/'voice/experiments/dtw_pilot'
MODEL = ROOT/'voice/experiments/robust_normalized/model'


def sequences(x):
    # Middle normalized view: two leading and six trailing quiet frames.
    return x.reshape(-1, 3, 48, 16)[:, 1, 2:42][:, np.arange(24)*40//24].astype(np.int16)


def distances(x, templates):
    """Integer distance, slope weighting (2 diagonal, 1 horizontal/vertical).

    Both sequences have 24 frames. A 6-frame Sakoe-Chiba band prevents
    unrestricted repeats. Divide by 48*16 for mean per-band feature units.
    """
    result = []
    for offset in range(0, len(x), 32):
        a = x[offset:offset+32]
        costs = np.zeros((len(a), len(templates), 24, 24), dtype=np.int32)
        for band in range(16):
            costs += np.abs(a[:, None, :, None, band]-templates[None, :, None, :, band])
        prev = np.full((len(a), len(templates), 25), 1 << 27, dtype=np.int32)
        prev[:, :, 0] = 0
        for i in range(1, 25):
            row = np.full_like(prev, 1 << 27)
            for j in range(max(1, i-6), min(24, i+6)+1):
                d = costs[:, :, i-1, j-1]
                row[:, :, j] = np.minimum(np.minimum(prev[:, :, j]+d, row[:, :, j-1]+d), prev[:, :, j-1]+2*d)
            prev = row
        result.append(prev[:, :, 24])
    return np.concatenate(result)/768


def summary(y, pred):
    cm = np.zeros((3, 3), dtype=int)
    for a, b in zip(y, pred):
        cm[a, b] += 1
    return dict(confusion=cm.tolist(), correct_commands=int(cm[1, 1]+cm[2, 2]),
                wrong_direction=int(cm[1, 2]+cm[2, 1]), false_accepts=int(cm[0, 1:].sum()),
                commands=int((y != 0).sum()), negatives=int((y == 0).sum()))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--templates-per-class', type=int, default=24)
    args = ap.parse_args()
    EXP.mkdir(exist_ok=True)
    train_path = ROOT/'voice/experiments/robust_normalized/train_dataset.npz'
    validation_path = ROOT/'voice/experiments/robust_normalized/validation_dataset.npz'
    tr = np.load(train_path)
    va = np.load(validation_path)
    tx = sequences(tr['x'])
    vx = sequences(va['x'])
    rng = np.random.default_rng(20261023)
    templates = []
    labels = []
    indices = []
    for label in range(3):
        members = np.flatnonzero(tr['y'] == label)
        members = rng.choice(members, min(len(members), 2000), replace=False)
        data = tx[members].reshape(len(members), -1).astype(np.float32)
        centers, _ = kmeans2(data, args.templates_per_class, iter=15, minit='++', seed=20261023+label)
        for center in centers:
            k = members[np.square(data-center).sum(1).argmin()]
            templates.append(tx[k])
            labels.append(label)
            indices.append(int(k))
    templates = np.array(templates)
    labels = np.array(labels)
    np.savez(EXP/'templates.npz', templates=templates, labels=labels, train_indices=indices)
    print('Templates derived from training split:', len(templates), flush=True)
    dist = distances(vx, templates)
    scores = np.stack([dist[:, labels == k].min(1) for k in range(3)], axis=1)
    winner = scores.argmin(1)
    ordered = np.sort(scores, axis=1)
    gap = ordered[:, 1]-ordered[:, 0]
    best = None
    max_false = int((va['y'] == 0).sum()*.005)
    for threshold in np.linspace(2, 24, 89):
        for margin in np.linspace(0, 5, 41):
            pred = np.where((ordered[:, 0] <= threshold) & (gap >= margin), winner, 0)
            s = summary(va['y'], pred)
            if s['false_accepts'] > max_false:
                continue
            rank = (s['correct_commands']-3*s['wrong_direction'], s['correct_commands'], -s['false_accepts'])
            if best is None or rank > best[0]:
                best = (rank, threshold, margin, s)
    w = read_hex(MODEL/'weights.mem', 8)
    b = read_hex(MODEL/'bias.mem', 32)
    cfg = json.loads((MODEL/'config.json').read_text())
    z = integer_infer(va['x'].reshape(-1, 768), w[:36864].reshape(48, 768), b[:48], w[36864:].reshape(3, 48), b[48:], cfg['shift']).reshape(-1, 3, 3)
    baseline = summary(va['y'], decisions(z, cfg['margin']))
    report = dict(experimental_only=True, deployed=False, split='synthetic_validation_candidates',
                  test_used_for_selection=False, real_capture_used_for_training=False,
                  metric_unit='endpoint candidates, not complete clips or human accuracy',
                  baseline=baseline, dtw=best[3], threshold=best[1], margin=best[2],
                  templates_per_class=args.templates_per_class,
                  estimated_template_bytes=int(templates.size),
                  estimated_cell_band_operations_per_utterance=int(len(templates)*24*13*16),
                  sources={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                           for p in [Path(__file__), train_path, validation_path, MODEL/'weights.mem', MODEL/'bias.mem']})
    sys.path.insert(0, str(ROOT/'tools'))
    from decode_voice_capture import packets
    from replay_voice_capture import replay
    reports = []
    for stamp in ['140757', '141019', '141445']:
        path = ROOT/f'verification/voice_capture_20261023_{stamp}.bin'
        blocks, bad = packets(path.read_bytes())
        features = np.array([list(b[12:28]) for b in blocks], dtype=np.int8)
        rows = [a for a in replay(path, MODEL)['attempts'] if 'exact_match' in a]
        xx = np.stack([normalized_windows(features, a['start_frame'], a['end_frame']) for a in rows])
        dd = distances(sequences(xx), templates)
        ss = np.stack([dd[:, labels == k].min(1) for k in range(3)], axis=1)
        for a, s in zip(rows, ss):
            order = np.sort(s)
            pred = int(s.argmin()) if order[0] <= best[1] and order[1]-order[0] >= best[2] else 0
            reports.append(dict(capture=path.name, sequence=a['sequence'], start_seconds=a['start_seconds'],
                                distance_per_class=s.tolist(), prediction=pred, label=None))
    report['unlabelled_hardware_candidates'] = reports
    (EXP/'validation_report.json').write_text(json.dumps(report, indent=2))
    print(json.dumps({k: v for k, v in report.items() if k not in ['sources', 'unlabelled_hardware_candidates']}, indent=2), flush=True)


if __name__ == '__main__':
    main()
