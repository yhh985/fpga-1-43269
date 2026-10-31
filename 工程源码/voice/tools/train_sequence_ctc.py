"""Small experimental syllable-code recognizer; no deployed RTL/ROM is changed.

Inspired by WeKws/FunASR temporal memory + CTC, independently implemented.
Tokens are acoustic training targets, not UTF encodings: blank/xia/shang/yi/zhang/other.
Only synthetic train speakers train the model. Validation chooses checkpoints.
The two old real utterances are reported after selection, never enrolled.
"""
import os
os.environ.setdefault('OPENBLAS_NUM_THREADS', '1')
from pathlib import Path
import argparse, copy, hashlib, json, time
from concurrent.futures import ThreadPoolExecutor
import numpy as np
import soundfile as sf
import torch
from torch import nn
from kws_common import log4, mel_powers, decimate
from probe_vad_continuity import prepare, gated_features
from robust_common import utterances

ROOT = Path(__file__).resolve().parents[2]
DATA = Path('E:/anlo_project/liantiao/voice')
OUT = ROOT/'voice/experiments/sequence_ctc'
TOKENS = ['blank', 'xia', 'shang', 'yi', 'zhang', 'other']
CODE = {1: [1, 3, 4], 2: [2, 3, 4], 0: [5]}

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def raw_features(p):
    """Loudness-normalized spectrum, WITHOUT destructive adaptive VAD masking."""
    logs = log4(p)
    f = np.clip(logs-logs.max(1, keepdims=True)+64, 0, 64)
    f[p.max(1) < 512] = 0
    n = len(f)//2
    return ((f[:2*n:2]+f[1:2*n:2]) >> 1).astype(np.int8)

def candidates(p, rate=1):
    raw = raw_features(p)
    gate = gated_features(p, 'hysteresis')
    if rate != 1:
        pos = np.linspace(0, len(raw)-1, max(2, round(len(raw)/rate)))
        def stretch(x):
            return np.rint(np.stack([np.interp(pos, np.arange(len(x)), x[:,j]) for j in range(16)], 1)).astype(np.int8)
        raw, gate = stretch(raw), stretch(gate)
    # Same fixed ready-board padding as the current full-stream evaluation.
    gate = np.r_[np.zeros((64,16), dtype=np.int8), gate]
    raw = np.r_[np.zeros((64,16), dtype=np.int8), raw]
    pairs = list(utterances(gate, prequiet=0, max_frames=127))
    active_total = max(1, np.count_nonzero(np.any(gate, axis=1)))
    found = []
    for s, e in pairs:
        # Capture 96ms before onset, keeping weak initial fricatives.
        x = raw[max(0,s-3):e].copy()
        coverage = np.count_nonzero(np.any(gate[s:e], axis=1))/active_total
        found.append((x, coverage, s, e))
    return found

class Memory(nn.Module):
    def __init__(self, dim, dilation):
        super().__init__()
        self.dilation = dilation
        self.filter = nn.Conv1d(dim, dim, 9, groups=dim, dilation=dilation, bias=False)
        self.mix = nn.Conv1d(dim, dim, 1)
    def forward(self, x):
        delayed = nn.functional.pad(x, (8*self.dilation, 0))
        return torch.clamp(self.mix(x+self.filter(delayed)), 0, 4)

class SequenceNet(nn.Module):
    def __init__(self):
        super().__init__()
        self.front = nn.Conv1d(16, 32, 5, padding=2)
        self.memory1 = Memory(32, 1)
        self.memory2 = Memory(32, 2)
        self.out = nn.Conv1d(32, len(TOKENS), 1)
    def forward(self, x):
        x = torch.clamp(self.front(x.transpose(1,2)), 0, 4)
        return self.out(self.memory2(self.memory1(x))).transpose(1,2)

def batch(xs):
    lengths = np.array([len(x) for x in xs])
    x = np.zeros((len(xs), max(lengths), 16), dtype=np.float32)
    for i, a in enumerate(xs):
        x[i,:len(a)] = a/32
    return torch.from_numpy(x), torch.from_numpy(lengths)

def decode(z):
    ids = z.argmax(1)
    tokens, confidence = [], []
    last = 0
    for i, k in enumerate(ids):
        if k and k != last:
            tokens.append(int(k))
            confidence.append(float(z[i,k]-np.max(np.delete(z[i],k))))
        elif k and tokens and k == last:
            confidence[-1] = max(confidence[-1], float(z[i,k]-np.max(np.delete(z[i],k))))
        last = k
    pred = 1 if tokens == CODE[1] else 2 if tokens == CODE[2] else 0
    return pred, min(confidence) if pred else -1, tokens

