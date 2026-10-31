"""Export V5 BN-folded INT8 CNN and evaluate quantized temporal consensus."""
import json,math,hashlib
from pathlib import Path
import numpy as np
import torch
from torch import nn
from train_directional_ctc import ROOT,Net,base,PHRASES,CODES,decisions
from train_masked_acoustic_codes import HALO
from evaluate_tempo_consensus import score_views
OUT=ROOT/'voice/model_ctc'

def write_hex(name,a,bits):
    (OUT/name).write_text(''.join(f'{int(v)&((1<<bits)-1):0{bits//4}x}\n' for v in np.asarray(a).ravel()))

class QuantNet(nn.Module):
    def __init__(self,params):
        super().__init__();self.params=params
    def forward(self,x,lengths):
        width=x.shape[1];h=nn.functional.pad(torch.round(x.transpose(1,2)*32)-32,(HALO,HALO),value=-32)
        valid=torch.arange(h.shape[2])[None,:]<(lengths+2*HALO)[:,None]
        original=torch.arange(width)[None,:]<lengths[:,None]
        h[:,:,HALO:HALO+width]=torch.where(original[:,None,:],h[:,:,HALO:HALO+width],-32.)
        h=h*valid[:,None,:]
        for i,(w,b,s) in enumerate(self.params):
            if i==3:h=h[:,:,HALO:HALO+width]
            y=nn.functional.conv1d(h,torch.tensor(w,dtype=torch.float32),torch.tensor(b,dtype=torch.float32),padding=[2,4,8,0][i],dilation=[1,2,4,1][i])
            y=torch.floor(y/torch.tensor(2.**s,dtype=torch.float32)[None,:,None])
            if i<3:h=y.clamp(0,127)*valid[:,None,:]
            else:return y.transpose(1,2)/64,None

def load():
    d=np.load(OUT/'params.npz');return QuantNet([(d[f'w{i}'],d[f'b{i}'],d[f's{i}']) for i in range(4)])

def main():
    torch.set_num_threads(2);OUT.mkdir(exist_ok=True);net=Net();net.load_state_dict(torch.load(ROOT/'voice/experiments/acoustic_codes_v5/candidate.pt',weights_only=True));net.eval()
    ps=[];allw=[];allb=[];alls=[];scales=[32,8,16,4,64];offsets=[]
    for i in range(4):
        conv=net.convs[i] if i<3 else net.out
        w=conv.weight.detach().numpy().copy();b=conv.bias.detach().numpy().copy()
        if i<3:
            norm=net.norms[i];factor=(norm.weight/torch.sqrt(norm.running_var+norm.eps)).detach().numpy()
            w*=factor[:,None,None];b=(b-norm.running_mean.detach().numpy())*factor+norm.bias.detach().numpy()
        frac=np.floor(np.log2(127/np.maximum(np.max(np.abs(w),axis=(1,2)),1e-9))).astype(int)
        qw=np.rint(w*2.**frac[:,None,None]).clip(-127,127).astype(np.int8)
        qb=np.rint(b*scales[i]*2.**frac).astype(np.int32)
        shift=frac+int(math.log2(scales[i]/scales[i+1]))
        assert shift.min()>=0
        ps.append((qw,qb,shift));offsets.append(len(allw));allw.extend(qw.ravel());allb.extend(qb);alls.extend(shift)
    np.savez(OUT/'params.npz',**{k:v for i,p in enumerate(ps) for k,v in zip([f'w{i}',f'b{i}',f's{i}'],p)})
    write_hex('weights.mem',allw,8);write_hex('bias.mem',allb,32);write_hex('shift.mem',alls,8)
    write_hex('logadd.mem',np.rint(64*np.log1p(np.exp(-np.arange(1024)/64))),8)
    write_hex('exp.mem',np.rint(65536*np.exp(-np.arange(1024)/64)),32)
    # ln mantissa in Q6 after leading-bit normalization to [1,2).
    write_hex('ln.mem',np.rint(64*np.log(1+np.arange(256)/256)),8)
    codes=[];lengths=[];commands=[]
    for text,code in zip(PHRASES,CODES):
        seq=[0]
        for c in code:seq.extend([c,0])
        assert len(seq)<=17
        codes.extend(seq+[0]*(17-len(seq)));lengths.append(len(seq));commands.append(next((k for k,v in base.WORDS.items() if v==text),0))
    write_hex('codes.mem',codes,8);write_hex('lengths.mem',lengths,8);write_hex('commands.mem',commands,8)
    quant=QuantNet(ps);ds=np.load(ROOT/'voice/experiments/sequence_ctc/dataset.npz')
    def get(split):
        lens=ds[split+'_lengths'];return np.split(ds[split+'_x'],np.cumsum(lens)[:-1]),lens,ds[split+'_owners'],ds[split+'_labels']
    xs,lens,o,y=get('validation');s=score_views(quant,xs);options=[]
    for margin in [2,3,4,6,8,12,24,1e9]:
        for floor in [-.05,-.1,-.2,-.5,-1,-2,-4]:
            m=base.metrics(y,o,decisions(s,lens,margin,floor),0)
            if m['false_accepts']<=8:options.append(((m['correct']-5*m['wrong_direction'],m['correct'],-m['false_accepts']),margin,floor,m))
    _,margin,floor,m=max(options,key=lambda t:t[0]);xs,lens,o,y=get('test');s=score_views(quant,xs)
    cfg=dict(weights_offsets=offsets,neurons=[48,48,48,39],scales=scales,margin=margin,floor=floor,validation=m,test=base.metrics(y,o,decisions(s,lens,margin,floor),0),checkpoint_sha256=hashlib.sha256((ROOT/'voice/experiments/acoustic_codes_v5/candidate.pt').read_bytes()).hexdigest())
    (OUT/'config.json').write_text(json.dumps(cfg,indent=2));print(json.dumps(cfg,indent=2))

if __name__=='__main__':main()
