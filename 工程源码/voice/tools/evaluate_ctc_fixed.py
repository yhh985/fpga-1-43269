"""Bit-accurate Q6 CTC decoder and rational interpolation reference for RTL."""
import json
import numpy as np
import torch
from export_ctc_fpga import ROOT,OUT,load
from train_masked_acoustic_codes import batch
from train_directional_ctc import PHRASES,CODES,base
NEG=-1000000
LUT=np.rint(64*np.log1p(np.exp(-np.arange(1024)/64))).astype(np.int64)

def add(a,b):
    m=np.maximum(a,b);d=np.abs(a-b)
    return np.where(m<=NEG//2,NEG,m+np.where(d>1023,0,LUT[np.minimum(d,1023)]))

def view(x,p):
    num,den=[(4,5),(1,1),(5,4)][p]
    n=(len(x)*den+num//2)//num
    phase=np.arange(n)*num;index=np.minimum(phase//den,len(x)-1);frac=phase%den
    return ((x[index].astype(int)*(den-frac[:,None])+x[np.minimum(index+1,len(x)-1)]*frac[:,None]+den//2)//den).astype(np.int8)

@torch.no_grad()
def score(net,xs):
    result=[]
    for lo in range(0,len(xs),32):
        chunk=xs[lo:lo+32];total=np.zeros((len(chunk),13),dtype=np.int64)
        for p in range(3):
            variants=[view(x,p) for x in chunk];x,lens=batch(variants);z,_=net(x,lens);z=torch.round(z*64).numpy().astype(np.int64)
            dp=np.full((len(chunk),13,17),NEG,dtype=np.int64);codes=np.zeros((13,17),int);sizes=[]
            for k,code in enumerate(CODES):
                seq=[0]
                for c in code:seq.extend([c,0])
                sizes.append(len(seq));codes[k,:len(seq)]=seq
            valid=np.arange(17)[None,:]<np.array(sizes)[:,None]
            skip=(np.arange(17)[None,:]>=2)&(codes!=0)&(codes!=np.roll(codes,2,axis=1))
            for t in range(z.shape[1]):
                a=z[:,t];norm=a[:,0]
                for c in range(1,39):norm=add(norm,a[:,c])
                lp=a-norm[:,None];emit=lp[:,codes]
                if t==0:
                    new=np.full_like(dp,NEG);new[:,:,0]=emit[:,:,0]
                    new[:,:,1]=np.where(np.array(sizes)[None,:]>1,emit[:,:,1],NEG)
                else:
                    one=np.pad(dp[:,:,:-1],((0,0),(0,0),(1,0)),constant_values=NEG)
                    two=np.pad(dp[:,:,:-2],((0,0),(0,0),(2,0)),constant_values=NEG)
                    merged=add(add(dp,one),np.where(skip[None,:,:],two,NEG))
                    new=np.where(merged<=NEG//2,NEG,merged+emit)
                new=np.where(valid[None,:,:],new,NEG)
                dp=np.where((t<lens.numpy())[:,None,None],new,dp)
            for k,size in enumerate(sizes):
                s=add(dp[:,k,size-1],dp[:,k,size-2] if size>1 else NEG)
                total[:,k]+=np.trunc(s*np.array([len(x) for x in chunk])/lens.numpy()).astype(np.int64)
        result.append(total)
    return np.concatenate(result)

def decode(scores,lens,margin=0,floor=1024):
    out=[]
    for s,n in zip(scores,lens):
        next_index=PHRASES.index(base.WORDS[1]);blank_index=len(PHRASES)-1
        gap=int(s[next_index]-s[blank_index])
        c=1 if gap>=margin and s[next_index]*10>=-int(n)*floor else 0
        out.append((c,gap,base.WORDS[1] if c else '<reject>'))
    return out

def main():
    torch.set_num_threads(2);net=load();ds=np.load(ROOT/'voice/experiments/sequence_ctc/dataset.npz');report={}
    for split in ['validation','test']:
        lens=ds[split+'_lengths'];xs=np.split(ds[split+'_x'],np.cumsum(lens)[:-1]);s=score(net,xs)
        labels=ds[split+'_labels'].copy();labels[labels==2]=0
        report[split]=base.metrics(labels,ds[split+'_owners'],decode(s,lens),0)
        np.save(OUT/f'{split}_q6_scores.npy',s);print(split,report[split],flush=True)
    (OUT/'fixed_report.json').write_text(json.dumps(dict(next_only_binary=True,margin_q6_sum=0,floor_q6_sum_times10=1024,results=report),indent=2))

if __name__=='__main__':main()
