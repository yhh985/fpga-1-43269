"""Paired gate audit on complete synthetic streams; fixed policy on test."""
import os
os.environ.setdefault('OPENBLAS_NUM_THREADS','1')
from pathlib import Path
import argparse,hashlib,json
import numpy as np
from kws_common import read_hex,integer_infer
from robust_common import utterances,normalized_windows,decisions

ROOT=Path(__file__).resolve().parents[2]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()

def main():
 ap=argparse.ArgumentParser();ap.add_argument('--split',choices=['validation','test'],default='validation');args=ap.parse_args()
 data=Path('E:/anlo_project/liantiao/voice');manifest=data/'data/manifest.json'
 rows=json.loads(manifest.read_text(encoding='utf-8'));ref=sha(ROOT/'voice/tools/kws_common.py');exp=ROOT/'voice/experiments/robust_normalized'
 w=read_hex(exp/'model/weights.mem',8);b=read_hex(exp/'model/bias.mem',32)
 windows=[];owners=[];labels=[];members=[];idx=0;cache_hashes={}
 for row in rows:
  if row['split']!=args.split:continue
  key=hashlib.sha256((sha(data/row['path'])+ref+'robust_noise_v1').encode()).hexdigest()
  cache=exp/'cache'/(key+'.npz');cache_hashes[str(cache.relative_to(ROOT))]=sha(cache)
  with np.load(cache) as c:
   for noise in ('clean','noisy'):
    original=c[noise]
    for rate in (.65,1.,1.45):
     f=original
     if rate!=1:
      t=np.linspace(0,len(f)-1,max(2,round(len(f)/rate)))
      f=np.rint(np.stack([np.interp(t,np.arange(len(f)),f[:,j]) for j in range(16)],1)).astype(np.int8)
     f=np.concatenate([np.zeros((64,16),dtype=np.int8),f]);old=set(utterances(f,prequiet=8));new=set(utterances(f,prequiet=6));labels.append(row['label'])
     for s,e in sorted(old|new):windows.append(normalized_windows(f,s,e));owners.append(idx);members.append([(s,e) in old,(s,e) in new])
     idx+=1
 z=integer_infer(np.concatenate(windows),w[:36864].reshape(48,768),b[:48],w[36864:].reshape(3,48),b[48:],8).reshape(-1,3,3)
 strict=decisions(z,791);relaxed=decisions(z,791,650,3600);summaries={}
 for name,mask,preds in [('old',0,strict),('quiet6_only',1,strict),('consensus_only',0,relaxed),('combined',1,relaxed)]:
  p=np.zeros(idx,dtype=int)
  for own,meta,pred in zip(owners,members,preds):
   if meta[mask] and pred and not p[own]:p[own]=pred
  cm=np.zeros((3,3),dtype=int)
  for a,bp in zip(labels,p):cm[a,bp]+=1
  summaries[name]=dict(confusion=cm.tolist(),commands=int(cm[1:].sum()),correct=int(cm[1,1]+cm[2,2]),wrong_direction=int(cm[1,2]+cm[2,1]),negatives=int(cm[0].sum()),false_accepts=int(cm[0,1:].sum()))
 report=dict(split=args.split,synthetic_only=True,test_used_for_selection=False,segments=len(windows),clips=idx,summary=summaries,
  policy=dict(prequiet=6,weakest_margin=650,total_margin=3600,strict_margin=791),
  sources={str(p.relative_to(ROOT)):sha(p) for p in [Path(__file__),ROOT/'voice/tools/robust_common.py',ROOT/'voice/tools/kws_common.py',exp/'model/weights.mem',exp/'model/bias.mem']},cache_hashes=cache_hashes,manifest_sha256=sha(manifest))
 out=ROOT/'verification'/('recognition_gate_'+args.split+'.json');out.write_text(json.dumps(report,indent=2),encoding='utf-8')
 print(json.dumps({k:v for k,v in report.items() if k not in ('sources','cache_hashes')},indent=2))

if __name__=='__main__':main()
