"""Padding-safe CTC experiment. No RTL or deployed model is modified.

Valid samples alone contribute to batch statistics; invalid frames are masked
before and after every temporal layer. A 14-frame real-silence halo gives the
noncausal network the same context at a clip edge and in a longer silence.
"""
import os
os.environ.setdefault('OPENBLAS_NUM_THREADS','1')
import argparse, hashlib, json, time
from pathlib import Path
import numpy as np
import torch
from torch import nn
import train_acoustic_codes as base
from train_sequence_ctc import ROOT,batch

OUT=ROOT/'voice/experiments/acoustic_codes_v4'
TOKENS,VOCAB,TEXTS,ROWS=base.TOKENS,base.VOCAB,base.TEXTS,base.ROWS
HALO=14

class Net(nn.Module):
    def __init__(self):
        super().__init__()
        self.convs=nn.ModuleList([nn.Conv1d(16,48,5,padding=2),
                                nn.Conv1d(48,48,5,padding=4,dilation=2),
                                nn.Conv1d(48,48,5,padding=8,dilation=4)])
        self.norms=nn.ModuleList([nn.BatchNorm1d(48) for _ in range(3)])
        self.out=nn.Conv1d(48,len(TOKENS),1)
        self.aux=nn.Linear(48,len(TEXTS))

    def forward(self,x,lengths):
        width=x.shape[1]
        h=nn.functional.pad(x.transpose(1,2)-1,(HALO,HALO),value=-1)
        valid=torch.arange(h.shape[2],device=x.device)[None,:]<(lengths+2*HALO)[:,None]
        # x beyond the true end is real silence inside the halo, then absent.
        original=torch.arange(width,device=x.device)[None,:]<lengths[:,None]
        h[:,:,HALO:HALO+width]=torch.where(original[:,None,:],h[:,:,HALO:HALO+width],-1.)
        h=h*valid[:,None,:]
        for conv,norm in zip(self.convs,self.norms):
            a=conv(h).transpose(1,2)
            packed=norm(a[valid]).relu()
            h=torch.zeros_like(a).index_put((valid,),packed).transpose(1,2)
        h=h[:,:,HALO:HALO+width]
        z=self.out(h).transpose(1,2)
        pooled=(h*original[:,None,:]).sum(2)/lengths[:,None]
        return z,self.aux(pooled)

@torch.no_grad()
def infer(net,xs):
    out=[]
    for lo in range(0,len(xs),64):
        x,lens=batch(xs[lo:lo+64]);z,_=net(x,lens)
        out.extend(base.greedy(a[:int(n)]) for a,n in zip(z.numpy(),lens))
    return out

