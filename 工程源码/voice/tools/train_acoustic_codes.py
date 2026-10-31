"""Full-transcript acoustic code experiment; never silently installs firmware.

Use complete synthetic clips, rather than guessing the transcript of VAD fragments.
Validation selects the checkpoint. The previously inspected test and owner pair
are diagnostic replays, not fresh independent evidence.
"""
import os
os.environ.setdefault('OPENBLAS_NUM_THREADS', '1')
from pathlib import Path
import argparse, hashlib, json, time
import numpy as np
import torch
from torch import nn
from train_sequence_ctc import raw_features, batch, ROOT, DATA, candidates
from probe_vad_continuity import prepare
from concurrent.futures import ThreadPoolExecutor

OUT = ROOT/'voice/experiments/acoustic_codes_v2'
ROWS = json.loads((DATA/'data/manifest.json').read_text(encoding='utf8'))
TOKENS = ['<blank>'] + sorted(set(''.join(r['text'] for r in ROWS)))
VOCAB = {c:i for i,c in enumerate(TOKENS)}
TEXTS = sorted(set(r['text'] for r in ROWS))
WORDS = {1:'下一张', 2:'上一张'}

class Net(nn.Module):
    def __init__(self):
        super().__init__()
        self.layers = nn.ModuleList([
            nn.Sequential(nn.Conv1d(16,48,5,padding=2),nn.BatchNorm1d(48),nn.ReLU()),
            nn.Sequential(nn.Conv1d(48,48,5,padding=4,dilation=2),nn.BatchNorm1d(48),nn.ReLU()),
            nn.Sequential(nn.Conv1d(48,48,5,padding=8,dilation=4),nn.BatchNorm1d(48),nn.ReLU())])
        self.out = nn.Conv1d(48,len(TOKENS),1)
        self.aux = nn.Linear(48,len(TEXTS))
    def forward(self,x,lengths=None):
        h=x.transpose(1,2)-1
        for layer in self.layers:h=layer(h)
        z=self.out(h).transpose(1,2)
        if lengths is None:return z
        mask=torch.arange(h.shape[2])[None,:]<lengths[:,None]
        pooled=(h*mask[:,None,:]).sum(2)/lengths[:,None]
        return z,self.aux(pooled)

def greedy(z):
    ids=z.argmax(1);last=0;text='';gaps=[]
    for t,k in enumerate(ids):
        if k and k!=last:
            text+=TOKENS[k];gaps.append(float(z[t,k]-np.max(np.delete(z[t],k))))
        last=k
    cls=next((c for c,w in WORDS.items() if w==text),0)
    return cls,min(gaps) if cls else -1,text

@torch.no_grad()
def infer(net,xs):
    out=[]
    for i in range(0,len(xs),64):
        x,lens=batch(xs[i:i+64]);z=net(x).numpy()
        out.extend(greedy(a[:n]) for a,n in zip(z,lens.numpy()))
    return out

def metrics(labs,owners,decoded,margin):
    pred=np.zeros(len(labs),dtype=int)
    for o,(c,g,_) in zip(owners,decoded):
        if c and g>=margin and not pred[o]:pred[o]=c
    cm=np.zeros((3,3),dtype=int)
    for a,b in zip(labs,pred):cm[a,b]+=1
    return dict(correct=int(cm[1,1]+cm[2,2]),wrong_direction=int(cm[1,2]+cm[2,1]),
                false_accepts=int(cm[0,1:].sum()),confusion=cm.tolist())

