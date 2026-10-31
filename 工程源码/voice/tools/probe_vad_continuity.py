"""Evaluate continuity-aware VAD before changing the deployed RTL.

Validation selects the policy; test and the old real recording are reports only.
Caches contain pre-VAD band powers, not irreversibly gated features.
"""
import os
os.environ.setdefault('OPENBLAS_NUM_THREADS', '1')
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import argparse, hashlib, json
import numpy as np
import soundfile as sf
from kws_common import pcm48, decimate, mel_powers, log4, read_hex, integer_infer
from robust_common import utterances, normalized_windows, decisions

ROOT = Path(__file__).resolve().parents[2]
DATA = Path('E:/anlo_project/liantiao/voice')
OUT = ROOT/'voice/experiments/vad_continuity'
POLICIES = {'baseline': (8, 3, 0), 'hold2': (8, 3, 2),
            'hysteresis': (4, 2, 0), 'hysteresis_hold2': (4, 2, 2)}

def gated_features(p, policy):
    release, bands, hold = POLICIES[policy]
    logs = log4(p)
    f = np.maximum(-64, logs-logs.max(1, keepdims=True)).astype(np.int16)
    f[p.max(1)<512] = -64
    noise = 0; calibration = 0; active_run = 0; hang = 0
    band_noise = np.zeros(16, dtype=np.int64)
    for i, row in enumerate(logs):
        maximum = int(row.max()); loud = p[i].max()>=512
        strong = bool(loud and maximum>(noise>>3)+8 and
                      np.count_nonzero(row>(band_noise>>3)+8)>=3)
        weak = bool(loud and maximum>(noise>>3)+release and
                    np.count_nonzero(row>(band_noise>>3)+release)>=bands)
        active = strong or (hang>0 and weak)
        speech = calibration==16 and (active or (hang>0 and hold>0))
        # Saturated active runs eventually adapt, as in the original frontend.
        if calibration<16:
            calibration += 1
            noise = maximum*8 if calibration==1 else noise-(noise>>3)+maximum
        elif not speech or active_run==127:
            noise = noise-(noise>>3)+maximum
        active_run = min(127,active_run+1) if active else 0
        if calibration==1: band_noise = row.astype(np.int64)*8
        elif calibration<16 or not speech or active_run==127:
            band_noise = band_noise-(band_noise>>3)+row
        if calibration==16 and active:
            hang = max(1,hold)
        elif hang: hang -= 1
        if not speech: f[i] = -64
    n = len(f)//2
    return (((f[:2*n:2]+f[1:2*n:2])>>1)+64).astype(np.int8)

def prepare(item):
    ri, row = item
    path = DATA/row['path']
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    cache = OUT/'cache'/(digest+f'_{ri}_powers_v1.npz')
    if not cache.exists():
        a, sr = sf.read(path)
        if a.ndim==2: a = a.mean(1)
        pcm = np.r_[np.zeros(49152,dtype=np.int16),pcm48(a,sr),np.zeros(73728,dtype=np.int16)]
        rng = np.random.default_rng(202610230+ri); t = np.arange(len(pcm))/48000
        noise = rng.uniform(-500,500,len(pcm))+220*np.sin(2*np.pi*120*t)+80*np.sin(2*np.pi*240*t)
        noisy = np.clip(pcm.astype(float)*.7+noise,-32768,32767).astype(np.int16)
        np.savez_compressed(cache,clean=mel_powers(decimate(pcm)),noisy=mel_powers(decimate(noisy)))
    with np.load(cache) as z: return row,z['clean'],z['noisy']

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--split',choices=['validation','test'],default='validation')
    ap.add_argument('--policy', choices=POLICIES); args=ap.parse_args()
    (OUT/'cache').mkdir(parents=True,exist_ok=True)
    rows=json.loads((DATA/'data/manifest.json').read_text(encoding='utf-8'))
    selected=[(i,r) for i,r in enumerate(rows) if r['split']==args.split]
    samples=[]
    with ThreadPoolExecutor(max_workers=4) as pool:
        for i,s in enumerate(pool.map(prepare,selected)):
            samples.append(s)
            if i%100==0: print('powers',i,'/',len(selected),flush=True)
    model=ROOT/'voice/experiments/robust_normalized/model'
    w=read_hex(model/'weights.mem',8); b=read_hex(model/'bias.mem',32)
    def predict(f):
        pairs=list(utterances(f,prequiet=6))
        if not pairs:return 0
        x=np.concatenate([normalized_windows(f,s,e) for s,e in pairs])
        z=integer_infer(x,w[:36864].reshape(48,768),b[:48],w[36864:].reshape(3,48),b[48:],8).reshape(-1,3,3)
        preds=decisions(z,791,650,3600)
        return next((int(p) for p in preds if p),0)
    report={}
    policies=['baseline',args.policy] if args.policy and args.policy!='baseline' else list(POLICIES)
    for policy in policies:
        cm=np.zeros((3,3),dtype=int)
        for row,clean,noisy in samples:
            for p in [clean,noisy]:
                original=gated_features(p,policy)
                for rate in [.65,1.,1.45]:
                    f=original
                    if rate!=1:
                        t=np.linspace(0,len(f)-1,max(2,round(len(f)/rate)))
                        f=np.rint(np.stack([np.interp(t,np.arange(len(f)),f[:,j]) for j in range(16)],1)).astype(np.int8)
                    f=np.r_[np.zeros((64,16),dtype=np.int8),f]
                    cm[row['label'],predict(f)]+=1
        audio,sr=sf.read(ROOT/'verification/user_20261021_170604.wav',dtype='int16'); assert sr==48000
        f=gated_features(mel_powers(decimate(np.r_[np.zeros(98304,dtype=np.int16),audio,np.zeros(73728,dtype=np.int16)])),policy)
        real=[]
        for s,e in utterances(f,prequiet=6):
            x=normalized_windows(f,s,e)
            z=integer_infer(x,w[:36864].reshape(48,768),b[:48],w[36864:].reshape(3,48),b[48:],8)
            real.append(dict(start=s,end=e,prediction=int(decisions(z[None],791,650,3600)[0]),logits=z.tolist()))
        report[policy]=dict(confusion=cm.tolist(),correct=int(cm[1,1]+cm[2,2]),wrong_direction=int(cm[1,2]+cm[2,1]),false_accepts=int(cm[0,1:].sum()),real_recording=real)
        print(policy,json.dumps(report[policy]),flush=True)
    result=dict(split=args.split,synthetic_only=True,policies=report,real_not_used_for_selection=True)
    (OUT/(args.split+'_report.json')).write_text(json.dumps(result,indent=2),encoding='utf-8')

if __name__=='__main__': main()
