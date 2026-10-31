"""Candidate training; never overwrites the deployed model or uses test for selection."""
import os
os.environ.setdefault('OPENBLAS_NUM_THREADS','1')
os.environ.setdefault('OMP_NUM_THREADS','4')
from pathlib import Path
import json,hashlib,argparse,copy,time
from concurrent.futures import ThreadPoolExecutor
import numpy as np
import soundfile as sf
import torch
from train import TemporalConv
from kws_common import features,pcm48,integer_infer
from robust_common import utterances,normalized_windows,decisions

ROOT=Path(__file__).resolve().parents[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--epochs',type=int,default=100)
    ap.add_argument('--data-root',type=Path,default=Path('E:/anlo_project/liantiao/voice'))
    ap.add_argument('--out',type=Path,default=ROOT/'experiments/robust_normalized')
    ap.add_argument('--architecture',choices=['dense','conv'],default='conv')
    args=ap.parse_args();out=args.out;out.mkdir(parents=True,exist_ok=True)
    cache=out/'cache';cache.mkdir(exist_ok=True)
    rows=json.loads((args.data_root/'data/manifest.json').read_text(encoding='utf8'))
    refsha=sha(ROOT/'tools/kws_common.py')
    def prepare(item):
        ri,row=item;path=args.data_root/row['path']
        key=hashlib.sha256((sha(path)+refsha+'robust_noise_v1').encode()).hexdigest()
        cp=cache/(key+'.npz')
        if not cp.exists():
            a,sr=sf.read(path)
            if a.ndim==2:a=a.mean(1)
            pcm=np.concatenate([np.zeros(49152,dtype=np.int16),pcm48(a,sr),np.zeros(73728,dtype=np.int16)])
            rng=np.random.default_rng(202610230+ri);t=np.arange(len(pcm))/48000
            # Full waveform front end sees ambient floor before speech.
            noise=rng.uniform(-500,500,len(pcm))+220*np.sin(2*np.pi*120*t)+80*np.sin(2*np.pi*240*t)
            noisy=np.clip(pcm.astype(np.float64)*.7+noise,-32768,32767).astype(np.int16)
            np.savez(cp,clean=features(pcm,adaptive_vad=True),noisy=features(noisy,adaptive_vad=True))
        with np.load(cp) as z:return row,z['clean'],z['noisy']
    samples=[]
    with ThreadPoolExecutor(max_workers=4) as pool:
        for i,s in enumerate(pool.map(prepare,enumerate(rows))):
            samples.append(s)
            if i%100==0:print('features',i,'/',len(rows),flush=True)
    rng=np.random.default_rng(20261023)
    def dataset(split):
        xx=[];yy=[];owners=[];counts={}
        for ri,(row,clean,noisy) in enumerate(samples):
            if row['split']!=split:continue
            # Speed augmentation preserves pitch in feature space; actual
            # synthesized clips already include two independently spoken rates.
            views=12 if split=='train' else 6
            for view in range(views):
                f=(clean if view%2==0 else noisy).copy()
                if split=='train' and view>=2:
                    rate=rng.uniform(.55,1.65)
                    t=np.linspace(0,len(f)-1,max(2,round(len(f)/rate)))
                    f=np.stack([np.interp(t,np.arange(len(f)),f[:,j]) for j in range(16)],1)
                    active=np.any(f,axis=1)
                    eq=np.interp(np.arange(16),[0,5,10,15],rng.normal(0,2,4))
                    f=np.clip(np.rint(f+eq+rng.normal(0,1,f.shape)),0,64).astype(np.int8);f[~active]=0
                elif split!='train' and view//2!=1:
                    rate=[.65,1.,1.45][view//2]
                    t=np.linspace(0,len(f)-1,max(2,round(len(f)/rate)))
                    f=np.rint(np.stack([np.interp(t,np.arange(len(f)),f[:,j]) for j in range(16)],1)).astype(np.int8)
                # Changing speech rate must not shorten device warmup. Add
                # fixed quiet AFTER time augmentation, as on a ready board.
                f=np.concatenate([np.zeros((64,16),dtype=np.int8),f])
                found=0
                for start,end in utterances(f):
                    xx.append(normalized_windows(f,start,end));yy.append(row['label']);owners.append(ri);found+=1
                counts[row['label']]=counts.get(row['label'],0)+found
        # Explicit synthetic non-speech candidates keep background rejection.
        if split=='train':
            for _ in range(150):
                f=np.zeros((100,16),dtype=np.int8)
                f[32:64]=rng.integers(0,65,(32,16),dtype=np.int8)
                xx.append(normalized_windows(f,32,70));yy.append(0);owners.append(-1)
        x=np.stack(xx);y=np.array(yy);np.savez(out/(split+'_dataset.npz'),x=x,y=y,owners=owners)
        print('dataset',split,x.shape,counts,flush=True)
        return x,y
    x,y=dataset('train');vx,vy=dataset('validation')
    torch.set_num_threads(4);torch.manual_seed(20261023)
    first=TemporalConv() if args.architecture=='conv' else torch.nn.Linear(768,48)
    net=torch.nn.Sequential(first,torch.nn.ReLU(),torch.nn.Linear(48,3))
    xt=torch.tensor(x.reshape(-1,768)/32,dtype=torch.float32);yt=torch.tensor(np.repeat(y,3))
    vt=torch.tensor(vx.reshape(-1,768)/32,dtype=torch.float32)
    opt=torch.optim.AdamW(net.parameters(),lr=.0007,weight_decay=.004)
    best=None;bestscore=None
    def calibrate(z):
        wins=z.argmax(-1);gaps=np.diff(np.sort(z,axis=-1)[...,-2:],axis=-1)[...,0]
        unanimous=(wins==wins[:,:1]).all(1)&(wins[:,0]!=0)
        mingap=gaps.min(1);neg=mingap[(vy==0)&unanimous]
        thresholds=np.unique(np.r_[1,mingap+1])
        p=np.where(unanimous[None,:] & (mingap[None,:]>=thresholds[:,None]),wins[None,:,0],0)
        correct=((vy[None,:]!=0)&(p==vy[None,:])).sum(1)
        wrong=((vy[None,:]!=0)&(p!=0)&(p!=vy[None,:])).sum(1)
        false=((vy[None,:]==0)&(p!=0)).sum(1)
        eligible=np.flatnonzero(false<=int((vy==0).sum()*.005))
        best=max(eligible,key=lambda i:(int(correct[i]-3*wrong[i]),int(correct[i]),-int(false[i]),-int(thresholds[i])))
        return (int(correct[best]-3*wrong[best]),int(correct[best]),-int(wrong[best])),int(thresholds[best]),p[best]
    for epoch in range(args.epochs):
        net.train()
        for batch in torch.randperm(len(xt)).split(512):
            opt.zero_grad();z=net(xt[batch]);loss=torch.nn.functional.cross_entropy(z,yt[batch],weight=torch.tensor([.5,1.,1.]),label_smoothing=.02)
            loss.backward();opt.step()
        if epoch%5==0 or epoch==args.epochs-1:
            pars=[p.detach().numpy() for p in net.parameters()];w1f,b1f,w2f,b2f=pars
            if args.architecture=='conv':w1f,b1f=first.dense()
            s1=2**int(np.floor(np.log2(127/np.abs(w1f).max())))
            s2=2**int(np.floor(np.log2(127/np.abs(w2f).max())))
            with torch.no_grad():h=net[:2](xt[:10000]).numpy()
            shift=max(0,int(np.ceil(np.log2(s1*32*max(1,float(np.percentile(h,99.95)))/110))))
            hs=s1*32/(2**shift)
            w1=np.rint(w1f*s1).astype(np.int64);b1=np.rint(b1f*s1*32).astype(np.int64)
            w2=np.rint(w2f*s2).astype(np.int64);b2=np.rint(b2f*s2*hs).astype(np.int64)
            z=integer_infer(vx.reshape(-1,768),w1,b1,w2,b2,shift).reshape(-1,3,3)
            score,margin,p=calibrate(z)
            print('epoch',epoch,'loss',float(loss.detach()),'validation',score,'margin',margin,flush=True)
            if bestscore is None or score>bestscore:
                bestscore=score;best=(w1.copy(),b1.copy(),w2.copy(),b2.copy(),shift,margin,p.copy(),epoch)
    w1,b1,w2,b2,shift,margin,p,epoch=best
    model=out/'model';model.mkdir(exist_ok=True)
    def write(name,a,bits): (model/name).write_text(''.join(f'{int(v)&((1<<bits)-1):0{bits//4}x}\n' for v in a.ravel()))
    write('weights.mem',np.concatenate([w1.ravel(),w2.ravel()]),8);write('bias.mem',np.concatenate([b1,b2]),32)
    cfg=dict(inputs=768,frames=48,bands=16,hidden=48,shift=shift,margin=margin,architecture=args.architecture,normalization='utterance_nearest_38_40_42_v1',feature_version='mel63_q8_v3',synthetic_only=True)
    (model/'config.json').write_text(json.dumps(cfg,indent=2))
    cm=np.zeros((3,3),dtype=int)
    for a,b in zip(vy,p):cm[a,b]+=1
    report=dict(selected_epoch=epoch,validation_confusion=cm.tolist(),validation_score=bestscore,
        synthetic_only=True,test_used_for_selection=False,real_recording_used_for_training=False,
        waveform_noise='uniform +-500 PCM16 plus 120/240 Hz hum; gain 0.7',speed_factors=[.55,1.65],
        config=cfg,weight_sha256=sha(model/'weights.mem'),data_manifest_sha256=sha(args.data_root/'data/manifest.json'),
        sources={str(p.relative_to(ROOT.parent)):sha(p) for p in [Path(__file__),ROOT/'tools/robust_common.py',ROOT/'tools/kws_common.py']})
    (out/'training.json').write_text(json.dumps(report,indent=2));print(json.dumps(report),flush=True)

if __name__=='__main__':main()