def dataset():
    OUT.mkdir(parents=True,exist_ok=True)
    path=OUT/'full_clips.npz'
    if path.exists():return np.load(path)
    arrays={};samples=[]
    with ThreadPoolExecutor(max_workers=4) as pool:
        for i,s in enumerate(pool.map(prepare,enumerate(ROWS))):
            samples.append(s)
            if i%400==0:print('cached power',i,flush=True)
    for split in ['train','validation','test']:
        xs=[];rowids=[];owners=[];labels=[];targets=[]
        for row,clean,noisy in samples:
            if row['split']!=split:continue
            ri=ROWS.index(row)
            for p in [clean,noisy]:
                raw=raw_features(p)[29:-42] # Known 32-frame lead,48-frame tail: retain 3/6.
                for rate in ([.75,1,1.3] if split=='train' else [.65,1,1.45]):
                    pos=np.arange(max(3,round(len(raw)/rate)))*rate
                    x=np.rint(np.stack([np.interp(pos,np.arange(len(raw)),raw[:,j]) for j in range(16)],1)).astype(np.int8)
                    xs.append(x);rowids.append(ri);owners.append(len(labels));labels.append(row['label'])
        arrays.update({split+'_x':np.concatenate(xs),split+'_lengths':np.array([len(x) for x in xs]),
                       split+'_rowids':np.array(rowids),split+'_labels':np.array(labels)})
    np.savez_compressed(path,**arrays)
    return np.load(path)

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--epochs',type=int,default=80)
    ap.add_argument('--prevent-boundary-shortcut',action='store_true');a=ap.parse_args()
    global OUT
    if a.prevent_boundary_shortcut:OUT=ROOT/'voice/experiments/acoustic_codes_v3'
    torch.set_num_threads(4);torch.manual_seed(20261026);rng=np.random.default_rng(20261026)
    ds=dataset()
    def split(name):
        xs=np.split(ds[name+'_x'],np.cumsum(ds[name+'_lengths'])[:-1]);rowids=ds[name+'_rowids']
        return xs,[[VOCAB[c] for c in ROWS[i]['text']] for i in rowids],rowids,ds[name+'_labels']
    tx,ty,tr,tl=split('train');vx,vy,vr,vl=split('validation')
    # Full-stream candidate evaluation prevents clean-clip accuracy concealing VAD failures.
    stream=np.load(ROOT/'voice/experiments/sequence_ctc/dataset.npz')
    sx=np.split(stream['validation_x'],np.cumsum(stream['validation_lengths'])[:-1])
    so,sl=stream['validation_owners'],stream['validation_labels']
    net=Net();opt=torch.optim.AdamW(net.parameters(),lr=.001,weight_decay=.001)
    ctc=nn.CTCLoss(blank=0,zero_infinity=False,reduction='none');best=None;history=[];t0=time.time()
    commands=np.flatnonzero(tl!=0)
    for epoch in range(a.epochs):
        net.train();losses=[]
        ids=np.r_[rng.permutation(len(tx)),rng.choice(commands,len(tx)//3)];rng.shuffle(ids)
        for ix in np.array_split(ids,max(1,len(ids)//64)):
            xs=[];targets=[];classes=[]
            for i in ix:
                x=tx[i].astype(np.float32).copy()
                if rng.random()<.7:
                    eq=np.interp(np.arange(16),[0,5,10,15],rng.normal(0,2,4))
                    active=np.any(x,axis=1);x[active]=np.clip(x[active]+eq+rng.normal(0,.7,x[active].shape),0,64)
                if a.prevent_boundary_shortcut:
                    # Random time origin prevents CTC learning a fixed opening
                    # character from convolution padding instead of the audio.
                    x=np.pad(x,((int(rng.integers(0,13)),int(rng.integers(0,13))),(0,0)))
                xs.append(x);targets.append(ty[i]);classes.append(TEXTS.index(ROWS[tr[i]]['text']))
            if a.prevent_boundary_shortcut:
                # Empty transcript is a real CTC target, NOT the word OTHER.
                for _ in range(8):
                    n=int(rng.integers(15,100));quiet=np.zeros((n,16),dtype=np.float32)
                    if rng.random()<.5:quiet=np.clip(rng.normal(0,.7,(n,16)),0,64).astype(np.float32)
                    xs.append(quiet);targets.append([]);classes.append(-100)
            x,lens=batch(xs);z,aux=net(x,lens)
            target=torch.tensor(np.concatenate(targets)).long();tls=torch.tensor([len(t) for t in targets])
            ce=ctc(z.log_softmax(2).transpose(0,1),target,lens,tls)/tls.clamp(min=1)
            cls=torch.tensor(classes)
            loss=ce.mean()+.3*nn.functional.cross_entropy(aux,cls)
            assert torch.isfinite(loss)
            opt.zero_grad();loss.backward();nn.utils.clip_grad_norm_(net.parameters(),5);opt.step()
            losses.append(float(loss.detach()))
        if epoch%5==4 or epoch==0:
            net.eval();decoded=infer(net,sx);options=[]
            for margin in [0,.25,.5,1,1.5,2,3,4]:
                m=metrics(sl,so,decoded,margin)
                if m['false_accepts']<=8:options.append(((m['correct']-3*m['wrong_direction'],m['correct'],-m['false_accepts']),margin,m))
            rank,margin,m=max(options,key=lambda t:t[0]);record=dict(epoch=epoch,loss=float(np.mean(losses)),margin=margin,validation=m)
            history.append(record)
            if best is None or rank>best:
                best=rank;torch.save(net.state_dict(),OUT/'candidate.pt');(OUT/'selected.json').write_text(json.dumps(record,indent=2))
            print('epoch',epoch,'loss',round(record['loss'],4),m,'seconds',round(time.time()-t0,1),flush=True)
            (OUT/'history.json').write_text(json.dumps(history,indent=2))
    selected=json.loads((OUT/'selected.json').read_text());net.load_state_dict(torch.load(OUT/'candidate.pt',weights_only=True));net.eval()
    report=dict(experimental_only=True,fpga_deployed=False,real_used_for_training=False,
                prevent_boundary_shortcut=a.prevent_boundary_shortcut,
                test_previously_inspected=True,selected=selected,tokens=TOKENS,results={})
    for name in ['validation','test']:
        x=np.split(stream[name+'_x'],np.cumsum(stream[name+'_lengths'])[:-1])
        report['results'][name]=metrics(stream[name+'_labels'],stream[name+'_owners'],infer(net,x),selected['margin'])
    import soundfile as sf
    from kws_common import mel_powers,decimate
    wav=ROOT/'verification/user_20261021_170604.wav';audio,sr=sf.read(wav,dtype='int16');assert sr==48000
    clips=candidates(mel_powers(decimate(np.r_[np.zeros(98304,dtype=np.int16),audio,np.zeros(73728,dtype=np.int16)])))
    report['real_development']=[dict(start=s,end=e,prediction=c if gap>=selected['margin'] else 0,text=text,gap=gap)
                              for (_,_,s,e),(c,gap,text) in zip(clips,infer(net,[x for x,_,_,_ in clips]))]
    report['sources']={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path(__file__),wav,OUT/'candidate.pt',OUT/'full_clips.npz',OUT/'selected.json']}
    (OUT/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf8')
    print(json.dumps({k:v for k,v in report.items() if k!='sources'},ensure_ascii=True,indent=2),flush=True)

if __name__=='__main__':main()
