"""Deterministic continuous non-speech regression of the normalized candidate."""
from pathlib import Path
import hashlib,json
import numpy as np
from kws_common import features,integer_infer,read_hex
from robust_common import utterances,normalized_windows,decisions
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
pcm=np.clip(pcm,-32768,32767).astype(np.int16);f=features(pcm,adaptive_vad=True,vad_hysteresis=True)
pairs=list(utterances(f,prequiet=6));model=ROOT/'voice/experiments/robust_normalized/model'
c=json.loads((model/'config.json').read_text());w=read_hex(model/'weights.mem',8);b=read_hex(model/'bias.mem',32)
x=np.concatenate([normalized_windows(f,s,e) for s,e in pairs]) if pairs else np.zeros((0,768))
z=integer_infer(x,w[:36864].reshape(48,768),b[:48],w[36864:].reshape(3,48),b[48:],c['shift']).reshape(-1,3,3)
p=decisions(z,c['margin'],relaxed_margin=650,relaxed_total=3600)
files=[Path(__file__),ROOT/'voice/tools/kws_common.py',ROOT/'voice/tools/robust_common.py',model/'weights.mem',model/'bias.mem',model/'config.json']
report=dict(passed=not bool(np.any(p)),seconds=seconds,endpoints=len(pairs),false_commands=int(np.count_nonzero(p)),synthetic_only=True,
 note='Synthetic non-speech pressure test, not a real-room false trigger rate',
 sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files})
(ROOT/'verification/voice_robust_noise.json').write_text(json.dumps(report,indent=2));print(json.dumps(report),flush=True)
assert report['passed'],'Continuous noise emitted a command'
