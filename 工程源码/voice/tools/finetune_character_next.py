"""Fine-tune the small character CTC model for NEXT while retaining full transcripts."""
import os
os.environ.setdefault('OPENBLAS_NUM_THREADS','1')
from pathlib import Path
import hashlib,json,time
import numpy as np
import torch
from torch import nn
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
import train_character_ctc as char
from train_sequence_ctc import batch

ROOT=char.ROOT
OUT=ROOT/'voice/experiments/character_ctc_next'
DATA=ROOT/'voice/experiments/sequence_ctc/dataset.npz'
TOKENS,VOCAB,ROWS=char.TOKENS,char.VOCAB,char.ROWS
WORDS={1:'下一张',2:'上一张'}
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()

def load_split(ds,name):
    lens=ds[name+'_lengths'];owners=ds[name+'_owners'];labels=ds[name+'_labels']
    xs=np.split(ds[name+'_x'],np.cumsum(lens)[:-1])
    rows=[r for r in ROWS if r['split']==name]
    original=np.split(ds[name+'_targets'],np.cumsum(ds[name+'_target_lengths'])[:-1])
    longest={}
    for i,o in enumerate(owners):
        if o not in longest or lens[i]>lens[longest[o]]:longest[o]=i
    targets=[]
    for i,o in enumerate(owners):
        row=rows[o//6]
        full=(len(original[i])==3 if row['label'] else longest[o]==i)
        targets.append([VOCAB[c] for c in row['text']] if full else [1])
    return xs,targets,owners,labels

def decoded(net,xs):
    out=[]
    with torch.no_grad():
        for i in range(0,len(xs),64):
            x,l=batch(xs[i:i+64]);z=net(x).numpy()
            out.extend([char.decode(a[:int(n)]) for a,n in zip(z,l)])
    return out

def measure(labels,owners,rows,margin):
    pred=np.zeros(len(labels),dtype=np.int8)
    for o,(c,gap,_) in zip(owners,rows):
        if c and gap>=margin and not pred[o]:pred[o]=c
    cm=np.zeros((3,3),dtype=int)
    for a,b in zip(labels,pred):cm[a,b]+=1
    return {'correct':int(cm[1,1]+cm[2,2]),'wrong_direction':int(cm[1,2]+cm[2,1]),
            'false_accepts':int(cm[0,1:].sum()),'confusion':cm.tolist(),
            'next_correct':int(cm[1,1]),'next_reject':int(cm[1,0]),'other_false_next':int(cm[0,1])}

def main():
    torch.set_num_threads(2);torch.manual_seed(20261026);rng=np.random.default_rng(20261026)
    OUT.mkdir(parents=True,exist_ok=True);ds=np.load(DATA)
    tx,ty,to,tl=load_split(ds,'train');vx,vy,vo,vl=load_split(ds,'validation')
    net=char.Net();net.load_state_dict(torch.load(ROOT/'voice/experiments/character_ctc/candidate.pt',weights_only=True))
    opt=torch.optim.AdamW(net.parameters(),lr=.00012,weight_decay=.001)
    ctc=nn.CTCLoss(blank=0,zero_infinity=True,reduction='none')
    ids=np.arange(len(tx));next_ids=np.flatnonzero(tl[to]==1);best=None;history=[];start=time.time()
    for epoch in range(40):
        net.train();rng.shuffle(ids);batches=np.array_split(np.r_[ids,rng.choice(next_ids,len(ids)//2)],max(1,len(ids)//48));losses=[]
        for ix in batches:
            xs=[];targets=[]
            for i in ix:
                x=tx[i].astype(np.float32).copy()
                rate=float(rng.uniform(.78,1.32));pos=np.arange(max(8,round(len(x)/rate)))*rate
                x=np.stack([np.interp(pos,np.arange(len(x)),x[:,j]) for j in range(16)],1)
                if rng.random()<.75:
                    active=np.any(x,axis=1);eq=np.interp(np.arange(16),[0,5,10,15],rng.normal(0,2.5,4))
                    x[active]=np.clip(x[active]+eq+rng.normal(0,1,x[active].shape),0,64)
                x=np.pad(x,((int(rng.integers(0,13)),int(rng.integers(0,13))),(0,0)))
                xs.append(x);targets.append(ty[i])
            x,l=batch(xs);target=torch.tensor(np.concatenate(targets),dtype=torch.long)
            lens=torch.tensor([len(t) for t in targets]);z=net(x);lp=z.log_softmax(2).transpose(0,1).contiguous()
            per=ctc(lp,target,l,lens)/lens.clamp(min=1).sqrt()
            sample_owner=np.array([to[i] for i in ix]);sample_labels=tl[sample_owner]
            weights=torch.tensor(np.where(sample_labels==1,2.0,1.0),dtype=torch.float32)
            loss=(per*weights).sum()/weights.sum()
            opt.zero_grad();loss.backward();nn.utils.clip_grad_norm_(net.parameters(),4);opt.step();losses.append(float(loss.detach()))
        if epoch%4==3:
            net.eval();d=decoded(net,vx);options=[]
            for margin in [0,.25,.5,.75,1,1.5,2,3,4,6]:
                m=measure(vl,vo,d,margin)
                if m['other_false_next']<=8:
                    rank=(m['next_correct']-5*m['other_false_next'],m['next_correct'],-m['other_false_next'])
                    options.append((rank,margin,m))
            if options:
                rank,margin,m=max(options,key=lambda a:a[0]);rec={'epoch':epoch,'margin':margin,'validation':m}
                history.append(rec)
                if best is None or rank>best:
                    best=rank;torch.save(net.state_dict(),OUT/'candidate.pt');(OUT/'selected.json').write_text(json.dumps(rec,ensure_ascii=False,indent=2),encoding='utf8')
            print('epoch',epoch,'loss',round(float(np.mean(losses)),4),'best',history[-1] if history else None,'elapsed',round(time.time()-start,1),flush=True)
    if best is None:raise RuntimeError('validation found no acceptable threshold')
    net.load_state_dict(torch.load(OUT/'candidate.pt',weights_only=True));net.eval();selected=json.loads((OUT/'selected.json').read_text())
    result={}
    for split in ['validation','test']:
        xs,_,owner,labels=load_split(ds,split);result[split]=measure(labels,owner,decoded(net,xs),selected['margin'])
    manifest=char.MANIFEST;inputs=[Path(__file__),Path(char.__file__),DATA,manifest,ROOT/'voice/experiments/character_ctc/candidate.pt']
    report={'experimental_only':True,'deployed':False,'real_used_for_training':False,'test_used_for_selection':False,
        'target_policy':'complete 下一张 transcript; strict transcript CTC, command-only output',
        'parameters':sum(p.numel() for p in net.parameters()),'selected':selected,'results':result,
        'checkpoint_sha256':sha(OUT/'candidate.pt'),'input_sha256':{str(p):sha(p) for p in inputs},
        'limitations':['Synthetic speakers only; not a human accuracy guarantee.','Previously inspected test split.','No FPGA quantization or timing yet.']}
    (OUT/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf8');print(json.dumps(report,ensure_ascii=False),flush=True)
if __name__=='__main__':main()
