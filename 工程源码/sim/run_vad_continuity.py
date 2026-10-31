"""Exact old/new frontend equivalence and weak-onset/continuation controls."""
from pathlib import Path
import sys,json,hashlib,subprocess
import numpy as np
import soundfile as sf
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'voice/tools'))
from kws_common import features,mel_powers,decimate
from probe_vad_continuity import gated_features

out=ROOT/'verification'; iver=ROOT/'tools/iverilog/app/bin/iverilog.exe'
files=[Path(__file__),ROOT/'sim/tb_vad_continuity.v',ROOT/'aca420/rtl/aca_kws_frontend.v',
 ROOT/'aca420/rtl/kws_goertzel.v',ROOT/'voice/tools/kws_common.py',ROOT/'voice/tools/probe_vad_continuity.py',out/'user_20261021_170604.wav']
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
hashes={str(p.relative_to(ROOT)):sha(p) for p in files}
audio,sr=sf.read(out/'user_20261021_170604.wav',dtype='int16');assert sr==48000
pcm=np.r_[np.zeros(98304,dtype=np.int16),audio,np.zeros(73728,dtype=np.int16)]
real=mel_powers(decimate(pcm))
# Background=4096. Weak is >+4 but <=+8; only a preceding strong
# frame may admit it. Include one/two/three-band and exact threshold probes.
quiet=np.full((32,16),4096,dtype=np.uint32)
weak=np.full((8,16),12288,dtype=np.uint32)
strong=np.full((8,16),262144,dtype=np.uint32)
controls=np.r_[quiet,weak,quiet,strong,weak,quiet,strong,np.zeros((14,16),dtype=np.uint32),quiet]
rng=np.random.default_rng(20261023)
random=rng.integers(0,2**25,(512,16),dtype=np.uint32)
random=np.r_[quiet,random,quiet]
two=np.full((8,16),4096,dtype=np.uint32);two[:,:2]=12288
one=np.full((8,16),4096,dtype=np.uint32);one[:,:1]=12288
equal=np.full((8,16),8192,dtype=np.uint32)
bands=np.r_[quiet,strong,two,quiet,strong,one,quiet,strong,equal,quiet]
cases={'controls':controls,'bands':bands,'real':real,'random':random}
records={}
def write(name,arr,bits):
 (out/name).write_text(''.join(f'{int(v):0{bits//4}x}\n' for v in arr.ravel()))
for name,p in cases.items():
 for mode in [0,1]:
  f=gated_features(p,'hysteresis' if mode else 'baseline')
  if name=='real':assert np.array_equal(f,features(pcm,adaptive_vad=True,vad_hysteresis=bool(mode)))
  if name=='controls':
   assert not np.any(f[16:20]),'weak onset opened gate'
   assert np.any(f[40:44])==bool(mode),'weak continuation did not follow selected policy'
   assert not np.any(f[44:60]),'silence appended a hangover'
  if name=='bands':
   assert np.any(f[20:24])==bool(mode),'two-band continuation policy'
   assert not np.any(f[44:48]),'single-band interference continued speech'
   assert not np.any(f[68:72]),'exact release threshold must remain closed'
  write('vad_powers.mem',p,32);write('vad_features.mem',f,8)
  binary=out/'tb_vad_continuity.vvp'
  cmd=[str(iver),'-g2012','-s','tb_vad_continuity',f'-Ptb_vad_continuity.FRAMES={len(p)}',
   f'-Ptb_vad_continuity.HYSTERESIS={mode}','-o',str(binary),str(files[1]),str(files[2]),str(files[3])]
  cp=subprocess.run(cmd,cwd=ROOT,capture_output=True,text=True);assert cp.returncode==0,cp.stderr
  cp=subprocess.run([str(iver.with_name('vvp.exe')),str(binary)],cwd=ROOT,capture_output=True,text=True)
  log=out/f'vad_{name}_{mode}.run.log';log.write_text(cp.stdout+cp.stderr)
  assert cp.returncode==0 and 'PASS' in cp.stdout,cp.stdout+cp.stderr
  records[f'{name}_{mode}']=dict(passed=True,features=int(f.size),log_sha256=sha(log))
  print(cp.stdout.strip(),flush=True)
assert hashes=={str(p.relative_to(ROOT)):sha(p) for p in files}
(out/'vad_continuity.json').write_text(json.dumps(dict(passed=True,cases=records,sources=hashes),indent=2))
