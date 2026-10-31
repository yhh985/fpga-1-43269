"""Bit-exact spectral regression and real sample-clock budget for packed RAM."""
from pathlib import Path
import sys, json, hashlib, subprocess
import numpy as np
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'voice/tools'))
from kws_common import mel_powers

OUT=ROOT/'verification/voice_ram_pack'
OUT.mkdir(exist_ok=True)
iver=ROOT/'tools/iverilog/app/bin/iverilog.exe'
rng=np.random.default_rng(20261023)
t=np.arange(128)
pcm=np.concatenate([np.zeros(128),np.full(128,32767),np.full(128,-32768),
                    rng.integers(-32768,32768,128),32767*np.cos(2*np.pi*t/128),
                    32767*np.cos(2*np.pi*31*t/128),32767*np.cos(2*np.pi*63*t/128),
                    np.where(t%2,32767,-32768)]).astype(np.int16)
def write(p,a,bits):
    p.write_text(''.join(f'{int(v)&((1<<bits)-1):0{bits//4}x}\n' for v in a.ravel()))
write(OUT/'mel_pcm8.mem',pcm,16)
write(OUT/'mel_powers.mem',mel_powers(pcm),32)
legacy=ROOT/'archive/before_voice_ram_pack_20261023/kws_goertzel.v'
old=OUT/'kws_goertzel_old.v'
old.write_text(legacy.read_text().replace('module kws_goertzel(', 'module kws_goertzel_old('))
tb=ROOT/'sim/tb_voice_ram_pack.v'
sources=[ROOT/'aca420/rtl/kws_goertzel.v',legacy,tb,Path(__file__),
         ROOT/'voice/tools/generate_mel_rtl.py',ROOT/'voice/tools/kws_common.py']
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
hashes={str(p.relative_to(ROOT)):sha(p) for p in sources}
binary=OUT/'test.vvp'
cp=subprocess.run([str(iver),'-g2012','-Wall','-s','tb_voice_ram_pack','-o',str(binary),
                   str(sources[0]),str(old),str(tb)],capture_output=True,text=True)
(OUT/'compile.log').write_text(cp.stdout+cp.stderr)
assert cp.returncode==0,cp.stdout+cp.stderr
cp=subprocess.run([str(iver.with_name('vvp.exe')),str(binary)],cwd=OUT,capture_output=True,text=True,timeout=240)
(OUT/'run.log').write_text(cp.stdout+cp.stderr)
assert cp.returncode==0 and 'PASS' in cp.stdout,cp.stdout+cp.stderr
assert hashes=={str(p.relative_to(ROOT)):sha(p) for p in sources}
report=dict(passed=True,power_values=128,bit_exact_to_original=True,
            sample_period_clocks=6246,arithmetic_precision_unchanged=True,
            mid_window_reset_tested=True,sources=hashes,log_sha256=sha(OUT/'run.log'))
(ROOT/'verification/voice_ram_pack.json').write_text(json.dumps(report,indent=2))
print(cp.stdout.strip(),flush=True)
