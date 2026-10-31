"""Equal V5/V6 score ensemble; thresholds selected on synthetic validation only."""
import hashlib,json
from pathlib import Path
import numpy as np
import torch
from train_directional_ctc import ROOT,Net,decisions,base
from evaluate_tempo_consensus import score_views

OUT=ROOT/'voice/experiments/acoustic_codes_v5v6'
CHECKPOINTS=[ROOT/f'voice/experiments/acoustic_codes_{v}/candidate.pt' for v in ['v5','v6']]

def load_models():
    models=[]
    for p in CHECKPOINTS:
        net=Net();net.load_state_dict(torch.load(p,weights_only=True));net.eval();models.append(net)
    return models

def score_models(models,xs):
    return np.mean([score_views(net,xs) for net in models],axis=0)

def main():
    torch.set_num_threads(2);OUT.mkdir(parents=True,exist_ok=True);models=load_models()
    ds=np.load(ROOT/'voice/experiments/sequence_ctc/dataset.npz')
    def get(split):
        lens=ds[split+'_lengths'];return np.split(ds[split+'_x'],np.cumsum(lens)[:-1]),lens,ds[split+'_owners'],ds[split+'_labels']
    xs,lens,o,y=get('validation');s=score_models(models,xs);options=[]
    for margin in [0,.5,1,2,3,4,6,8,12,24,1e9]:
        for floor in [-.05,-.1,-.2,-.5,-1,-2,-4]:
            m=base.metrics(y,o,decisions(s,lens,margin,floor),0)
            if m['false_accepts']<=8:options.append(((m['correct']-5*m['wrong_direction'],m['correct'],-m['false_accepts']),margin,floor,m))
    _,margin,floor,m=max(options,key=lambda t:t[0]);selected=dict(margin=margin,floor=floor,validation=m)
    (OUT/'tempo_selected.json').write_text(json.dumps(selected,indent=2))
    xs,lens,o,y=get('test');s=score_models(models,xs)
    report=dict(experimental_only=True,fpga_deployed=False,real_used_for_selection=False,test_previously_inspected=True,
                equal_model_weights=True,forward_passes_per_clip=6,selected=selected,
                test=base.metrics(y,o,decisions(s,lens,margin,floor),0),
                sources={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path(__file__),*CHECKPOINTS,ROOT/'voice/tools/evaluate_tempo_consensus.py']})
    (OUT/'tempo_report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))

if __name__=='__main__':main()
