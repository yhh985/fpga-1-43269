"""V5: explicit competing transcript training, frozen batch statistics.

Fine-tune V4 using synthetic train clips only. Exact CTC probability trains
the 12 known phrases plus empty to compete; commands must separate up/down.
Real recordings never train or select the checkpoint or thresholds.
"""
import os
os.environ.setdefault('OPENBLAS_NUM_THREADS','1')
import argparse,hashlib,json,time
from pathlib import Path
import numpy as np
import torch
from torch import nn
from train_masked_acoustic_codes import Net,ROOT,batch,base,TEXTS,VOCAB,TOKENS

OUT=ROOT/'voice/experiments/acoustic_codes_v5'
PHRASES=TEXTS+['']
CODES=[[VOCAB[c] for c in text] for text in PHRASES]

def transcript_scores(z,lengths):
    n=len(z);k=len(CODES)
    lp=z.log_softmax(2).repeat_interleave(k,dim=0).transpose(0,1).contiguous()
    targets=torch.tensor([t for _ in range(n) for code in CODES for t in code],dtype=torch.long)
    tls=torch.tensor([len(code) for _ in range(n) for code in CODES],dtype=torch.long)
    return -nn.functional.ctc_loss(lp,targets,lengths.repeat_interleave(k),tls,
                                   blank=0,reduction='none',zero_infinity=False).reshape(n,k)

@torch.no_grad()
def scores(net,xs):
    output=[]
    for lo in range(0,len(xs),32):
        x,lens=batch(xs[lo:lo+32]);z,_=net(x,lens);output.append(transcript_scores(z,lens).numpy())
    return np.concatenate(output)

def decisions(s,lens,margin,floor):
    out=[]
    for row,n in zip(s,lens):
        order=np.argsort(row);i,j=order[-1],order[-2];text=PHRASES[i]
        c=next((c for c,w in base.WORDS.items() if text==w),0)
        gap=float(row[i]-row[j])
        if gap<margin or row[i]/n<floor:c=0
        out.append((c,gap,text))
    return out

