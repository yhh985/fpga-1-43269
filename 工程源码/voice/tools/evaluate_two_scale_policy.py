"""Validation-only estimate of two-scale NEXT gate/confirmation policy."""
import sys,json
from pathlib import Path
import numpy as np
import torch
sys.path.insert(0,str(Path(__file__).resolve().parent))
import train_directional_ctc as model
from evaluate_tempo_consensus import RATES
from train_masked_acoustic_codes import batch
ROOT=model.ROOT
def main():
 torch.set_num_threads(2);net=model.Net();net.load_state_dict(torch.load(ROOT/'voice/experiments/acoustic_codes_v5/candidate.pt',weights_only=True));net.eval()
 ds=np.load(ROOT/'voice/experiments/sequence_ctc/dataset.npz');reports={}
 for split in ['validation','test']:
  lengths=ds[split+'_lengths'];xs=np.split(ds[split+'_x'],np.cumsum(lengths)[:-1]);owners=ds[split+'_owners'];labels=ds[split+'_labels'].copy();labels[labels==2]=0
  all_scores=[]
  for rate in RATES:
   variants=[np.rint(np.stack([np.interp(np.arange(max(8,round(len(x)/rate)))*rate,np.arange(len(x)),x[:,j]) for j in range(16)],1)).astype(np.int8) for x in xs]
   all_scores.append(model.scores(net,variants))
  scores=np.stack(all_scores);policies={}
  for quick in range(3):
   for confirm in range(3):
    if quick==confirm:continue
    accepted=[]
    for i,x in enumerate(xs):
     def dec(row):
      o=np.argsort(row);return int(o[-1]),float(row[o[-1]]-row[o[-2]]),float(row[o[-1]]/len(x))
     a,ga,fa=dec(scores[quick,i]);b,gb,fb=dec(scores[confirm,i])
     accepted.append(a==2 and ga>=6 and fa>=-.1 and b==2 and gb>=2 and fb>=-.2)
    pred=np.zeros(len(labels),dtype=np.int8)
    for owner,ok in zip(owners,accepted):
     if ok:pred[owner]=1
    cm=np.zeros((2,2),dtype=int)
    for y,p in zip(labels,pred):cm[int(y!=1),p]+=1
    policies[f'{quick}->{confirm}']=cm.tolist()
  reports[split]=policies
  print(split,json.dumps(policies),flush=True)
 out=ROOT/'verification/two_scale_policy.json';out.write_text(json.dumps(reports,indent=2))
if __name__=='__main__':main()
