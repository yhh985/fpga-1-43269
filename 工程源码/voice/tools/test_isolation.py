"""Build a short-gap recording and verify independent utterances in actual RTL."""
import json,subprocess
from pathlib import Path
import numpy as np
from kws_common import FEATURE_VERSION,endpoints

ROOT=Path(__file__).resolve().parents[2]
chunks=[np.zeros((64,16),dtype=np.int8)]
for name in ['s005_p00_0','s005_p01_0']:
    f=np.load(ROOT/f'voice/data/{name}_{FEATURE_VERSION}.npz')['f']
    active=np.flatnonzero(np.any(f,axis=1));f=f[active[0]:active[-1]+1]
    chunks.extend([f,np.zeros((8,16),dtype=np.int8),np.full((8,16),20,dtype=np.int8),np.zeros((64,16),dtype=np.int8)])
f=np.concatenate(chunks);ends=list(endpoints(f,robust=True));assert len(ends)==4,ends
(ROOT/'verification/isolation_inputs.mem').write_text('\n'.join(f'{int(v):02x}' for v in f.ravel())+'\n')
mapping=np.full(len(f),0xffffffff,dtype=np.uint32)
for i,end in enumerate(ends):mapping[end-1]=i
(ROOT/'verification/isolation_map.mem').write_text('\n'.join(f'{int(v):08x}' for v in mapping)+'\n')
iver=ROOT/'tools/iverilog/app/bin/iverilog.exe';binary=ROOT/'verification/tb_kws_isolation.vvp'
cp=subprocess.run([str(iver),'-g2012','-s','tb_kws_isolation',f'-Ptb_kws_isolation.FRAMES={len(f)}',
    '-o',str(binary),'aca420/rtl/aca_kws_engine.v','sim/tb_kws_isolation.v'],cwd=ROOT,capture_output=True,text=True)
assert cp.returncode==0,cp.stderr
p=subprocess.run([str(iver.with_name('vvp.exe')),str(binary)],cwd=ROOT,capture_output=True,text=True)
(ROOT/'verification/tb_kws_isolation.run.log').write_text(p.stdout+p.stderr)
print(p.stdout,p.stderr)
assert p.returncode==0 and 'PASS' in p.stdout
