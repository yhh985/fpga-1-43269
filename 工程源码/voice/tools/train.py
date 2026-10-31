"""Train a small MLP, export signed integer ROMs and reproducible evidence."""
import argparse, copy, hashlib, json, random
from pathlib import Path
import numpy as np
import soundfile as sf
import torch
from kws_common import *

ROOT=Path(__file__).resolve().parents[1]

class TemporalConv(torch.nn.Module):
    """Shared temporal kernels compiled to a sparse 768x48 matrix for existing RTL.

    Sixteen kernels, 24 frames each, stride twelve: 16 channels x three positions.
    Training uses 6144 kernel weights rather than 36864 independent dense weights.
    The exported matrix is mathematically identical; board MAC scheduling is unchanged.
    """
    def __init__(self,channels=16,kernel=24,stride=12):
        super().__init__()
        self.positions=(FRAMES-kernel)//stride+1;self.stride=stride
        assert channels*self.positions==HIDDEN
        self.weight=torch.nn.Parameter(torch.empty(channels,16,kernel))
        self.bias=torch.nn.Parameter(torch.zeros(channels))
        torch.nn.init.kaiming_uniform_(self.weight,a=5**.5)
    def forward(self,x):
        return torch.nn.functional.conv1d(x.reshape(-1,48,16).transpose(1,2),
                                          self.weight,self.bias,stride=self.stride).flatten(1)
    def dense(self):
        w=self.weight.detach().numpy();b=self.bias.detach().numpy()
        expanded=np.zeros((48,768),dtype=np.float32)
        for ch in range(len(w)):
            for t in range(self.positions):
                expanded[ch*self.positions+t,t*self.stride*16:(t*self.stride+w.shape[2])*16]=w[ch].T.ravel()
        return expanded,np.repeat(b,self.positions)

