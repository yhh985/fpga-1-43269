"""Compare full CTC alignment probabilities for commands, negatives and blank.

Thresholds use synthetic validation only. This does not force a binary choice:
twelve phrases plus empty compete, with an absolute likelihood acceptance gate.
"""
import os
os.environ.setdefault('OPENBLAS_NUM_THREADS','1')
import json,hashlib
from pathlib import Path
import numpy as np
import torch
import soundfile as sf
from train_masked_acoustic_codes import ROOT,OUT,Net,batch,base,TEXTS,VOCAB
from train_sequence_ctc import candidates
from kws_common import mel_powers,decimate

PHRASES=TEXTS+['']
CODES=[[VOCAB[c] for c in text] for text in PHRASES]

@torch.no_grad()
def score(net,xs):
    scores=[]
    for lo in range(0,len(xs),32):
        x,lens=batch(xs[lo:lo+32]);z,_=net(x,lens);n=len(x);k=len(CODES)
        lp=z.log_softmax(2).repeat_interleave(k,dim=0).transpose(0,1).contiguous()
        targets=torch.tensor([t for _ in range(n) for code in CODES for t in code],dtype=torch.long)
        tls=torch.tensor([len(code) for _ in range(n) for code in CODES],dtype=torch.long)
        loss=torch.nn.functional.ctc_loss(lp,targets,lens.repeat_interleave(k),tls,blank=0,reduction='none',zero_infinity=False)
        scores.append(-loss.reshape(n,k).numpy())
    return np.concatenate(scores)

def decode(scores,lengths,margin,floor):
    output=[]
    for s,n in zip(scores,lengths):
        order=np.argsort(s);best,second=order[-1],order[-2];text=PHRASES[best]
        cls=next((c for c,w in base.WORDS.items() if text==w),0)
        gap=float(s[best]-s[second]);perframe=float(s[best]/n)
        if gap<margin or perframe<floor:cls=0
        output.append((cls,gap,text))
    return output

def main():
    torch.set_num_threads(2);net=Net();net.load_state_dict(torch.load(OUT/'candidate.pt',weights_only=True));net.eval()
    ds=np.load(ROOT/'voice/experiments/sequence_ctc/dataset.npz')
    def get(name):
        lens=ds[name+'_lengths'];return np.split(ds[name+'_x'],np.cumsum(lens)[:-1]),lens,ds[name+'_owners'],ds[name+'_labels']
    xs,lens,owners,labels=get('validation');s=score(net,xs);options=[]
    for margin in [0,.5,1,2,3,4,6,8,12,24,1e9]:
        for floor in [-.05,-.1,-.2,-.5,-1,-2,-4,-1e9]:
            d=decode(s,lens,margin,floor);m=base.metrics(labels,owners,d,0)
            if m['false_accepts']<=8:options.append(((m['correct']-3*m['wrong_direction'],m['correct'],-m['false_accepts']),margin,floor,m))
    rank,margin,floor,validation=max(options,key=lambda t:t[0])
    xs,lens,owners,labels=get('test');s=score(net,xs)
    report=dict(experimental_only=True,fpga_deployed=False,real_used_for_selection=False,
                test_previously_inspected=True,margin=margin,min_log_probability_per_frame=floor,
                validation=validation,test=base.metrics(labels,owners,decode(s,lens,margin,floor),0))
    wav=ROOT/'verification/user_20261021_170604.wav';a,sr=sf.read(wav,dtype='int16');assert sr==48000
    clips=candidates(mel_powers(decimate(np.r_[np.zeros(98304,dtype=np.int16),a,np.zeros(73728,dtype=np.int16)])))
    xs=[x for x,_,_,_ in clips];s=score(net,xs);lens=[len(x) for x in xs];d=decode(s,lens,margin,floor)
    report['real_reused_development']=[dict(expected=expected,command=c,text=t,gap=g,
        log_probability_per_frame=float(row.max()/n)) for expected,(c,g,t),row,n in zip([2,1],d,s,lens)]
    report['sources']={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path(__file__),OUT/'candidate.pt',wav]}
    (OUT/'ctc_paths_report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf8')
    print(json.dumps(report,ensure_ascii=True,indent=2))

if __name__=='__main__':main()
