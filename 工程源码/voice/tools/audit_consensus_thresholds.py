"""Audit fixed-model decision gates on validation; do not tune on human captures."""
import os
os.environ.setdefault('OPENBLAS_NUM_THREADS','1')
from pathlib import Path
import hashlib,json,sys
import numpy as np
from kws_common import integer_infer,read_hex

ROOT=Path(__file__).resolve().parents[2]
MODEL=ROOT/'voice/experiments/robust_normalized/model'

def predict(z,margin,votes=3,total=0):
 wins=z.argmax(-1);gaps=np.diff(np.sort(z,axis=-1)[...,-2:],axis=-1)[...,0]
 result=np.zeros(len(z),dtype=np.int8)
 for command in (1,2):
  strong=((wins==command)&(gaps>=margin)).sum(1)>=votes
  if total:
   strong&=gaps.sum(1)>=total
   strong|=((wins==command)&(gaps>=791)).sum(1)==3
  # Never override another non-background direction, even a weak one.
  conflict=(wins==3-command).any(1)
  result[strong & ~conflict]=command
 return result

def summary(y,p):
 cm=np.zeros((3,3),dtype=int)
 for a,b in zip(y,p):cm[a,b]+=1
 return dict(confusion=cm.tolist(),correct=int(cm[1,1]+cm[2,2]),
  wrong_direction=int(cm[1,2]+cm[2,1]),false_accepts=int(cm[0,1:].sum()),
  commands=int((y!=0).sum()),negatives=int((y==0).sum()))

def main():
 w=read_hex(MODEL/'weights.mem',8);b=read_hex(MODEL/'bias.mem',32)
 p=ROOT/'voice/experiments/robust_normalized/validation_dataset.npz'
 data=np.load(p);y=data['y']
 z=integer_infer(data['x'].reshape(-1,768),w[:36864].reshape(48,768),b[:48],
  w[36864:].reshape(3,48),b[48:],8).reshape(-1,3,3)
 baseline=summary(y,predict(z,791,3));rows=[]
 for votes in (3,2):
  for margin in sorted(set(range(250,1501,50))|{791}):
   r=dict(votes=votes,margin=margin,**summary(y,predict(z,margin,votes)))
   r['eligible']=r['false_accepts']<=baseline['false_accepts'] and r['wrong_direction']<=baseline['wrong_direction']
   rows.append(r)
 for floor in (400,500,600,650,700):
  for total in (2373,2700,3000,3300,3600):
   r=dict(votes=3,margin=floor,total_margin=total,**summary(y,predict(z,floor,3,total)))
   r['eligible']=r['false_accepts']<=baseline['false_accepts'] and r['wrong_direction']<=baseline['wrong_direction']
   rows.append(r)
 best=max((r for r in rows if r['eligible']),key=lambda r:(r['correct'],-r['wrong_direction'],-r['false_accepts'],r['votes'],r['margin']))
 report=dict(validation_only=True,test_used_for_selection=False,human_used_for_selection=False,
  baseline=baseline,selected=best,rows=rows,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path(__file__),p,MODEL/'weights.mem',MODEL/'bias.mem']})
 # Human captures are unlabeled; report decisions, never score them as accuracy.
 sys.path.insert(0,str(ROOT/'tools'))
 from decode_voice_capture import packets
 from robust_common import normalized_windows
 reports=[]
 for path in sorted((ROOT/'verification').glob('voice_capture_20261023_*.replay.json')):
  raw=path.with_suffix('').with_suffix('.bin')
  if not raw.exists():continue
  blocks,bad=packets(raw.read_bytes())
  if bad or not blocks:continue
  f=np.array([list(block[12:28]) for block in blocks],dtype=np.int8)
  for a in json.loads(path.read_text(encoding='utf-8'))['attempts']:
   if not a.get('complete') or a.get('voiced_frames',0)<6 or a.get('duration_frames',999)>96:continue
   zz=integer_infer(normalized_windows(f,a['start_frame'],a['end_frame']),w[:36864].reshape(48,768),b[:48],w[36864:].reshape(3,48),b[48:],8)[None]
   reports.append(dict(capture=raw.name,sequence=a['sequence'],label=None,
    old=int(predict(zz,791,3)[0]),candidate=int(predict(zz,best['margin'],best['votes'],best.get('total_margin',0))[0]),
    existing_gate_flags=a.get('flags',0)&15,logits=zz[0].tolist()))
 report['unlabelled_hardware_decisions']=reports
 out=ROOT/'verification/consensus_gate_audit.json';out.write_text(json.dumps(report,indent=2),encoding='utf-8')
 print(json.dumps(dict(baseline=baseline,selected=best,human_decision_changes=[r for r in reports if r['old']!=r['candidate']]),indent=2))

if __name__=='__main__':main()
