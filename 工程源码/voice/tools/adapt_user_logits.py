"""Minimum-change output-head adaptation; offline candidate, not a release.

Two confirmed user utterances are training anchors. Their replay is not accuracy.
Preserve original logits on synthetic TRAIN, select only on VALIDATION.
"""
import os
os.environ.setdefault('OPENBLAS_NUM_THREADS','1')
from pathlib import Path
import json,hashlib
import numpy as np
import soundfile as sf
from kws_common import read_hex,features
from robust_common import utterances,normalized_windows,decisions
from probe_vad_continuity import prepare,gated_features

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'voice/experiments/user_logits_candidate'
MODEL=ROOT/'voice/experiments/robust_normalized/model'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()

def main():
 OUT.mkdir(exist_ok=True)
 w=read_hex(MODEL/'weights.mem',8);b=read_hex(MODEL/'bias.mem',32)
 w1=w[:36864].reshape(48,768);w2=w[36864:].reshape(3,48);b1=b[:48];b2=b[48:]
 hidden=lambda x:np.clip((np.asarray(x,dtype=np.int64)@w1.T+b1)>>8,0,127)
 with np.load(ROOT/'voice/experiments/robust_normalized/train_dataset.npz') as d:
  h=hidden(d['x'].reshape(-1,768))
 X=np.c_[h/32,np.ones(len(h))];C=X.T@X/len(X)
 manifest=Path('E:/anlo_project/liantiao/voice/data/manifest.json')
 rows=json.loads(manifest.read_text(encoding='utf-8'));vx=[];owners=[];labels=[]
 for ri,row in enumerate(rows):
  if row['split']!='validation':continue
  _,clean,noisy=prepare((ri,row))
  for powers in [clean,noisy]:
   original=gated_features(powers,'hysteresis')
   for rate in [.65,1.,1.45]:
    f=original
    if rate!=1:
     t=np.linspace(0,len(f)-1,max(2,round(len(f)/rate)))
     f=np.rint(np.stack([np.interp(t,np.arange(len(f)),f[:,j]) for j in range(16)],1)).astype(np.int8)
    f=np.r_[np.zeros((64,16),dtype=np.int8),f]
    own=len(labels);labels.append(row['label'])
    for s,e in utterances(f,prequiet=6):vx.append(normalized_windows(f,s,e));owners.append(own)
 vh=hidden(np.stack(vx).reshape(-1,768));labels=np.array(labels)
 def metrics(ow,ob):
  p=np.zeros(len(labels),dtype=int)
  pred=decisions((vh@ow.T+ob).reshape(-1,3,3),791,650,3600)
  for own,pr in zip(owners,pred):
   if pr and not p[own]:p[own]=pr
  cm=np.zeros((3,3),dtype=int)
  for a,pr in zip(labels,p):cm[a,pr]+=1
  return dict(correct=int(cm[1,1]+cm[2,2]),wrong_direction=int(cm[1,2]+cm[2,1]),false_accepts=int(cm[0,1:].sum()),confusion=cm.tolist())
 baseline=metrics(w2,b2);assert (baseline['correct'],baseline['wrong_direction'],baseline['false_accepts'])==(410,13,7)
 wav=ROOT/'verification/user_20261021_170604.wav';annotation=ROOT/'verification/real_voice_transient.json'
 ann=json.loads(annotation.read_text());assert ann['real_direction_labels_confirmed'] and ann['spoken_classes']==[2,1]
 assert ann['sources']['verification\\user_20261021_170604.wav']==sha(wav)
 a,sr=sf.read(wav,dtype='int16');assert sr==48000
 f=features(np.r_[np.zeros(98304,dtype=np.int16),a,np.zeros(73728,dtype=np.int16)],adaptive_vad=True,vad_hysteresis=True)
 pairs=list(utterances(f,prequiet=6));assert len(pairs)==2
 realx=np.stack([normalized_windows(f,s,e) for s,e in pairs]);rh=hidden(realx.reshape(-1,768))
 A=np.c_[rh/32,np.ones(len(rh))];old=(rh@w2.T+b2)/512
 targets=np.zeros_like(old)
 for i,label in enumerate(np.repeat([2,1],3)):
  if label==1:targets[i,label]=max(0,max(np.delete(old[i],label))+3-old[i,label])
 original_head=np.r_[w2.T/16,b2[None,:]/512]
 history=[];best=None
 for ridge in [.0001,.001,.01,.1,1.]:
  inv_a=np.linalg.solve(C+ridge*np.eye(49),A.T)
  for penalty in [.0001,.01,1.,10.]:
   delta=inv_a@np.linalg.solve(A@inv_a+penalty*np.eye(6),targets)
   head=original_head+delta
   ow=np.rint(head[:48].T*16).astype(np.int64);ob=np.rint(head[48]*512).astype(np.int64)
   if np.abs(ow).max()>127:continue
   m=metrics(ow,ob);pred=decisions((rh@ow.T+ob).reshape(2,3,3),791,650,3600).tolist()
   r=dict(ridge=ridge,penalty=penalty,validation=m,training_recording_predictions=pred)
   history.append(r);print(json.dumps(r),flush=True)
   if pred==[2,1] and m['correct']>=410 and m['wrong_direction']<=13 and m['false_accepts']<=7:
    score=(m['correct'],-m['wrong_direction'],-m['false_accepts'])
    if best is None or score>best[0]:best=(score,ow,ob,r)
 report=dict(candidate_only=True,deployed_model_changed=False,real_training_utterances=2,
  independent_real_validation_utterances=0,synthetic_test_not_used=True,baseline_validation=baseline,
  history=history,eligible_candidate_found=best is not None,
  sources={str(p.relative_to(ROOT)):sha(p) for p in [Path(__file__),ROOT/'voice/tools/kws_common.py',ROOT/'voice/tools/robust_common.py',ROOT/'voice/tools/probe_vad_continuity.py',MODEL/'weights.mem',MODEL/'bias.mem',wav,annotation]},
  synthetic_manifest_sha256=sha(manifest))
 if best:
  _,ow,ob,r=best;dest=OUT/'model';dest.mkdir(exist_ok=True)
  def write(name,arr,bits):
   (dest/name).write_text(''.join(f'{int(x)&((1<<bits)-1):0{bits//4}x}\n' for x in arr.ravel()))
  write('weights.mem',np.r_[w1.ravel(),ow.ravel()],8);write('bias.mem',np.r_[b1,ob],32)
  cfg=json.loads((MODEL/'config.json').read_text());cfg.update(synthetic_only=False,owner_adaptation_training_utterances=2,independent_real_validation=False)
  (dest/'config.json').write_text(json.dumps(cfg,indent=2));report['selected']=r
  report['candidate_weight_sha256']=sha(dest/'weights.mem')
 (OUT/'adaptation_report.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
 print('Candidate eligible:',best is not None,'; deployed ROMs untouched; no independent real validation',flush=True)

if __name__=='__main__':main()
