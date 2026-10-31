"""Synthetic-validation-selected tempo consensus; no real-audio tuning."""
import argparse,json,hashlib
from pathlib import Path
import numpy as np
import torch
from train_directional_ctc import ROOT,OUT,Net,scores,decisions,base

RATES=[.8,1.,1.25]

def score_views(net,xs):
    all_scores=[]
    for rate in RATES:
        variants=[]
        for x in xs:
            pos=np.arange(max(8,round(len(x)/rate)))*rate
            variants.append(np.rint(np.stack([np.interp(pos,np.arange(len(x)),x[:,j]) for j in range(16)],1)).astype(np.int8))
        # Normalize each alignment by its frame count before averaging.
        all_scores.append(scores(net,variants)/np.array([len(x) for x in variants])[:,None])
    return np.mean(all_scores,axis=0)*np.array([len(x) for x in xs])[:,None]

def main():
    global OUT
    ap=argparse.ArgumentParser();ap.add_argument('--version',choices=['v5','v6'],default='v5');args=ap.parse_args()
    OUT=ROOT/('voice/experiments/acoustic_codes_'+args.version)
    torch.set_num_threads(2);net=Net();net.load_state_dict(torch.load(OUT/'candidate.pt',weights_only=True));net.eval()
    ds=np.load(ROOT/'voice/experiments/sequence_ctc/dataset.npz')
    def get(split):
        lens=ds[split+'_lengths'];return np.split(ds[split+'_x'],np.cumsum(lens)[:-1]),lens,ds[split+'_owners'],ds[split+'_labels']
    xs,lens,o,y=get('validation');s=score_views(net,xs);options=[]
    for margin in [0,.5,1,2,3,4,6,8,12,24,1e9]:
        for floor in [-.05,-.1,-.2,-.5,-1,-2,-4]:
            m=base.metrics(y,o,decisions(s,lens,margin,floor),0)
            if m['false_accepts']<=8:options.append(((m['correct']-5*m['wrong_direction'],m['correct'],-m['false_accepts']),margin,floor,m))
    rank,margin,floor,m=max(options,key=lambda t:t[0])
    selected=dict(margin=margin,floor=floor,rates=RATES,validation=m)
    (OUT/'tempo_selected.json').write_text(json.dumps(selected,indent=2))
    xs,lens,o,y=get('test');s=score_views(net,xs)
    report=dict(version=args.version,experimental_only=True,fpga_deployed=False,real_used_for_selection=False,test_previously_inspected=True,
                selected=selected,test=base.metrics(y,o,decisions(s,lens,margin,floor),0),
                sources={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path(__file__),OUT/'candidate.pt']})
    (OUT/'tempo_report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))

if __name__=='__main__':main()
