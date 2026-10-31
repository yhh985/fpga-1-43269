"""Measure fixed-point CTC paths for NEXT with a skipped middle character."""
import json
import os

import numpy as np
import torch

from evaluate_ctc_fixed import LUT, view
from export_ctc_fpga import ROOT, load
from train_directional_ctc import CODES
from train_masked_acoustic_codes import batch

NEG = -1_000_000


def lse(values):
    m = max(values)
    if m <= NEG // 2:
        return NEG
    result = m
    for value in values:
        if value != m and m - value <= 1023:
            result = max(result, m + int(LUT[m - value]))
    return result


def target_score(logits, target):
    states = [0]
    for token in target:
        states.extend([token, 0])
    dp = [NEG] * len(states)
    for t, row in enumerate(logits):
        norm = int(row[0])
        for v in row[1:]:
            norm = lse([norm, int(v)])
        lp = row.astype(np.int64) - norm
        new = [NEG] * len(states)
        for s, token in enumerate(states):
            candidates = [dp[s]]
            if s > 0:
                candidates.append(dp[s - 1])
            if s > 1 and token != 0 and token != states[s - 2]:
                candidates.append(dp[s - 2])
            merged = lse(candidates)
            if merged > NEG // 2:
                new[s] = merged + int(lp[token])
        if t == 0:
            new = [NEG] * len(states)
            new[0] = int(lp[0])
            if len(states) > 1:
                new[1] = int(lp[states[1]])
        dp = new
    return lse([dp[-1], dp[-2]])


def score_pair(logits, lengths):
    down, one, zhang = CODES[1]
    targets = [[down, one, zhang], [down, zhang]]
    values = np.zeros((len(logits), 2), dtype=np.int64)
    for i, (sample, n) in enumerate(zip(logits, lengths)):
        sample = sample[:int(n)]
        for j, target in enumerate(targets):
            values[i, j] = target_score(sample, target)
    return values


def main():
    os.environ.setdefault('OPENBLAS_NUM_THREADS', '1')
    torch.set_num_threads(2)
    net = load()
    ds = np.load(ROOT / 'voice/experiments/sequence_ctc/dataset.npz')
    reports = {}
    for split in ['validation', 'test']:
        lens = ds[split + '_lengths']
        xs = np.split(ds[split + '_x'], np.cumsum(lens)[:-1])
        owners = ds[split + '_owners']
        labels = ds[split + '_labels'].copy()
        labels[labels == 2] = 0
        scale_scores = []
        for scale in range(3):
            logits_all = []
            for lo in range(0, len(xs), 32):
                part = [view(x, scale) for x in xs[lo:lo + 32]]
                x, l = batch(part)
                with torch.no_grad():
                    logits, _ = net(x, l)
                logits_all.extend([np.rint(a[:int(n)].numpy() * 64).astype(np.int64)
                                   for a, n in zip(logits, l)])
            scale_scores.append(score_pair(logits_all, [len(x) for x in logits_all]))
        summaries = {}
        for policy in ['full_only', 'two_only', 'full_or_two']:
            for margin in [0, 128, 256, 512, 768, 1152, 1536, 2048]:
                accepted = []
                for s in scale_scores:
                    gap = s[:, 1] - s[:, 0]
                    if policy == 'full_only':
                        ok = (s[:, 0] >= s[:, 1]) & (s[:, 0] >= NEG // 2)
                    elif policy == 'two_only':
                        ok = (s[:, 1] > NEG // 2) & (gap >= margin)
                    else:
                        ok = ((s[:, 0] >= s[:, 1]) | ((s[:, 1] > NEG // 2) & (gap >= margin)))
                    accepted.append(ok)
                # Require two of three scales; prevent one anomalous scale from
                # triggering the command. This is still offline policy analysis.
                votes = np.sum(np.stack(accepted), axis=0)
                pred = np.zeros(len(labels), dtype=np.int8)
                for owner, ok in zip(owners, votes >= 2):
                    if ok:
                        pred[owner] = 1
                cm = np.zeros((2, 2), dtype=int)
                for y, p in zip(labels, pred):
                    cm[int(y != 1), p] += 1
                summaries[f'{policy}_m{margin}'] = dict(confusion=cm.tolist(),
                    next_recall=int(cm[1, 1]), false_accepts=int(cm[0, 1]))
        reports[split] = summaries
        print(split, json.dumps(summaries), flush=True)
    (ROOT / 'verification/two_char_ctc_policy.json').write_text(
        json.dumps(reports, indent=2), encoding='utf-8')


if __name__ == '__main__':
    main()
