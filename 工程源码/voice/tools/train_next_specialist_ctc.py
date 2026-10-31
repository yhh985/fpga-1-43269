"""Fine-tune V5 NEXT discrimination using complete, explicitly labeled trials."""
import hashlib
import json
import time
from pathlib import Path

import numpy as np
import torch
from torch import nn

from train_directional_ctc import CODES, PHRASES, base
from train_masked_acoustic_codes import Net, ROOT, batch

OUT = ROOT / 'voice/experiments/next_specialist_ctc'
SOURCE = ROOT / 'voice/experiments/sequence_ctc/dataset.npz'
PRETRAINED = ROOT / 'voice/experiments/acoustic_codes_v5/candidate.pt'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def path_scores(z, lengths):
    n = len(z)
    k = len(CODES)
    lp = z.log_softmax(2).repeat_interleave(k, dim=0).transpose(0, 1).contiguous()
    targets = torch.tensor([token for _ in range(n) for code in CODES for token in code], dtype=torch.long)
    target_lengths = torch.tensor([len(code) for _ in range(n) for code in CODES], dtype=torch.long)
    return -nn.functional.ctc_loss(lp, targets, lengths.repeat_interleave(k), target_lengths,
                                  blank=0, reduction='none', zero_infinity=False).reshape(n, k)


def score_samples(net, xs):
    result = []
    for lo in range(0, len(xs), 32):
        x, lens = batch(xs[lo:lo + 32])
        with torch.no_grad():
            z, _ = net(x, lens)
            result.append(path_scores(z, lens).numpy())
    return np.concatenate(result)


def measure(scores, lengths, owners, labels, margin, floor):
    next_index = PHRASES.index('下一张')
    rivals = np.max(np.delete(scores, next_index, axis=1), axis=1)
    gaps = scores[:, next_index] - rivals
    accepts = (scores[:, next_index] > rivals) & (gaps >= margin)
    accepts &= scores[:, next_index] / lengths >= floor
    pred = np.zeros(len(labels), dtype=np.int8)
    for owner, accepted in zip(owners, accepts):
        if accepted:
            pred[owner] = 1
    cm = np.zeros((2, 2), dtype=int)
    for label, value in zip(labels, pred):
        cm[int(label != 1), value] += 1
    return dict(confusion=cm.tolist(), correct=int(cm[1, 1]),
                false_accepts=int(cm[0, 1]), rejected=int(cm[1, 0]))


