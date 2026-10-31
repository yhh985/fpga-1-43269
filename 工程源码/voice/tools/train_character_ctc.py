"""Character-unit temporal CTC candidate, with complete negative transcripts.

The earlier four-unit pilot confuses a broad OTHER target with initial syllables.
This experiment uses the existing transcript for every synthetic phrase instead.
No owner recording trains or selects this model. No board sources are changed.
"""
import os
os.environ.setdefault('OPENBLAS_NUM_THREADS', '1')
from pathlib import Path
import argparse, hashlib, json, time
import numpy as np
import soundfile as sf
import torch
from torch import nn
from train_sequence_ctc import batch, candidates, sha, ROOT, DATA
from kws_common import mel_powers, decimate

OUT = ROOT/'voice/experiments/character_ctc'
MANIFEST = DATA/'data/manifest.json'
ROWS = json.loads(MANIFEST.read_text(encoding='utf-8'))
TOKENS = ['<blank>', '<other>'] + sorted(set(''.join(row['text'] for row in ROWS)))
VOCAB = {s:i for i,s in enumerate(TOKENS)}
WORDS = {1: '\u4e0b\u4e00\u5f20', 2: '\u4e0a\u4e00\u5f20'}

class Block(nn.Module):
    def __init__(self, dilation):
        super().__init__()
        self.dilation = dilation
        self.memory = nn.Conv1d(64,64,9,groups=64,dilation=dilation,bias=False)
        self.mix = nn.Conv1d(64,64,1)
    def forward(self,x):
        return torch.clamp(self.mix(x+self.memory(nn.functional.pad(x,(8*self.dilation,0)))),0,4)

class Net(nn.Module):
    def __init__(self):
        super().__init__()
        self.front = nn.Conv1d(16,64,5,padding=2)
        self.mem1 = Block(1)
        self.mem2 = Block(2)
        self.out = nn.Conv1d(64,len(TOKENS),1)
    def forward(self,x):
        x = torch.clamp(self.front(x.transpose(1,2)),0,4)
        return self.out(self.mem2(self.mem1(x))).transpose(1,2)

def decode(z):
    ids=z.argmax(1);units=[];gaps=[];last=0
    for i,k in enumerate(ids):
        if k and k!=last:
            units.append(int(k));gaps.append(float(z[i,k]-np.max(np.delete(z[i],k))))
        elif k and units and k==last:
            gaps[-1]=max(gaps[-1],float(z[i,k]-np.max(np.delete(z[i],k))))
        last=k
    text=''.join(TOKENS[k] for k in units)
    # Exact three-character command. No approximate xia/shang substitution.
    command=next((c for c,w in WORDS.items() if text==w),0)
    return command,min(gaps) if command else -1,text

@torch.no_grad()
def infer(net,xs):
    out=[]
    for lo in range(0,len(xs),64):
        x,lens=batch(xs[lo:lo+64]);z=net(x).numpy()
        out += [decode(a[:int(n)]) for a,n in zip(z,lens)]
    return out