def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--epochs',type=int,default=100);args=ap.parse_args()
    torch.set_num_threads(4);torch.manual_seed(20261027);rng=np.random.default_rng(20261027)
    OUT.mkdir(parents=True,exist_ok=True)
    source=ROOT/'voice/experiments/acoustic_codes_v3/full_clips.npz'
    stream_path=ROOT/'voice/experiments/sequence_ctc/dataset.npz'
    sourcefiles=[Path(__file__),Path(base.__file__),ROOT/'voice/tools/train_sequence_ctc.py',
                 ROOT/'voice/tools/probe_vad_continuity.py',base.DATA/'data/manifest.json',source,stream_path]
    hashes={str(p):sha(p) for p in sourcefiles}
    (OUT/'training_source_snapshot.py').write_bytes(Path(__file__).read_bytes())
    (OUT/'input_hashes.json').write_text(json.dumps(hashes,indent=2),encoding='utf8')
    ds=np.load(source);stream=np.load(stream_path)
    tx=np.split(ds['train_x'],np.cumsum(ds['train_lengths'])[:-1]);tr=ds['train_rowids'];tl=ds['train_labels']
    ty=[[VOCAB[c] for c in ROWS[i]['text']] for i in tr]
    sx=np.split(stream['validation_x'],np.cumsum(stream['validation_lengths'])[:-1])
    commands=np.flatnonzero(tl!=0)
    net=Net();opt=torch.optim.AdamW(net.parameters(),lr=.001,weight_decay=.001)
    ctc=nn.CTCLoss(blank=0,zero_infinity=False,reduction='none')
    best=None;history=[];t0=time.time()
    for epoch in range(args.epochs):
        net.train();losses=[]
        ids=np.r_[rng.permutation(len(tx)),rng.choice(commands,len(tx)//3)];rng.shuffle(ids)
        for ix in np.array_split(ids,max(1,len(ids)//64)):
            xs=[];targets=[];classes=[]
            for i in ix:
                x=tx[i].astype(np.float32).copy()
                if rng.random()<.7:
                    eq=np.interp(np.arange(16),[0,5,10,15],rng.normal(0,2,4))
                    active=np.any(x,axis=1);x[active]=np.clip(x[active]+eq+rng.normal(0,.7,x[active].shape),0,64)
                x=np.pad(x,((int(rng.integers(0,13)),int(rng.integers(0,13))),(0,0)))
                xs.append(x);targets.append(ty[i]);classes.append(TEXTS.index(ROWS[tr[i]]['text']))
            for _ in range(8):
                n=int(rng.integers(15,100));quiet=np.zeros((n,16),dtype=np.float32)
                if rng.random()<.5:quiet=np.clip(rng.normal(0,.7,(n,16)),0,64).astype(np.float32)
                xs.append(quiet);targets.append([]);classes.append(-100)
            x,lens=batch(xs);z,aux=net(x,lens)
            target=torch.tensor(np.concatenate(targets)).long();tls=torch.tensor([len(t) for t in targets])
            loss=(ctc(z.log_softmax(2).transpose(0,1),target,lens,tls)/tls.clamp(min=1)).mean()
            loss=loss+.3*nn.functional.cross_entropy(aux,torch.tensor(classes))
            assert torch.isfinite(loss)
            opt.zero_grad();loss.backward();nn.utils.clip_grad_norm_(net.parameters(),5);opt.step()
            losses.append(float(loss.detach()))
        if epoch%5==4 or epoch==0:
            net.eval();decoded=infer(net,sx);options=[]
            for margin in [0,.25,.5,1,1.5,2,3,4,8,16,1e9]:
                m=base.metrics(stream['validation_labels'],stream['validation_owners'],decoded,margin)
                if m['false_accepts']<=8:options.append(((m['correct']-3*m['wrong_direction'],m['correct'],-m['false_accepts']),margin,m))
            rank,margin,m=max(options,key=lambda t:t[0])
            record=dict(epoch=epoch,loss=float(np.mean(losses)),margin=margin,validation=m);history.append(record)
            if best is None or rank>best:
                best=rank;torch.save(net.state_dict(),OUT/'candidate.pt');(OUT/'selected.json').write_text(json.dumps(record,indent=2))
            print('epoch',epoch,'loss',round(record['loss'],4),m,'seconds',round(time.time()-t0,1),flush=True)
            (OUT/'history.json').write_text(json.dumps(history,indent=2))
    selected=json.loads((OUT/'selected.json').read_text());net.load_state_dict(torch.load(OUT/'candidate.pt',weights_only=True));net.eval()
    report=dict(experimental_only=True,fpga_deployed=False,real_used_for_training=False,test_previously_inspected=True,
                selected=selected,results={},source_unchanged=all(sha(p)==v for p,v in hashes.items()),input_hashes=hashes)
    for name in ['validation','test']:
        xs=np.split(stream[name+'_x'],np.cumsum(stream[name+'_lengths'])[:-1])
        report['results'][name]=base.metrics(stream[name+'_labels'],stream[name+'_owners'],infer(net,xs),selected['margin'])
    report['checkpoint_sha256']=sha(OUT/'candidate.pt')
    (OUT/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf8')
    print(json.dumps(report,ensure_ascii=True,indent=2),flush=True)

if __name__=='__main__':main()