@torch.no_grad()
def infer(net, xs):
    rows = []
    for start in range(0, len(xs), 64):
        x, lens = batch(xs[start:start+64])
        z = net(x).numpy()
        rows += [decode(a[:int(n)]) for a, n in zip(z, lens)]
    return rows

def measure(labels, owners, decodes, margin):
    pred = np.zeros(len(labels), dtype=int)
    for owner, (k, gap, _) in zip(owners, decodes):
        if k and gap >= margin and pred[owner] == 0:
            pred[owner] = k
    cm = np.zeros((3,3), dtype=int)
    for lab, k in zip(labels, pred):
        cm[lab,k] += 1
    return dict(correct=int(cm[1,1]+cm[2,2]), wrong_direction=int(cm[1,2]+cm[2,1]),
                false_accepts=int(cm[0,1:].sum()), confusion=cm.tolist())

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--epochs', type=int, default=90)
    ap.add_argument('--evaluate-only', action='store_true')
    args = ap.parse_args()
    OUT.mkdir(exist_ok=True)
    manifest = DATA/'data/manifest.json'
    rows = json.loads(manifest.read_text(encoding='utf-8'))
    torch.set_num_threads(4)
    torch.manual_seed(20261023)
    rng = np.random.default_rng(20261023)
    cache = OUT/'dataset.npz'
    # Bind cache to both boundary/feature code and the exact sample manifest.
    key = sha(Path(__file__))+sha(manifest)+sha(ROOT/'voice/tools/probe_vad_continuity.py')
    meta_path = OUT/'dataset_sources.json'
    if not cache.exists() or not meta_path.exists() or json.loads(meta_path.read_text())['key'] != key:
        samples = []
        with ThreadPoolExecutor(max_workers=4) as pool:
            for i, sample in enumerate(pool.map(prepare, enumerate(rows))):
                samples.append(sample)
                if i % 200 == 0:
                    print('powers',i, flush=True)
        arrays = {}
        provenance = {}
        for split in ['train', 'validation', 'test']:
            xs, targets, owners, labels, spans = [], [], [], [], []
            for row, clean, noisy in samples:
                if row['split'] != split:
                    continue
                for p in [clean, noisy]:
                    for rate in ([.75, 1., 1.3] if split == 'train' else [.65, 1., 1.45]):
                        owner = len(labels)
                        labels.append(row['label'])
                        for x, coverage, s, e in candidates(p, rate):
                            # Fragmented candidates are not falsely taught a complete command.
                            target = CODE[row['label']] if coverage >= .70 else [5]
                            if row['label'] == 0 and coverage >= .70:
                                if row['text'] == '\u4e0b\u4e00\u9996': target = [1,3,5]
                                elif row['text'] == '\u4e0a\u4e00\u9996': target = [2,3,5]
                            xs.append(x);targets.append(target);owners.append(owner);spans.append((s,e))
            # Ragged arrays stored as numeric concatenations, no pickle objects.
            lengths = np.array([len(x) for x in xs], dtype=np.int32)
            target_lens = np.array([len(t) for t in targets], dtype=np.int32)
            for name, value in dict(x=np.concatenate(xs), lengths=lengths,
                                    targets=np.concatenate(targets), target_lengths=target_lens,
                                    owners=owners, labels=labels, spans=spans).items():
                arrays[split+'_'+name] = np.asarray(value)
            provenance[split] = dict(candidates=len(xs), full_clip_trials=len(labels))
            print('dataset',split,provenance[split],flush=True)
        np.savez_compressed(cache, **arrays)
        meta_path.write_text(json.dumps(dict(key=key, splits=provenance), indent=2))
    ds = np.load(cache)
    def split(name):
        lens = ds[name+'_lengths']; tls = ds[name+'_target_lengths']
        xs = np.split(ds[name+'_x'], np.cumsum(lens)[:-1])
        targets = np.split(ds[name+'_targets'], np.cumsum(tls)[:-1])
        return xs, targets, ds[name+'_owners'], ds[name+'_labels']
    tx, ty, _, _ = split('train')
    vx, _, vo, vy = split('validation')
    net = SequenceNet()
    best = None
    checkpoints = []
    if not args.evaluate_only:
        opt = torch.optim.AdamW(net.parameters(), lr=.0015, weight_decay=.005)
        ctc = nn.CTCLoss(blank=0, zero_infinity=False)
        t0 = time.time()
        for epoch in range(args.epochs):
            net.train(); losses = []
            for ids in np.array_split(rng.permutation(len(tx)), max(1,len(tx)//64)):
                xs = []
                for i in ids:
                    x = tx[i].astype(np.float32).copy()
                    # Smooth microphone EQ and mild noise, preserving all frames.
                    if rng.random() < .7:
                        eq = np.interp(np.arange(16), [0,5,10,15], rng.normal(0,2.5,4))
                        active = np.any(x,axis=1)
                        x[active] = np.clip(x[active]+eq+rng.normal(0,1,x[active].shape),0,64)
                    xs.append(x)
                x, lens = batch(xs)
                target = torch.from_numpy(np.concatenate([ty[i] for i in ids])).long()
                target_lens = torch.tensor([len(ty[i]) for i in ids])
                z = net(x).log_softmax(2).transpose(0,1)
                loss = ctc(z, target, lens, target_lens)
                assert torch.isfinite(loss), 'Nonfinite CTC training loss'
                opt.zero_grad();loss.backward();nn.utils.clip_grad_norm_(net.parameters(),5);opt.step()
                losses.append(float(loss.detach()))
            if epoch % 5 == 4 or epoch == 0:
                net.eval(); decoded = infer(net, vx)
                # Validation alone chooses a modest confidence condition.
                options = []
                for margin in [0,.25,.5,.75,1.,1.5,2.,3.]:
                    m = measure(vy, vo, decoded, margin)
                    if m['false_accepts'] <= 8:
                        options.append(((m['correct']-3*m['wrong_direction'],m['correct'],-m['false_accepts']),margin,m))
                if options:
                    rank, margin, metrics = max(options,key=lambda z:z[0])
                    record = dict(epoch=epoch, margin=margin, validation=metrics)
                    checkpoints.append(record)
                    if best is None or rank > best[0]:
                        best = (rank, copy.deepcopy(net.state_dict()), record)
                        torch.save(best[1], OUT/'candidate.pt')
                        (OUT/'selected.json').write_text(json.dumps(record,indent=2))
                    print('epoch',epoch,'loss',round(np.mean(losses),4),metrics,'elapsed',round(time.time()-t0,1),flush=True)
        assert best is not None
        (OUT/'training_log.json').write_text(json.dumps(checkpoints,indent=2))
    net.load_state_dict(torch.load(OUT/'candidate.pt',weights_only=True));net.eval()
    selected = json.loads((OUT/'selected.json').read_text())
    results = {}
    for name in ['validation','test']:
        x, _, owner, lab = split(name)
        results[name] = measure(lab, owner, infer(net,x), selected['margin'])
    wav = ROOT/'verification/user_20261021_170604.wav'
    a, sr = sf.read(wav,dtype='int16');assert sr == 48000
    pcm = np.r_[np.zeros(98304,dtype=np.int16),a,np.zeros(73728,dtype=np.int16)]
    real = candidates(mel_powers(decimate(pcm)))
    decoded = infer(net,[x for x,_,_,_ in real])
    results['real_development'] = [dict(start=s,end=e,code=[TOKENS[t] for t in tokens],
                                            prediction=k if gap>=selected['margin'] else 0, gap=gap)
                                  for (_,_,s,e),(k,gap,tokens) in zip(real,decoded)]
    report = dict(experimental_only=True, deployed=False, real_used_for_training=False,
                  tokens=TOKENS, keyword_codes=CODE, selected=selected,
                  parameter_count=sum(p.numel() for p in net.parameters()),
                  algorithm='2 temporal-memory blocks, framewise syllable targets, CTC alignment',
                  frontend='non-destructive raw spectrum; VAD boundaries only; 3-frame pre-roll',
                  results=results, test_used_for_selection=False,
                  human_accuracy_verified=False,
                  sources={str(p):sha(p) for p in [Path(__file__),manifest,meta_path,cache,
                           OUT/'candidate.pt',OUT/'selected.json',wav,
                           ROOT/'voice/tools/probe_vad_continuity.py',ROOT/'voice/tools/kws_common.py',
                           ROOT/'voice/tools/robust_common.py']})
    (OUT/'report.json').write_text(json.dumps(report,indent=2))
    print(json.dumps({k:v for k,v in report.items() if k!='sources'},indent=2),flush=True)

if __name__ == '__main__':
    main()
