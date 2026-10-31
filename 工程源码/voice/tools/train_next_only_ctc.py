"""Train a V5-shaped, complete-transcript NEXT-vs-background CTC candidate."""
import os
os.environ.setdefault('OPENBLAS_NUM_THREADS','1')
from pathlib import Path
import hashlib,json
import numpy as np
import torch
from torch import nn
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
import train_masked_acoustic_codes as acoustic
import train_directional_ctc as directional

ROOT=acoustic.ROOT
OUT=ROOT/'voice/experiments/next_only_ctc'
PHRASES=['下一张','']
CODES=[[directional.VOCAB[c] for c in t] for t in PHRASES]

def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def fit(net,xs,ys,opt):
    x,lens=acoustic.batch(xs);z,_=net(x,lens);lp=z.log_softmax(2).transpose(0,1).contiguous()
    target=torch.tensor([c for y in ys for c in CODES[y]],dtype=torch.long)
    tl=torch.tensor([len(CODES[y]) for y in ys])
    loss=nn.functional.ctc_loss(lp,target,lens,tl,blank=0,reduction='none',zero_infinity=True)
    loss=(loss/tl.clamp(min=1)).mean()
    opt.zero_grad();loss.backward();nn.utils.clip_grad_norm_(net.parameters(),3);opt.step()
    return float(loss.detach())
@torch.no_grad()
def scores(net,xs):
    out=[]
    for lo in range(0,len(xs),64):
        x,l=acoustic.batch(xs[lo:lo+64]);z,_=net(x,l)
        lp=z.log_softmax(2).transpose(0,1).contiguous()
        target=torch.tensor([0,12]*len(x),dtype=torch.long);tl=torch.ones(len(x)*2,dtype=torch.long)
        # Separate CTC scores for command and empty transcript.
        pieces=[]
        for k,code in enumerate(CODES):
            tg=torch.tensor(code*len(x),dtype=torch.long);lens_t=torch.full((len(x),),len(code),dtype=torch.long)
            pieces.append(-nn.functional.ctc_loss(lp,tg,l,lens_t,blank=0,reduction='none',zero_infinity=True).numpy())
        out.append(np.stack(pieces,1))
    return np.concatenate(out)
def measure(s,owners,labels,margin,floor):
    pred=np.zeros(len(labels),dtype=np.int8)
    gap=s[:,0]-s[:,1]
    accept=(gap>=margin)&(s[:,0]>=floor)
    for o,a in zip(owners,accept):
        if a:pred[o]=1
    cm=np.zeros((2,2),dtype=int)
    for y,p in zip(labels,pred):cm[int(y!=1),p]+=1
    return {'correct':int(cm[1,1]),'reject':int(cm[1,0]),'false_accepts':int(cm[0,1]),'confusion':cm.tolist()}
def main():
    torch.set_num_threads(2);torch.manual_seed(20261026);rng=np.random.default_rng(20261026);OUT.mkdir(exist_ok=True,parents=True)
    init=ROOT/'voice/experiments/acoustic_codes_v5/candidate.pt'
    source=ROOT/'voice/experiments/sequence_ctc/dataset.npz'
    ds=np.load(source)
    train=np.split(ds['train_x'],np.cumsum(ds['train_lengths'])[:-1]);owner=ds['train_owners'];labels=ds['train_labels']
    # Collapse repeated augmented candidates per source trial into balanced classes.
    ids={0:np.flatnonzero(labels[owner]==0),1:np.flatnonzero(labels[owner]==1)}
    print('candidate fragments',{k:len(v) for k,v in ids.items()},flush=True)
    net=acoustic.Net();state=torch.load(init,weights_only=True)
    # V5 has the same 39-token head; retain its representation and reinitialize
    # only blank/command/other logits into a 3-class head in a separate model.
    net.load_state_dict(state);net.eval()
    # Keep the deployed vocabulary, train full NEXT transcript versus empty.
    opt=torch.optim.AdamW(net.parameters(),lr=0.00006,weight_decay=0.001)
    history=[]
    for epoch in range(16):
        net.train()
        for n in net.norms:n.eval()
        nsteps=max(1,len(ids[1])//48)
        losses=[]
        for _ in range(nsteps):
            picks=np.r_[rng.choice(ids[0],48,replace=len(ids[0])<48),rng.choice(ids[1],48,replace=len(ids[1])<48)]
            rng.shuffle(picks);xs=[];ys=[]
            for i in picks:
                x=train[i].astype(np.float32).copy();y=int(labels[owner[i]]==1)
                if y:
                    rate=float(rng.uniform(.75,1.35));pos=np.arange(max(8,round(len(x)/rate)))*rate
                    x=np.stack([np.interp(pos,np.arange(len(x)),x[:,j]) for j in range(16)],1)
                    if rng.random()<.7:
                        active=np.any(x,axis=1);eq=np.interp(np.arange(16),[0,5,10,15],rng.normal(0,2.5,4))
                        x[active]=np.clip(x[active]+eq+rng.normal(0,1,x[active].shape),0,64)
                x=np.pad(x,((int(rng.integers(0,13)),int(rng.integers(0,13))),(0,0)))
                xs.append(x);ys.append(y)
            losses.append(fit(net,xs,ys,opt))
        history.append(float(np.mean(losses)))
        if epoch%4==3:print('epoch',epoch,'loss',round(history[-1],4),flush=True)
    torch.save(net.state_dict(),OUT/'candidate.pt')
    report={'experimental_only':True,'deployed':False,'targets':['下一张','<blank>'],
        'loss_tail':history[-4:],'checkpoint_sha256':sha(OUT/'candidate.pt'),
        'sources':{str(p):sha(p) for p in [Path(__file__),init,source,ROOT/'voice/experiments/sequence_ctc/dataset_sources.json']}}
    (OUT/'training_report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf8')
    print(json.dumps(report,ensure_ascii=False),flush=True)
if __name__=='__main__':main()