def main():
    torch.set_num_threads(4)
    torch.manual_seed(20261026)
    rng = np.random.default_rng(20261026)
    OUT.mkdir(parents=True, exist_ok=True)
    ds = np.load(SOURCE)
    tx = np.split(ds['train_x'], np.cumsum(ds['train_lengths'])[:-1])
    to = ds['train_owners']
    tl = ds['train_labels']
    # The sequence dataset only assigns the full NEXT transcript to windows
    # with at least 70% coverage; fragmented windows are labeled OTHER.
    # Identify those true positives by their full transcript target.
    train_targets = np.split(ds['train_targets'], np.cumsum(ds['train_target_lengths'])[:-1])
    positive_ids = np.array([i for i, (owner, target) in enumerate(zip(to, train_targets))
                             if tl[owner] == 1 and len(target) == 3], dtype=int)
    all_ids = np.arange(len(tx))
    assert len(positive_ids) > 0, 'No complete NEXT windows found'

    vx = np.split(ds['validation_x'], np.cumsum(ds['validation_lengths'])[:-1])
    vl = ds['validation_lengths']
    vo = ds['validation_owners']
    vy = ds['validation_labels'].copy()
    vy[vy == 2] = 0
    net = Net()
    net.load_state_dict(torch.load(PRETRAINED, weights_only=True))
    opt = torch.optim.AdamW(net.parameters(), lr=0.00005, weight_decay=0.001)
    best = None
    selected = None
    history = []
    started = time.time()

    for epoch in range(36):
        net.train()
        for norm in net.norms:
            norm.eval()
        picks = np.r_[rng.permutation(all_ids), rng.choice(positive_ids, len(all_ids) // 2)]
        rng.shuffle(picks)
        losses = []
        for ix in np.array_split(picks, max(1, len(picks) // 48)):
            xs, labels = [], []
            for i in ix:
                x = tx[i].astype(np.float32).copy()
                owner = int(to[i])
                y = int(tl[owner] == 1 and len(train_targets[i]) == 3)
                rate = float(rng.uniform(0.75, 1.35)) if y else float(rng.uniform(0.9, 1.1))
                pos = np.arange(max(8, round(len(x) / rate))) * rate
                x = np.stack([np.interp(pos, np.arange(len(x)), x[:, j]) for j in range(16)], 1)
                if rng.random() < 0.75:
                    eq = np.interp(np.arange(16), [0, 5, 10, 15], rng.normal(0, 2.2, 4))
                    active = np.any(x, axis=1)
                    x[active] = np.clip(x[active] + eq + rng.normal(0, 0.8, x[active].shape), 0, 64)
                x = np.pad(x, ((int(rng.integers(0, 9)), int(rng.integers(0, 9))), (0, 0)))
                xs.append(x)
                labels.append(y)
            x, lens = batch(xs)
            z, _ = net(x, lens)
            scores = path_scores(z, lens)
            next_index = PHRASES.index('下一张')
            rivals = scores.masked_fill(
                nn.functional.one_hot(torch.full((len(xs),), next_index), len(PHRASES)).bool(), -1e9
            ).max(1).values
            next_score = scores[:, next_index]
            positive = torch.tensor(labels, dtype=torch.bool)
            # Optimize separation against the strongest CTC phrase, including
            # blank/background, while preserving the original transcript loss.
            target = torch.tensor(labels, dtype=torch.long)
            chosen = scores[torch.arange(len(labels)), target]
            base_loss = -chosen.mean() / max(1, len(CODES[next_index]))
            neg_loss = nn.functional.softplus(2.0 + next_score[~positive] - rivals[~positive]).mean()
            pos_loss = nn.functional.softplus(4.0 + rivals[positive] - next_score[positive]).mean()
            loss = base_loss + 0.25 * neg_loss + 0.45 * pos_loss
            opt.zero_grad()
            loss.backward()
            nn.utils.clip_grad_norm_(net.parameters(), 3)
            opt.step()
            losses.append(float(loss.detach()))

        if epoch % 3 == 2 or epoch == 0:
            net.eval()
            scores = score_samples(net, vx)
            options = []
            for margin in [0, 2, 4, 6, 8, 12, 18, 24]:
                for floor in [-0.05, -0.1, -0.2, -0.5, -1.0]:
                    m = measure(scores, vl, vo, vy, margin, floor)
                    if m['false_accepts'] <= 8:
                        rank = (m['correct'], -m['false_accepts'])
                        options.append((rank, margin, floor, m))
            if options:
                rank, margin, floor, m = max(options, key=lambda v: v[0])
                record = dict(epoch=epoch, margin=margin, floor=floor,
                              validation=m, mean_loss=float(np.mean(losses)))
                history.append(record)
                if best is None or rank > best:
                    best = rank
                    selected = record
                    torch.save(net.state_dict(), OUT / 'candidate.pt')
                    (OUT / 'selected.json').write_text(json.dumps(record, indent=2), encoding='utf-8')
            print('epoch', epoch, 'loss', round(float(np.mean(losses)), 4),
                  'best', selected, 'elapsed', round(time.time() - started, 1), flush=True)

    if selected is None:
        raise RuntimeError('No threshold met false accept cap')
    net.load_state_dict(torch.load(OUT / 'candidate.pt', weights_only=True))
    net.eval()
    reports = {}
    for split in ['validation', 'test']:
        lengths = ds[split + '_lengths']
        xs = np.split(ds[split + '_x'], np.cumsum(lengths)[:-1])
        owners = ds[split + '_owners']
        labels = ds[split + '_labels'].copy()
        labels[labels == 2] = 0
        scores = score_samples(net, xs)
        reports[split] = measure(scores, lengths, owners, labels, selected['margin'], selected['floor'])
    report = dict(experimental_only=True, deployed=False, real_used_for_training=False,
                  selected=selected, results=reports, parameters=sum(p.numel() for p in net.parameters()),
                  source_hashes={str(p): sha(p) for p in [Path(__file__), SOURCE, PRETRAINED]},
                  checkpoint_sha256=sha(OUT / 'candidate.pt'), history=history,
                  note='Synthetic data only; test data was not used for selection.')
    (OUT / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2), flush=True)


if __name__ == '__main__':
    main()
