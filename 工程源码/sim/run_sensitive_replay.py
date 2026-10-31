"""Host telemetry fixture: one valid logit vector must not become three votes."""
from pathlib import Path
import sys,json,binascii,hashlib
import numpy as np
import soundfile as sf
ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'voice/tools'),str(ROOT/'tools')]
from kws_common import features,read_hex,integer_infer
from robust_common import utterances
from audit_sensitive_guard import native_window
from replay_voice_capture import replay
from decode_voice_capture import decode
out=ROOT/'verification';model=ROOT/'voice/model'
a,sr=sf.read(out/'user_20261021_170604.wav',dtype='int16');assert sr==48000
f=features(np.r_[np.zeros(98304,dtype=np.int16),a,np.zeros(73728,dtype=np.int16)],True,vad_hysteresis=True)
w=read_hex(model/'weights.mem',8);b=read_hex(model/'bias.mem',32)
ends={e-1:(s,e) for s,e in utterances(f,prequiet=0,max_frames=64)}
raw=bytearray();seq=0;logits=np.zeros((3,3),dtype='<i4');voiced=duration=flags=0
for i,row in enumerate(f):
 if i in ends:
  s,e=ends[i];seq+=1;duration=e-s;voiced=int(np.any(f[s:e],axis=1).sum())
  z=integer_infer(native_window(f,s,e)[None],w[:36864].reshape(48,768),b[:48],w[36864:].reshape(3,48),b[48:],9)[0]
  logits[:]=0;logits[0]=z;gap=np.diff(np.sort(z)[-2:])[0]
  flags=(16 if z.argmax()==0 else 0)|(32 if gap<109 or z.max()<0 else 0)
 h=bytearray(72);h[:3]=b'\xa5\x5a\x52';h[3:5]=i.to_bytes(2,'little');h[6]=flags;h[7]=voiced;h[8]=duration
 h[9:11]=seq.to_bytes(2,'little');h[12:28]=row.tobytes();h[28:64]=logits.tobytes()
 raw+=h+binascii.crc_hqx(h,0xffff).to_bytes(2,'little')
p=out/'sensitive_host_fixture.feature.bin';p.write_bytes(raw)
r=replay(p,model,'sensitive');assert r['inferred_attempts']==2 and r['all_compared_logits_match']
d,_=decode(raw,passes=1);assert all(len(x['winners'])==1 for x in d['attempts'])
assert not replay(p,model,'normalized')['all_compared_logits_match'],'Wrong model layout silently accepted'
files=[Path(__file__),ROOT/'tools/replay_voice_capture.py',ROOT/'tools/decode_voice_capture.py',ROOT/'voice/tools/kws_common.py',ROOT/'voice/tools/audit_sensitive_guard.py',model/'weights.mem',model/'bias.mem',out/'user_20261021_170604.wav']
(out/'sensitive_host.json').write_text(json.dumps(dict(passed=True,fixture_only=True,exact_attempts=2,sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}),indent=2))
print('PASS sensitive host: exact fixed-window replay, one pass, negative-score rejection and wrong-layout mismatch')
