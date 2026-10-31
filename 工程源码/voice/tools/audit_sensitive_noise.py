"""Report continuous-noise behavior of the sensitive trial, without retuning."""
from pathlib import Path
import hashlib,json
import numpy as np
from kws_common import features,read_hex,integer_infer
from robust_common import utterances
from audit_sensitive_guard import native_window
ROOT=Path(__file__).resolve().parents[2]
rng=np.random.default_rng(20261020);seconds=120;n=seconds*48000;t=np.arange(n)/48000
noise=rng.normal(0,1,n);pcm=np.zeros(n)
pcm[10*48000:40*48000]=noise[10*48000:40*48000]*250
fan=900*np.sin(2*np.pi*120*t)+350*np.sin(2*np.pi*240*t)
pcm[40*48000:70*48000]=fan[40*48000:70*48000]+noise[40*48000:70*48000]*150
for sec in range(70,100):
 start=sec*48000;pcm[start:start+48000]=noise[start:start+48000]*(120 if sec%2 else 1500)
for sec in range(100,120):
 start=sec*48000;pcm[start:start+48000]=noise[start:start+48000]*120;pcm[start:start+480]=rng.normal(0,8000,480)
f=features(np.clip(pcm,-32768,32767).astype(np.int16),True,vad_hysteresis=True)
pairs=list(utterances(f,prequiet=0,max_frames=64));model=ROOT/'voice/model'
w=read_hex(model/'weights.mem',8);b=read_hex(model/'bias.mem',32)
xs=np.stack([native_window(f,s,e) for s,e in pairs]) if pairs else np.zeros((0,768))
z=integer_infer(xs,w[:36864].reshape(48,768),b[:48],w[36864:].reshape(3,48),b[48:],9)
win=z.argmax(1);gap=np.diff(np.sort(z,axis=1)[:,-2:]).ravel()
pred=np.where((win!=0)&(gap>=109)&(z.max(1)>=0),win,0)
files=[Path(__file__),ROOT/'voice/tools/kws_common.py',ROOT/'voice/tools/robust_common.py',ROOT/'voice/tools/audit_sensitive_guard.py',model/'weights.mem',model/'bias.mem']
r=dict(completed=True,synthetic_only=True,seconds=seconds,endpoints=len(pairs),false_commands=int(np.count_nonzero(pred)),predictions=pred.tolist(),note='Not real-room false-trigger rate; not used to retune the selected validation policy',sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files})
(ROOT/'verification/sensitive_noise.json').write_text(json.dumps(r,indent=2));print(json.dumps(r),flush=True)