def window(f, offset):
    a=np.zeros((FRAMES,BANDS),dtype=np.int8)
    lo=max(0,offset); hi=min(len(f),offset+FRAMES)
    if hi>lo:a[lo-offset:hi-offset]=f[lo:hi]
    return a.reshape(-1)

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--epochs',type=int,default=320)
    ap.add_argument('--architecture',choices=['dense','conv'],default='dense')
    ap.add_argument('--output-dir',type=Path,default=ROOT/'model')
    ap.add_argument('--report',type=Path,default=ROOT/'verification/training.json')
    ap.add_argument('--checkpoint',type=Path)
    ap.add_argument('--production-windows',action='store_true',help='Adaptive VAD and isolated three-pass windows, exactly as deployed')
    args=ap.parse_args()
    torch.set_num_threads(4);torch.manual_seed(20261018);random.seed(20261018)
    rng=np.random.default_rng(20261018)
    rows=json.loads((ROOT/'data/manifest.json').read_text(encoding='utf8'))
    samples=[]
    for ri,row in enumerate(rows):
        cache=ROOT/'data'/(Path(row['path']).stem+'_'+FEATURE_VERSION+('_adaptive_isolated' if args.production_windows else '')+'.npz')
        if cache.exists():f=np.load(cache)['f']
        else:
            a,sr=sf.read(ROOT/row['path'])
            if a.ndim==2:a=a.mean(axis=1)
            pcm=pcm48(a,sr)
            if args.production_windows:pcm=np.concatenate([np.zeros(49152,dtype=np.int16),pcm,np.zeros(73728,dtype=np.int16)])
            f=features(pcm,adaptive_vad=args.production_windows);np.savez(cache,f=f)
        samples.append((row,f))
    # All augmentations of a speaker remain in that speaker's split. Validation
    # also includes fixed augmented views, used only for selection/calibration.
    def dataset(split,aug):
        xx=[];yy=[]
        for row,original in samples:
            if row['split']!=split:continue
            f=np.concatenate([np.zeros((32,16),dtype=np.int8),original,np.zeros((12,16),dtype=np.int8)])
            for ai in range(aug):
                g=original
                if split!='test' and ai:
                    t=np.linspace(0,len(g)-1,max(2,int(len(g)*rng.uniform(.78,1.25))))
                    g=np.stack([np.interp(t,np.arange(len(g)),g[:,j]) for j in range(BANDS)],axis=1)
                    # Smooth microphone EQ and feature-domain noise; preserve quiet gating.
                    active=np.any(g,axis=1)
                    eq=np.interp(np.arange(BANDS),[0,5,10,15],rng.normal(0,2,4))
                    g=np.clip(np.rint(g+eq+rng.normal(0,1.2,g.shape)),0,64).astype(np.int8)
                    g[~active]=0
                padded=np.concatenate([np.zeros((32,16),dtype=np.int8),g,np.zeros((12,16),dtype=np.int8)])
                for end in endpoints(padded,robust=args.production_windows):
                    if args.production_windows:
                        for z in endpoint_windows(padded,end):xx.append(z);yy.append(row['label'])
                        continue
                    offset=end-FRAMES+(int(rng.integers(-2,3)) if split=='train' and ai else 0)
                    xx.append(window(padded,offset));yy.append(row['label'])
            if row['label']==0 and split=='train':
                # Speech fragments and complete sentences both train rejection.
                for _ in range(3):
                    offset=int(rng.integers(0,max(1,len(f)-FRAMES+1)))
                    xx.append(window(f,offset));yy.append(0)
        # Explicit silence, white/colored noise, impulse and sinusoidal negatives.
        for i in range(300 if split=='train' else 60):
            noise=rng.normal(0,rng.uniform(0,1400),48000*2)
            if i%4==0:noise[:]=0
            if i%4==1:noise=12000*np.sin(np.arange(len(noise))*2*np.pi*rng.uniform(100,3500)/48000)
            if i%4==2:noise[30000:30010]=20000
            f=features(np.clip(noise,-32768,32767).astype(np.int16),adaptive_vad=args.production_windows)
            xx.append(window(f,0));yy.append(0)
        return np.array(xx,dtype=np.int64),np.array(yy)
    x,y=dataset('train',16);vx,vy=dataset('validation',5)
    first=TemporalConv() if args.architecture=='conv' else torch.nn.Linear(INPUTS,HIDDEN)
    net=torch.nn.Sequential(first,torch.nn.ReLU(),torch.nn.Linear(HIDDEN,3))
    opt=torch.optim.AdamW(net.parameters(),lr=.0006,weight_decay=.003)
    xt=torch.tensor(x/32,dtype=torch.float32);yt=torch.tensor(y)
    weights=torch.tensor([.65,1.,1.])
    best_score=-1;best_state=None
    if args.checkpoint:best_state=torch.load(args.checkpoint,weights_only=True)
    for epoch in range(args.epochs):
        perm=torch.randperm(len(x))
        for batch in perm.split(256):
            opt.zero_grad();out=net(xt[batch]);loss=torch.nn.functional.cross_entropy(out,yt[batch],weight=weights,label_smoothing=.025)
            loss.backward();opt.step()
        with torch.no_grad():
            vl=net(torch.tensor(vx/32,dtype=torch.float32)).numpy();vp=vl.argmax(1)
            vg=np.sort(vl,axis=1)[:,-1]-np.sort(vl,axis=1)[:,-2]
            negatives=np.sort(vg[(vy==0)&(vp!=0)])[::-1]
            budget=max(1,int((vy==0).sum()*.005))
            threshold=np.nextafter(negatives[budget],np.inf) if len(negatives)>budget else 0
            accepted=np.where(vg>=threshold,vp,0)
            score=float((accepted[vy!=0]==vy[vy!=0]).mean())
        if score>best_score:best_score=score;best_state=copy.deepcopy(net.state_dict())
        if epoch%20==0:print(epoch,'loss',float(loss.detach()),'val',score,flush=True)
    net.load_state_dict(best_state)
    w1f,b1f,w2f,b2f=[p.detach().numpy() for p in net.parameters()]
    if args.architecture=='conv':w1f,b1f=first.dense()
    with torch.no_grad():reference_hidden=net[:2](torch.tensor(vx/32,dtype=torch.float32)).numpy()
    expanded_hidden=np.maximum((vx/32)@w1f.T+b1f,0)
    expansion_error=float(np.max(np.abs(expanded_hidden-reference_hidden)))
    assert np.allclose(expanded_hidden,reference_hidden,rtol=1e-4,atol=1e-5)
    s1=2**int(np.floor(np.log2(127/np.abs(w1f).max())))
    s2=2**int(np.floor(np.log2(127/np.abs(w2f).max())))
    with torch.no_grad():h=net[:2](xt).numpy()
    shift=max(0,int(np.ceil(np.log2(s1*32*max(1,float(np.percentile(h,99.95)))/110))))
    hs=s1*32/(2**shift)
    w1=np.rint(w1f*s1).astype(np.int64);b1=np.rint(b1f*s1*32).astype(np.int64)
    w2=np.rint(w2f*s2).astype(np.int64);b2=np.rint(b2f*s2*hs).astype(np.int64)
    vo=integer_infer(vx,w1,b1,w2,b2,shift)
    # Calibrate the quantized gap on unique validation voices, not the test split.
    vp=vo.argmax(1);gap=np.sort(vo,axis=1)[:,-1]-np.sort(vo,axis=1)[:,-2]
    selection=[]
    for threshold in np.unique(np.r_[1,gap+1]):
        pred=np.where(gap>=threshold,vp,0)
        fa=int(((vy==0)&(pred!=0)).sum())
        commands=float((pred[vy!=0]==vy[vy!=0]).mean())
        if fa<=max(1,int((vy==0).sum()*.005)):selection.append((commands,-fa,-int(threshold)))
    margin=-max(selection)[2]
    def evaluate(a,b):
        out=integer_infer(a,w1,b1,w2,b2,shift);pred=out.argmax(1)
        gap=np.sort(out,axis=1)[:,-1]-np.sort(out,axis=1)[:,-2]
        pred=np.where(gap>=margin,pred,0)
        cm=np.zeros((3,3),dtype=int)
        for truth,p in zip(b,pred):cm[truth,p]+=1
        return dict(count=len(b),accuracy=float((pred==b).mean()),confusion=cm.tolist(),
                    false_accepts=int(((b==0)&(pred!=0)).sum()),negatives=int((b==0).sum()))
    outdir=args.output_dir;outdir.mkdir(exist_ok=True,parents=True)
    def write(name,a,bits):
        (outdir/name).write_text('\n'.join(f'{int(v)&((1<<bits)-1):0{bits//4}x}' for v in a.flatten())+'\n')
    write('weights.mem',np.concatenate([w1.ravel(),w2.ravel()]),8)
    write('bias.mem',np.concatenate([b1,b2]),32)
    cfg=dict(inputs=INPUTS,frames=FRAMES,bands=BANDS,hidden=HIDDEN,shift=shift,margin=margin,
             coefficients=COEFF.tolist(),feature_version=FEATURE_VERSION,architecture=args.architecture,
             mel_weights_q8=MEL_WEIGHTS.tolist(),
             temporal_conv=dict(channels=len(first.weight),kernel=first.weight.shape[2],stride=first.stride) if args.architecture=='conv' else None,
             classes=['reject','next','previous'],synthetic_only=True)
    (outdir/'config.json').write_text(json.dumps(cfg,indent=2))
    (outdir/'kws_config.vh').write_text(f'// Generated by voice/tools/train.py\n`define KWS_SHIFT {shift}\n`define KWS_MARGIN {margin}\n')
    torch.save(net.state_dict(),outdir/'bootstrap.pt')
    tx,ty=dataset('test',1)
    report=dict(seed=20261018,synthetic_only=True,real_speaker_test='NOT RUN',
        training_parameters=sum(p.numel() for p in net.parameters()),
        dense_expansion_max_error=expansion_error,
        selection=dict(split='validation',criterion='command accuracy at <=0.5% validation false accepts',
                       validation_augmented=True,test_used_for_selection=False),
        labels=['reject','next','previous'],train=evaluate(x,y),validation=evaluate(vx,vy),test=evaluate(tx,ty),
        speakers={s:sorted({r['speaker'] for r in rows if r['split']==s}) for s in ['train','validation','test']},
        production_windows=args.production_windows,
        model=cfg,weight_sha256=hashlib.sha256((outdir/'weights.mem').read_bytes()).hexdigest())
    args.report.write_text(json.dumps(report,indent=2))
    # Hundreds of independent integer feature-to-logit golden vectors.
    vectors=tx[:200];logits=integer_infer(vectors,w1,b1,w2,b2,shift)
    write('test_inputs.mem',vectors,8);write('test_logits.mem',logits,32)
    print(json.dumps(report,indent=2),flush=True)

if __name__=='__main__':main()
