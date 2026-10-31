"""Deterministic 120-second non-speech stream; report every endpoint/command."""
import hashlib,json
from pathlib import Path
import numpy as np
from kws_common import features,endpoints,endpoint_windows,integer_infer,read_hex

ROOT=Path(__file__).resolve().parents[1]
rng=np.random.default_rng(20261020)
seconds=120;n=seconds*48000;t=np.arange(n)/48000
noise=rng.normal(0,1,n)
pcm=np.zeros(n)
# Stationary microphone floor, changing fan hum, step changes and short clicks.
pcm[10*48000:40*48000]=noise[10*48000:40*48000]*250
fan=(900*np.sin(2*np.pi*120*t)+350*np.sin(2*np.pi*240*t))
pcm[40*48000:70*48000]=fan[40*48000:70*48000]+noise[40*48000:70*48000]*150
for sec in range(70,100):
    start=sec*48000
    pcm[start:start+48000]=noise[start:start+48000]*(120 if sec%2 else 1500)
for sec in range(100,120):
    start=sec*48000
    pcm[start:start+48000]=noise[start:start+48000]*120
    pcm[start:start+480]=rng.normal(0,8000,480)
pcm=np.clip(pcm,-32768,32767).astype(np.int16)
f=features(pcm,adaptive_vad=True);ends=list(endpoints(f,robust=True))
c=json.loads((ROOT/'model/config.json').read_text())
w=read_hex(ROOT/'model/weights.mem',8);b=read_hex(ROOT/'model/bias.mem',32)
windows=np.concatenate([endpoint_windows(f,e) for e in ends]) if ends else np.zeros((0,768))
z=integer_infer(windows,w[:36864].reshape(48,768),b[:48],w[36864:].reshape(3,48),b[48:],c['shift']).reshape(-1,3,3)
winners=z.argmax(axis=2);margins=np.diff(np.sort(z,axis=2)[:,:,-2:],axis=2)[:,:,0]
accept=(winners==winners[:,0,None]).all(axis=1)&(margins>=c['margin']).all(axis=1)&(winners[:,0]!=0)
report=dict(seconds=seconds,synthetic_only=True,feature_frames=len(f),endpoints=len(ends),
    false_commands=int(accept.sum()),passed=not bool(accept.any()),
    commands=[dict(end_frame=e,logits=zz.tolist()) for e,zz,ok in zip(ends,z,accept) if ok],
    sources={str(p.relative_to(ROOT.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in
             [ROOT/'tools/kws_common.py',ROOT.parent/'aca420/rtl/aca_kws_frontend.v',ROOT.parent/'aca420/rtl/aca_kws_engine.v']},
    note='Synthetic non-speech stress stream, not a real-room false alarm rate.')
(ROOT/'verification/continuous_noise.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
assert report['passed'],'Synthetic background caused a voice command'
