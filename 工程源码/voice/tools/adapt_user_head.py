"""Offline owner adaptation candidate; never overwrites deployed ROMs.

Only the old recording's explicitly confirmed PREV/NEXT pair is labelled.
Repeated/augmented examples of those two utterances remain training data.
Select on synthetic validation with bounded errors, never on synthetic test.
"""
import os
os.environ.setdefault('OPENBLAS_NUM_THREADS','1')
from pathlib import Path
import hashlib,json
import numpy as np
import soundfile as sf
import torch
from kws_common import features,read_hex,integer_infer
from robust_common import utterances,normalized_windows,decisions
from probe_vad_continuity import prepare,gated_features

ROOT=Path(__file__).resolve().parents[2]
EXP=ROOT/'voice/experiments/robust_normalized'
OUT=ROOT/'voice/experiments/user_head_candidate'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()

def main():
 OUT.mkdir(exist_ok=True)
 torch.set_num_threads(4);torch.manual_seed(20261023);rng=np.random.default_rng(20261023)
 model=EXP/'model';w=read_hex(model/'weights.mem',8);b=read_hex(model/'bias.mem',32)
 w1=w[:36864].reshape(48,768);w2=w[36864:].reshape(3,48);b1=b[:48];b2=b[48:]
 hidden=lambda x:np.clip((np.asarray(x,dtype=np.int64)@w1.T+b1)>>8,0,127)
 with np.load(EXP/'train_dataset.npz') as d:
  tx=d['x'].reshape(-1,768);ty=np.repeat(d['y'],3)
 th=hidden(tx);print('synthetic training views',len(th),flush=True)
 # Full validation streams include clips rejected before model inference.
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
 vx=np.stack(vx);vh=hidden(vx.reshape(-1,768));labels=np.array(labels)
 def metrics(ow,ob):
  z=(vh@ow.T+ob).reshape(-1,3,3);pred=decisions(z,791,650,3600)
  p=np.zeros(len(labels),dtype=int)
  for own,pr in zip(owners,pred):
   if pr and not p[own]:p[own]=pr
  cm=np.zeros((3,3),dtype=int)
  for a,pr in zip(labels,p):cm[a,pr]+=1
  return dict(correct=int(cm[1,1]+cm[2,2]),wrong_direction=int(cm[1,2]+cm[2,1]),false_accepts=int(cm[0,1:].sum()),confusion=cm.tolist())
 baseline=metrics(w2,b2);assert tuple(baseline[k] for k in ['correct','wrong_direction','false_accepts'])==(410,13,7),baseline
 wav=ROOT/'verification/user_20261021_170604.wav'
 annotation=ROOT/'verification/real_voice_transient.json'
 ann=json.loads(annotation.read_text());assert ann['real_direction_labels_confirmed'] and ann['spoken_classes']==[2,1]
 assert ann['sources']['verification\\user_20261021_170604.wav']==sha(wav)
 a,sr=sf.read(wav,dtype='int16');assert sr==48000
 f=features(np.r_[np.zeros(98304,dtype=np.int16),a,np.zeros(73728,dtype=np.int16)],adaptive_vad=True,vad_hysteresis=True)
 pairs=list(utterances(f,prequiet=6));assert len(pairs)==2
 original=np.stack([normalized_windows(f,s,e) for s,e in pairs]);realx=[];realy=[]
 for (s,e),label in zip(pairs,[2,1]):
  speech=f[s:e-6]
  for n in range(96):
   rate=rng.uniform(.8,1.2);t=np.linspace(0,len(speech)-1,max(6,round(len(speech)/rate)))
   aug=np.stack([np.interp(t,np.arange(len(speech)),speech[:,j]) for j in range(16)],1)
   active=np.any(aug,axis=1)
   eq=np.interp(np.arange(16),[0,5,10,15],rng.normal(0,1.2,4))
   aug=np.clip(np.rint(aug+eq+rng.normal(0,.7,aug.shape)),0,64).astype(np.int8);aug[~active]=0
   aug=np.r_[aug,np.zeros((6,16),dtype=np.int8)]
   realx.append(normalized_windows(aug,0,len(aug)));realy.append(label)
 rh=hidden(np.stack(realx).reshape(-1,768));ry=np.repeat(realy,3)
 oh=hidden(original.reshape(-1,768))
 head=torch.nn.Linear(48,3)
 with torch.no_grad():head.weight.copy_(torch.tensor(w2/16,dtype=torch.float32));head.bias.copy_(torch.tensor(b2/512,dtype=torch.float32))
 xt=torch.tensor(th/32,dtype=torch.float32);yt=torch.tensor(ty,dtype=torch.long)
 rt=torch.tensor(rh/32,dtype=torch.float32);rlabels=torch.tensor(ry,dtype=torch.long)
 old_logits=torch.tensor((th@w2.T+b2)/512,dtype=torch.float32)
 opt=torch.optim.Adam(head.parameters(),lr=.001)
 best=None;history=[]
 for epoch in range(61):
  if epoch:
   for batch in torch.randperm(len(xt)).split(512):
    rb=torch.randint(len(rt),(64,));opt.zero_grad();z=head(xt[batch])
    # Rehearse the established classes and retain old output distributions.
    loss=torch.nn.functional.cross_entropy(z,yt[batch])
    loss+=torch.nn.functional.kl_div(torch.log_softmax(z,1),torch.softmax(old_logits[batch],1),reduction='batchmean')
    loss+=.5*torch.nn.functional.cross_entropy(head(rt[rb]),rlabels[rb])
    loss.backward();opt.step()
  if epoch%5:continue
  ow=np.rint(head.weight.detach().numpy()*16).astype(np.int64)
  ob=np.rint(head.bias.detach().numpy()*512).astype(np.int64)
  if np.abs(ow).max()>127:continue
  m=metrics(ow,ob);rz=(oh@ow.T+ob).reshape(2,3,3);rp=decisions(rz,791,650,3600)
  record=dict(epoch=epoch,validation=m,training_recording_predictions=rp.tolist())
  history.append(record);print(json.dumps(record),flush=True)
  # Both real utterances are TRAINING requirements, not held-out success.
  eligible=m['correct']>=baseline['correct'] and m['wrong_direction']<=baseline['wrong_direction'] and m['false_accepts']<=baseline['false_accepts'] and rp.tolist()==[2,1]
  if eligible:
   score=(m['correct'],-m['wrong_direction'],-m['false_accepts'])
   if best is None or score>best[0]:best=(score,ow.copy(),ob.copy(),record)
 report=dict(candidate_only=True,deployed_model_changed=False,real_training_utterances=2,
  independent_real_validation_utterances=0,real_training_source_sha256=sha(wav),
  real_annotations_source=str(annotation.relative_to(ROOT)),synthetic_test_not_used=True,
  synthetic_training_features_are_legacy=True,baseline_validation=baseline,history=history,
  eligible_candidate_found=best is not None,
  sources={str(p.relative_to(ROOT)):sha(p) for p in [Path(__file__),ROOT/'voice/tools/kws_common.py',ROOT/'voice/tools/robust_common.py',ROOT/'voice/tools/probe_vad_continuity.py',model/'weights.mem',model/'bias.mem',wav,annotation]},
  synthetic_manifest_sha256=sha(manifest))
 if best:
  _,ow,ob,record=best;dest=OUT/'model';dest.mkdir(exist_ok=True)
  def write(name,arr,bits):
   (dest/name).write_text(''.join(f'{int(x)&((1<<bits)-1):0{bits//4}x}\n' for x in arr.ravel()))
  write('weights.mem',np.r_[w1.ravel(),ow.ravel()],8);write('bias.mem',np.r_[b1,ob],32)
  cfg=json.loads((model/'config.json').read_text());cfg.update(synthetic_only=False,owner_adaptation_training_utterances=2,independent_real_validation=False)
  (dest/'config.json').write_text(json.dumps(cfg,indent=2))
  report['selected']=record;report['candidate_weight_sha256']=sha(dest/'weights.mem')
  exact=integer_infer(original.reshape(-1,768),w1,b1,ow,ob,8).reshape(2,3,3)
  assert decisions(exact,791,650,3600).tolist()==[2,1]
 (OUT/'adaptation_report.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
 print('Candidate eligible:',best is not None,'; deployed ROMs untouched; no independent real validation',flush=True)

if __name__=='__main__':main()
