"""Paired streaming comparison. Speed stress scales features, not waveform pitch."""
import os
os.environ.setdefault('OPENBLAS_NUM_THREADS','1')
from pathlib import Path
import argparse,hashlib,json
import numpy as np
from kws_common import endpoints,endpoint_windows,integer_infer,read_hex
from robust_common import utterances,normalized_windows,decisions
ROOT=Path(__file__).resolve().parents[1]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--split',choices=['validation','test'],default='validation')
    ap.add_argument('--data-root',type=Path,default=Path('E:/anlo_project/liantiao/voice'))
    args=ap.parse_args();exp=ROOT/'experiments/robust_normalized'
    rows=json.loads((args.data_root/'data/manifest.json').read_text(encoding='utf8'))
    models={}
    for name,path in [('baseline',ROOT/'model'),('candidate',exp/'model')]:
        w=read_hex(path/'weights.mem',8);b=read_hex(path/'bias.mem',32)
        models[name]=(w[:36864].reshape(48,768),b[:48],w[36864:].reshape(3,48),b[48:],json.loads((path/'config.json').read_text()))
    records=[]
    for ri,row in enumerate(rows):
        if row['split']!=args.split:continue
        key=hashlib.sha256((sha(args.data_root/row['path'])+sha(ROOT/'tools/kws_common.py')+'robust_noise_v1').encode()).hexdigest()
        with np.load(exp/'cache'/(key+'.npz')) as cache:
            for noise in ['clean','noisy']:
                original=cache[noise]
                for rate in [.65,1.,1.45]:
                    f=original
                    if rate!=1:
                        t=np.linspace(0,len(f)-1,max(2,round(len(f)/rate)))
                        f=np.rint(np.stack([np.interp(t,np.arange(len(f)),f[:,j]) for j in range(16)],1)).astype(np.int8)
                    # Keep readiness independent of rate; stretch speech,
                    # never the FPGA's required startup interval.
                    f=np.concatenate([np.zeros((64,16),dtype=np.int8),f])
                    predictions={};details={}
                    for name,(w1,b1,w2,b2,cfg) in models.items():
                        pairs=list(utterances(f)) if name=='candidate' else [(None,e) for e in endpoints(f,robust=True)]
                        windows=np.concatenate([normalized_windows(f,s,e) if name=='candidate' else endpoint_windows(f,e) for s,e in pairs]) if pairs else np.zeros((0,768))
                        z=integer_infer(windows,w1,b1,w2,b2,cfg['shift']).reshape(-1,3,3)
                        preds=decisions(z,cfg['margin']);accepted=preds[preds!=0]
                        predictions[name]=int(accepted[0]) if len(accepted) else 0
                        details[name]=dict(endpoints=len(pairs),predictions=preds.tolist())
                    records.append(dict(path=row['path'],label=row['label'],speaker=row['speaker'],noise=noise,rate=rate,predictions=predictions,details=details))
    def summary(group,name):
        cm=np.zeros((3,3),dtype=int)
        for r in group:cm[r['label'],r['predictions'][name]]+=1
        return dict(confusion=cm.tolist(),commands=int(cm[1:].sum()),correct=int(cm[1,1]+cm[2,2]),wrong_direction=int(cm[1,2]+cm[2,1]),negatives=int(cm[0].sum()),false_accepts=int(cm[0,1:].sum()))
    groups={}
    for noise in ['clean','noisy']:
        for rate in [.65,1.,1.45]:
            group=[r for r in records if r['noise']==noise and r['rate']==rate]
            groups[f'{noise}_rate{rate}']={n:summary(group,n) for n in models}
    report=dict(split=args.split,synthetic_only=True,speed_stress='Feature-domain pitch-preserving time interpolation; natural recordings also include two synthesized rates',
        noise='Full PCM front end: uniform +-500 plus 120/240Hz hum, speech gain 0.7',groups=groups,
        overall={n:summary(records,n) for n in models},details=records,
        source_sha256={str(p.relative_to(ROOT.parent)):sha(p) for p in [Path(__file__),ROOT/'tools/robust_common.py',ROOT/'tools/kws_common.py',ROOT/'model/weights.mem',exp/'model/weights.mem']})
    (exp/(args.split+'_comparison.json')).write_text(json.dumps(report,indent=2))
    print(json.dumps({k:v for k,v in report.items() if k not in ['details','source_sha256']},indent=2),flush=True)

if __name__=='__main__':main()
