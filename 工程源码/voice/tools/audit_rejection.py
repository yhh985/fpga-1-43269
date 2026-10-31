"""Compare rejection policies without changing the production model or HDL."""
import os
os.environ.setdefault('OPENBLAS_NUM_THREADS','1')
from pathlib import Path
import argparse,hashlib,json
import numpy as np
import soundfile as sf
from kws_common import pcm48,features,endpoints,endpoint_windows,integer_infer,read_hex

ROOT=Path(__file__).resolve().parents[1]
ap=argparse.ArgumentParser()
ap.add_argument('--data-root',type=Path,required=True)
ap.add_argument('--noise-amplitude',type=int,default=0)
args=ap.parse_args()
manifest=args.data_root/'data/manifest.json'
rows=[r for r in json.loads(manifest.read_text(encoding='utf-8')) if r['split']=='test']
c=json.loads((ROOT/'model/config.json').read_text())
w=read_hex(ROOT/'model/weights.mem',8);b=read_hex(ROOT/'model/bias.mem',32)
policies=['current_three_all','three_all_margin_zero','two_of_three','last_window_only']
cms={p:np.zeros((3,3),dtype=int) for p in policies}
details=[];rng=np.random.default_rng(20261020)
for row in rows:
    audio,sr=sf.read(args.data_root/row['path'])
    if audio.ndim==2:audio=audio.mean(axis=1)
    pcm=np.concatenate([np.zeros(49152,dtype=np.int16),pcm48(audio,sr),np.zeros(73728,dtype=np.int16)])
    if args.noise_amplitude:
        pcm=np.clip(pcm.astype(np.int32)+rng.integers(-args.noise_amplitude,args.noise_amplitude+1,len(pcm)),-32768,32767).astype(np.int16)
    f=features(pcm,adaptive_vad=True);ends=list(endpoints(f,robust=True))
    windows=np.concatenate([endpoint_windows(f,e) for e in ends]) if ends else np.zeros((0,768))
    z=integer_infer(windows,w[:36864].reshape(48,768),b[:48],w[36864:].reshape(3,48),b[48:],c['shift']).reshape(-1,3,3)
    winner=z.argmax(axis=2);margin=np.diff(np.sort(z,axis=2)[:,:,-2:],axis=2)[:,:,0]
    preds={p:0 for p in policies}
    for wins,m in zip(winner,margin):
        unanimous=bool((wins==wins[0]).all() and wins[0]!=0)
        candidates={
            'current_three_all':int(wins[0]) if unanimous and (m>=c['margin']).all() else 0,
            'three_all_margin_zero':int(wins[0]) if unanimous else 0,
            'two_of_three':next((label for label in [1,2] if np.count_nonzero((wins==label)&(m>=c['margin']))>=2),0),
            'last_window_only':int(wins[-1]) if m[-1]>=c['margin'] else 0}
        for p,value in candidates.items():
            if not preds[p] and value:preds[p]=value
    for p,pred in preds.items():cms[p][row['label'],pred]+=1
    details.append(dict(path=row['path'],label=row['label'],endpoints=len(ends),
                        predictions=preds,winners=winner.tolist(),margins=margin.tolist()))
summary={p:dict(confusion=cm.tolist(),command_correct=int(cm[1,1]+cm[2,2]),
    command_count=int(cm[1:].sum()),wrong_direction=int(cm[1,2]+cm[2,1]),
    rejected_commands=int(cm[1:,0].sum()),false_accepts=int(cm[0,1:].sum())) for p,cm in cms.items()}
report=dict(synthetic_only=all(row.get('synthetic',True) for row in rows),clips=len(rows),
    production_changed=False,noise_amplitude=args.noise_amplitude,margin=c['margin'],policies=summary,
    commands_without_endpoint=sum(d['label']!=0 and d['endpoints']==0 for d in details),details=details,
    note='Policy ablation on synthetic holdout only; not real microphone accuracy. No threshold selected or deployed.',
    sources={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [manifest,ROOT/'model/config.json',
      ROOT/'model/weights.mem',ROOT/'model/bias.mem',ROOT/'tools/kws_common.py',Path(__file__),
      ROOT.parent/'aca420/rtl/aca_kws_frontend.v',ROOT.parent/'aca420/rtl/aca_kws_engine.v']})
out=ROOT.parent/'verification'/f'voice_rejection_audit_noise{args.noise_amplitude}.json'
out.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({k:v for k,v in report.items() if k not in ['sources','details']},ensure_ascii=False,indent=2),flush=True)
