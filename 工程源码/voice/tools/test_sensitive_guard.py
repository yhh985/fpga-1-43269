"""Exact production-sensitive inference path and deterministic noise replay."""
from pathlib import Path
import json,subprocess,hashlib
import numpy as np
import soundfile as sf
from kws_common import features,read_hex,integer_infer
from robust_common import utterances
from audit_sensitive_guard import native_window
ROOT=Path(__file__).resolve().parents[2];OUT=ROOT/'verification'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
model=ROOT/'voice/model';w=read_hex(model/'weights.mem',8);b=read_hex(model/'bias.mem',32)
infer=lambda x:integer_infer(x,w[:36864].reshape(48,768),b[:48],w[36864:].reshape(3,48),b[48:],9)
rng=np.random.default_rng(20261023);parts=[np.zeros((64,16),dtype=np.int8)]
for length in [1,5,6,12,41,42,43,57,58,59,90,10]:
 parts.extend([rng.integers(1,64,(length,16),dtype=np.int8),np.zeros((64,16),dtype=np.int8)])
audio,sr=sf.read(OUT/'user_20261021_170604.wav',dtype='int16');assert sr==48000
real=features(np.r_[np.zeros(98304,dtype=np.int16),audio,np.zeros(73728,dtype=np.int16)],True,vad_hysteresis=True)
cases={'boundaries':np.concatenate(parts),'real_development':real};records={}
files=[Path(__file__),ROOT/'aca420/rtl/aca_kws_engine.v',ROOT/'aca420/rtl/aca420_audio_top.v',
 ROOT/'aca420/rtl/aca_kws_frontend.v',ROOT/'sim/tb_voice_sensitive.v',ROOT/'sim/tb_sensitive_score.v',
 ROOT/'voice/tools/kws_common.py',ROOT/'voice/tools/robust_common.py',ROOT/'voice/tools/audit_sensitive_guard.py',
 model/'weights.mem',model/'bias.mem',OUT/'user_20261021_170604.wav']
snapshot={str(p.relative_to(ROOT)):sha(p) for p in files}
iver=ROOT/'tools/iverilog/app/bin/iverilog.exe'
def write(name,a,bits):
 (OUT/name).write_text(''.join(f'{int(v)&((1<<bits)-1):0{bits//4}x}\n' for v in a.ravel()))
for name,f in cases.items():
 pairs=list(utterances(f,prequiet=0,max_frames=64));assert pairs
 z=infer(np.stack([native_window(f,s,e) for s,e in pairs]))
 win=z.argmax(1);gap=np.diff(np.sort(z,axis=1)[:,-2:]).ravel()
 pred=np.where((win!=0)&(gap>=109)&(z.max(1)>=0),win,0)
 if name=='real_development':assert pred.tolist()==[2,0],'Old NEXT must remain explicit failure, never a claimed fix'
 mapping=np.full(len(f),0xffffffff,dtype=np.uint32)
 for i,(_,e) in enumerate(pairs):mapping[e-1]=i
 for n,a,bits in [('inputs',f,8),('map',mapping,32),('logits',z,32),('class',pred,8)]:write(f'sensitive_{n}.mem',a,bits)
 binary=OUT/'tb_voice_sensitive.vvp'
 cp=subprocess.run([str(iver),'-g2012','-s','tb_voice_sensitive',f'-Ptb_voice_sensitive.FRAMES={len(f)}',f'-Ptb_voice_sensitive.RESULTS={len(pairs)}','-o',str(binary),str(ROOT/'aca420/rtl/aca_kws_engine.v'),str(ROOT/'sim/tb_voice_sensitive.v')],cwd=ROOT,capture_output=True,text=True)
 assert cp.returncode==0,cp.stderr
 cp=subprocess.run([str(iver.with_name('vvp.exe')),str(binary)],cwd=ROOT,capture_output=True,text=True,timeout=120)
 log=OUT/f'sensitive_{name}.run.log';log.write_text(cp.stdout+cp.stderr)
 assert cp.returncode==0 and 'PASS' in cp.stdout,cp.stdout+cp.stderr
 records[name]=dict(passed=True,endpoints=len(pairs),predictions=pred.tolist(),log_sha256=sha(log))
 print(cp.stdout,flush=True)
binary=OUT/'tb_sensitive_score.vvp'
cp=subprocess.run([str(iver),'-g2012','-s','tb_sensitive_score','-o',str(binary),str(ROOT/'aca420/rtl/aca_kws_engine.v'),str(ROOT/'sim/tb_sensitive_score.v')],cwd=ROOT,capture_output=True,text=True);assert cp.returncode==0,cp.stderr
cp=subprocess.run([str(iver.with_name('vvp.exe')),str(binary)],cwd=ROOT,capture_output=True,text=True)
log=OUT/'sensitive_score.run.log';log.write_text(cp.stdout+cp.stderr);assert cp.returncode==0 and 'PASS' in cp.stdout,cp.stdout+cp.stderr
records['score']=dict(passed=True,log_sha256=sha(log));print(cp.stdout,flush=True)
assert snapshot=={str(p.relative_to(ROOT)):sha(p) for p in files}
(OUT/'sensitive_guard_rtl.json').write_text(json.dumps(dict(passed=True,cases=records,sources=snapshot),indent=2))
