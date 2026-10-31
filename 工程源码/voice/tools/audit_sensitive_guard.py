"""Select a small guard around the historical fixed-window dense recognizer.

Only validation selects margins. Report the confirmed real pair without tuning
to it. Full-stream metrics include pre-inference rejects and first commands.
"""
import os
os.environ.setdefault('OPENBLAS_NUM_THREADS','1')
from pathlib import Path
import argparse,json,hashlib
import numpy as np
import soundfile as sf
from kws_common import read_hex,integer_infer,features,log4
from robust_common import utterances
from probe_vad_continuity import prepare,gated_features

ROOT=Path(__file__).resolve().parents[2];OUT=ROOT/'voice/experiments/sensitive_guard'
DATA=Path('E:/anlo_project/liantiao/voice');MODEL=ROOT/'voice/model'
LEGACY=DATA.parent/'verification/before_noise_fix_20261020'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()

def legacy_features(p):
 logs=log4(p);f=np.maximum(-64,logs-logs.max(1,keepdims=True)).astype(np.int16)
 f[p.max(1)<512]=-64
 noise=0;calibration=0;run=0
 for i,row in enumerate(logs):
  maximum=int(row.max());active=p[i].max()>=512 and maximum>(noise>>3)+8
  speech=calibration==16 and active
  if calibration<16:calibration+=1;noise=noise-(noise>>3)+maximum
  elif not active or run==127:noise=noise-(noise>>3)+maximum
  run=min(127,run+1) if active else 0
  if not speech:f[i]=-64
 n=len(f)//2
 return (((f[:n*2:2]+f[1:n*2:2])>>1)+64).astype(np.int8)

def native_window(f,s,e,isolate=True):
 x=np.zeros((48,16),dtype=np.int8);lo=max(s if isolate else 0,e-48)
 x[lo-(e-48):]=f[lo:e]
 return x.ravel()

def main():
 ap=argparse.ArgumentParser();ap.add_argument('--split',choices=['validation','test'],default='validation');args=ap.parse_args()
 OUT.mkdir(exist_ok=True)
 original=json.loads((LEGACY/'deliverable/release_manifest.json').read_text(encoding='utf-8'))
 for n in ['weights.mem','bias.mem']:assert sha(MODEL/n)==original['model'][n]
 w=read_hex(MODEL/'weights.mem',8);b=read_hex(MODEL/'bias.mem',32)
 infer=lambda x:integer_infer(x,w[:36864].reshape(48,768),b[:48],w[36864:].reshape(3,48),b[48:],9)
 rows=json.loads((DATA/'data/manifest.json').read_text(encoding='utf-8'))
 labels=[];owners=[];xs=[];meta=[]
 for ri,row in enumerate(rows):
  if row['split']!=args.split:continue
  _,clean,noisy=prepare((ri,row))
  for p in [clean,noisy]:
   for rate in [.65,1.,1.45]:
    own=len(labels);labels.append(row['label'])
    for frontend,original_f in [('legacy',legacy_features(p)),('guard',gated_features(p,'hysteresis'))]:
     f=original_f
     if rate!=1:
      t=np.linspace(0,len(f)-1,max(2,round(len(f)/rate)))
      f=np.rint(np.stack([np.interp(t,np.arange(len(f)),f[:,j]) for j in range(16)],1)).astype(np.int8)
     f=np.r_[np.zeros((64,16),dtype=np.int8),f]
     for s,e in utterances(f,prequiet=0,max_frames=64):
      for isolate in [False,True]:
       xs.append(native_window(f,s,e,isolate));owners.append(own);meta.append((frontend,isolate))
 z=infer(np.array(xs));win=z.argmax(1);gap=np.diff(np.sort(z,axis=1)[:,-2:]).ravel()
 policies={'original':('legacy',False,109,-2147483648)}
 if args.split=='validation':
  for iso in [False,True]:
   for margin in [109,160,220,300,400,500,600,800]:
    for score in [0,128,256]:policies[f'guard_iso{int(iso)}_m{margin}_s{score}']=('guard',iso,margin,score)
 else:
  selected=json.loads((OUT/'selected_policy.json').read_text());policies['selected']=tuple(selected['policy'])
 report={};labels=np.array(labels)
 for name,(frontend,iso,margin,minscore) in policies.items():
  p=np.zeros(len(labels),dtype=int)
  for own,m,cls,confidence,logits in zip(owners,meta,win,gap,z):
   if m==(frontend,iso) and cls and confidence>=margin and logits[cls]>=minscore and not p[own]:p[own]=cls
  cm=np.zeros((3,3),dtype=int)
  for a,pr in zip(labels,p):cm[a,pr]+=1
  report[name]=dict(policy=[frontend,iso,margin,minscore],correct=int(cm[1,1]+cm[2,2]),wrong_direction=int(cm[1,2]+cm[2,1]),false_accepts=int(cm[0,1:].sum()),confusion=cm.tolist())
 if args.split=='validation':
  # The user requested a modest guard on the sensitive version. Preserve its
  # recall within 1% of all command trials, reducing triggers by at least 20%,
  # selecting another high-rejection policy just to minimize false accepts.
  base=report['original']
  command_count=sum(sum(row) for row in base['confusion'][1:])
  eligible=[(name,r) for name,r in report.items() if name!='original' and r['policy'][1] and r['correct']>=base['correct']-command_count*.01 and r['false_accepts']<=base['false_accepts']*.8 and r['wrong_direction']<=base['wrong_direction']]
  if eligible:
   name,r=max(eligible,key=lambda item:(item[1]['correct'],-item[1]['wrong_direction'],-item[1]['false_accepts'],-item[1]['policy'][2]))
   (OUT/'selected_policy.json').write_text(json.dumps(dict(name=name,policy=r['policy'],selection_split='validation',validation=r,selection_rule='Correct-count loss <=1% of command trials; no more direction errors; >=20% fewer background accepts than sensitive baseline.'),indent=2))
  else:
   (OUT/'selected_policy.json').unlink(missing_ok=True)
   print('NO ELIGIBLE POLICY',flush=True)
 a,sr=sf.read(ROOT/'verification/user_20261021_170604.wav',dtype='int16');assert sr==48000
 f=features(np.r_[np.zeros(98304,dtype=np.int16),a,np.zeros(73728,dtype=np.int16)],True,vad_hysteresis=True)
 real=[]
 for s,e in utterances(f,prequiet=0,max_frames=64):
  zz=infer(native_window(f,s,e)[None])[0];real.append(dict(start=s,end=e,logits=zz.tolist(),winner=int(zz.argmax()),margin=int(np.diff(np.sort(zz)[-2:])[0])))
 result=dict(split=args.split,synthetic_only=True,policies=report,real_recording_report_only=real,
  real_consulted_during_design=True,real_independent_validation=False,numeric_policy_selected_on_validation=True,production_changed=False,
  sources={str(p):sha(p) for p in [Path(__file__),ROOT/'voice/tools/kws_common.py',ROOT/'voice/tools/robust_common.py',ROOT/'voice/tools/probe_vad_continuity.py',MODEL/'weights.mem',MODEL/'bias.mem',DATA/'data/manifest.json']})
 (OUT/(args.split+'_report.json')).write_text(json.dumps(result,indent=2),encoding='utf-8')
 print(json.dumps(result['policies'],indent=2),flush=True)
 print('Real recording, not selection:',json.dumps(real),flush=True)

if __name__=='__main__':main()