def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--epochs',type=int,default=60);args=ap.parse_args()
    torch.set_num_threads(4);torch.manual_seed(20261028);rng=np.random.default_rng(20261028)
    OUT.mkdir(parents=True,exist_ok=True)
    source=ROOT/'voice/experiments/acoustic_codes_v3/full_clips.npz'
    streamp=ROOT/'voice/experiments/sequence_ctc/dataset.npz'
    initial=ROOT/'voice/experiments/acoustic_codes_v4/candidate.pt'
    paths=[Path(__file__),ROOT/'voice/tools/train_masked_acoustic_codes.py',Path(base.__file__),
           source,streamp,initial,base.DATA/'data/manifest.json']
    hashes={str(p):sha(p) for p in paths};(OUT/'training_source_snapshot.py').write_bytes(Path(__file__).read_bytes())
    (OUT/'input_hashes.json').write_text(json.dumps(hashes,indent=2))
    ds=np.load(source);stream=np.load(streamp)
    tx=np.split(ds['train_x'],np.cumsum(ds['train_lengths'])[:-1]);tr=ds['train_rowids'];tl=ds['train_labels']
    classes=np.array([TEXTS.index(base.ROWS[i]['text']) for i in tr]);commands=np.flatnonzero(tl!=0)
    sx=np.split(stream['validation_x'],np.cumsum(stream['validation_lengths'])[:-1]);vl=stream['validation_lengths']
    net=Net();net.load_state_dict(torch.load(initial,weights_only=True));net.eval()
    opt=torch.optim.AdamW(net.parameters(),lr=.00015,weight_decay=.001)
    best=None;history=[];t0=time.time()
    for epoch in range(-1,args.epochs):
        losses=[]
        if epoch>=0:
            # Fixed running normalization removes train/eval statistics drift.
            net.train()
            for norm in net.norms:norm.eval()
            ids=np.r_[rng.permutation(len(tx)),rng.choice(commands,len(tx)//3)];rng.shuffle(ids)
            for ix in np.array_split(ids,max(1,len(ids)//48)):
                xs=[];ys=[]
                for i in ix:
                    x=tx[i].astype(np.float32).copy()
                    # Continuous tempo range includes the earlier failing 1.3x.
                    rate=float(rng.uniform(.75,1.35));pos=np.arange(max(8,round(len(x)/rate)))*rate
                    x=np.stack([np.interp(pos,np.arange(len(x)),x[:,j]) for j in range(16)],1)
                    if rng.random()<.8:
                        active=np.any(x,axis=1);eq=np.interp(np.arange(16),[0,5,10,15],rng.normal(0,2.5,4))
                        x[active]=np.clip(x[active]+eq+rng.normal(0,1.,x[active].shape),0,64)
                    x=np.pad(x,((int(rng.integers(0,13)),int(rng.integers(0,13))),(0,0)))
                    xs.append(x);ys.append(classes[i])
                for _ in range(6):
                    n=int(rng.integers(15,100));x=np.zeros((n,16),dtype=np.float32)
                    if rng.random()<.5:x=np.clip(rng.normal(0,.7,(n,16)),0,64)
                    xs.append(x);ys.append(len(TEXTS))
                x,lens=batch(xs);z,_=net(x,lens);s=transcript_scores(z,lens);y=torch.tensor(ys)
                chosen=s[torch.arange(len(s)),y]
                competing=s.masked_fill(nn.functional.one_hot(y,len(PHRASES)).bool(),-1e9).max(1).values
                # Absolute acoustic fit + explicit relative separation; blank competes too.
                targetlen=torch.tensor([max(1,len(CODES[i])) for i in ys])
                loss=(-chosen/targetlen).mean()+.3*nn.functional.softplus(3+competing-chosen).mean()
                assert torch.isfinite(loss)
                opt.zero_grad();loss.backward();nn.utils.clip_grad_norm_(net.parameters(),3);opt.step()
                losses.append(float(loss.detach()))
        if epoch==-1 or epoch%5==4:
            net.eval();s=scores(net,sx);options=[]
            for margin in [0,.5,1,2,3,4,6,8,12,24,1e9]:
                for floor in [-.05,-.1,-.2,-.5,-1,-2,-4]:
                    d=decisions(s,vl,margin,floor)
                    m=base.metrics(stream['validation_labels'],stream['validation_owners'],d,0)
                    if m['false_accepts']<=8:options.append(((m['correct']-5*m['wrong_direction'],m['correct'],-m['false_accepts']),margin,floor,m))
            rank,margin,floor,m=max(options,key=lambda t:t[0])
            record=dict(epoch=epoch,loss=float(np.mean(losses)) if losses else None,margin=margin,floor=floor,validation=m);history.append(record)
            if best is None or rank>best:
                best=rank;torch.save(net.state_dict(),OUT/'candidate.pt');(OUT/'selected.json').write_text(json.dumps(record,indent=2))
            (OUT/'history.json').write_text(json.dumps(history,indent=2))
            print('epoch',epoch,m,'seconds',round(time.time()-t0,1),flush=True)
    selected=json.loads((OUT/'selected.json').read_text());net.load_state_dict(torch.load(OUT/'candidate.pt',weights_only=True));net.eval()
    report=dict(experimental_only=True,fpga_deployed=False,real_used_for_training=False,real_used_for_selection=False,
                test_previously_inspected=True,selected=selected,results={})
    for split in ['validation','test']:
        lens=stream[split+'_lengths'];xs=np.split(stream[split+'_x'],np.cumsum(lens)[:-1])
        d=decisions(scores(net,xs),lens,selected['margin'],selected['floor'])
        report['results'][split]=base.metrics(stream[split+'_labels'],stream[split+'_owners'],d,0)
    report.update(input_hashes=hashes,source_unchanged=all(sha(p)==v for p,v in hashes.items()),checkpoint_sha256=sha(OUT/'candidate.pt'))
    (OUT/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2),flush=True)

if __name__=='__main__':main()