def metrics(labs,owners,decoded,margin):
    pred=np.zeros(len(labs),dtype=np.int8)
    for owner,(cls,gap,_) in zip(owners,decoded):
        if cls and gap>=margin and pred[owner]==0:pred[owner]=cls
    cm=np.zeros((3,3),dtype=int)
    for a,b in zip(labs,pred):cm[a,b]+=1
    return dict(correct=int(cm[1,1]+cm[2,2]),wrong_direction=int(cm[1,2]+cm[2,1]),
                false_accepts=int(cm[0,1:].sum()),confusion=cm.tolist())

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--epochs',type=int,default=120)
    args=ap.parse_args();OUT.mkdir(exist_ok=True)
    torch.set_num_threads(4);torch.manual_seed(20261024)
    rng=np.random.default_rng(20261024)
    source=ROOT/'voice/experiments/sequence_ctc/dataset.npz'
    ds=np.load(source)
    def split(name):
        lens=ds[name+'_lengths'];owners=ds[name+'_owners'];labs=ds[name+'_labels']
        xs=np.split(ds[name+'_x'],np.cumsum(lens)[:-1])
        original=np.split(ds[name+'_targets'],np.cumsum(ds[name+'_target_lengths'])[:-1])
        rows=[r for r in ROWS if r['split']==name]
        assert len(labs)==len(rows)*6
        for owner,lab in enumerate(labs):assert lab==rows[owner//6]['label']
        longest={}
        for i,owner in enumerate(owners):
            if owner not in longest or lens[i]>lens[longest[owner]]:longest[owner]=i
        targets=[]
        for i,owner in enumerate(owners):
            row=rows[owner//6]
            full=(len(original[i])==3 if row['label'] else longest[owner]==i)
            targets.append([VOCAB[c] for c in row['text']] if full else [1])
        return xs,targets,owners,labs
    tx,ty,_,_=split('train');vx,_,vo,vy=split('validation')
    # These weights address the threefold loss-normalization imbalance in the
    # pilot, rather than weakening runtime acceptance on observed owner data.
    command_ids=np.array([i for i,t in enumerate(ty) if t==[VOCAB[c] for c in WORDS[1]] or t==[VOCAB[c] for c in WORDS[2]]])
    net=Net();opt=torch.optim.AdamW(net.parameters(),lr=.0012,weight_decay=.004)
    ctc=nn.CTCLoss(blank=0,zero_infinity=False,reduction='none')
    best=None;history=[];t0=time.time()
    for epoch in range(args.epochs):
        net.train();losses=[]
        # Real recordings never enter this list; augmentations remain in their
        # original synthetic speaker split.
        ids=np.r_[rng.permutation(len(tx)),rng.choice(command_ids,len(tx)//3)]
        rng.shuffle(ids)
        for indices in np.array_split(ids,max(1,len(ids)//64)):
            xs=[]
            for i in indices:
                x=tx[i].astype(np.float32).copy()
                if rng.random()<.7:
                    eq=np.interp(np.arange(16),[0,5,10,15],rng.normal(0,2.5,4))
                    active=np.any(x,axis=1)
                    x[active]=np.clip(x[active]+eq+rng.normal(0,1,x[active].shape),0,64)
                xs.append(x)
            x,lens=batch(xs)
            target=torch.from_numpy(np.concatenate([ty[i] for i in indices])).long()
            tls=torch.tensor([len(ty[i]) for i in indices])
            z=net(x).log_softmax(2).transpose(0,1)
            loss=(ctc(z,target,lens,tls)/tls.sqrt()).mean()
            assert torch.isfinite(loss)
            opt.zero_grad();loss.backward();nn.utils.clip_grad_norm_(net.parameters(),5);opt.step()
            losses.append(float(loss.detach()))
        if epoch%10==9 or epoch==0:
            net.eval();decoded=infer(net,vx);options=[]
            for margin in [0,.25,.5,.75,1.,1.5,2.,3.]:
                m=metrics(vy,vo,decoded,margin)
                if m['false_accepts']<=8:
                    options.append(((m['correct']-3*m['wrong_direction'],m['correct'],-m['false_accepts']),margin,m))
            if options:
                rank,margin,m=max(options,key=lambda p:p[0]);record=dict(epoch=epoch,margin=margin,validation=m)
                history.append(record)
                if best is None or rank>best:
                    best=rank;torch.save(net.state_dict(),OUT/'candidate.pt')
                    (OUT/'selected.json').write_text(json.dumps(record,indent=2))
                print('epoch',epoch,'loss',round(np.mean(losses),4),m,'elapsed',round(time.time()-t0,1),flush=True)
    assert best is not None
    net.load_state_dict(torch.load(OUT/'candidate.pt',weights_only=True));net.eval()
    selected=json.loads((OUT/'selected.json').read_text());results={}
    for name in ['validation','test']:
        x,_,owner,lab=split(name);results[name]=metrics(lab,owner,infer(net,x),selected['margin'])
    wav=ROOT/'verification/user_20261021_170604.wav'
    a,sr=sf.read(wav,dtype='int16');assert sr==48000
    samples=candidates(mel_powers(decimate(np.r_[np.zeros(98304,dtype=np.int16),a,np.zeros(73728,dtype=np.int16)])))
    real=infer(net,[x for x,_,_,_ in samples])
    results['real_development']=[dict(start=s,end=e,prediction=c if gap>=selected['margin'] else 0,gap=gap,text=text)
                                for (_,_,s,e),(c,gap,text) in zip(samples,real)]
    report=dict(experimental_only=True,fpga_deployed=False,real_used_for_training=False,
                human_accuracy_verified=False,test_used_for_selection=False,
                test_already_consulted_by_previous_pilot=True,
                tokens=TOKENS,parameters=sum(p.numel() for p in net.parameters()),selected=selected,
                results=results,history=history,
                limitations=['Synthetic transcripts do not establish real speaker generalization.',
                             'Negative fragments use longest-candidate heuristic, not forced alignment.',
                             'Current 16-band 32ms frontend differs from mature 80-band speech models.',
                             'This float32 CPU model has no synthesized FPGA accelerator.'],
                sources={str(p):sha(p) for p in [Path(__file__),ROOT/'voice/tools/train_sequence_ctc.py',
                         source,MANIFEST,wav,OUT/'candidate.pt',OUT/'selected.json']})
    (OUT/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({k:v for k,v in report.items() if k not in ['sources','history','tokens']},ensure_ascii=True,indent=2),flush=True)

if __name__=='__main__':main()
