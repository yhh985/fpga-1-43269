"""Exact per-pass ROM/MAC/ring-resampling checks, including wrap and boundaries."""
from pathlib import Path
import json,hashlib,subprocess,argparse
import numpy as np
import soundfile as sf
from kws_common import features,read_hex,integer_infer
from robust_common import utterances,normalized_windows,decisions
ROOT=Path(__file__).resolve().parents[2];OUT=ROOT/'verification'
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--candidate',action='store_true');args=ap.parse_args()
 exp=ROOT/'voice/experiments/robust_normalized';model=exp/'model'
 engine=exp/'aca_kws_engine.v' if args.candidate else ROOT/'aca420/rtl/aca_kws_engine.v'
 cfg=json.loads((model/'config.json').read_text());w=read_hex(model/'weights.mem',8);b=read_hex(model/'bias.mem',32)
 rng=np.random.default_rng(20261023);parts=[np.zeros((64,16),dtype=np.int8)]
 for length in [1,5,6,8,13,27,47,66,89,90,91,100,12]:
  parts.extend([rng.integers(1,64,(length,16),dtype=np.int8),np.zeros((64,16),dtype=np.int8)])
 boundary=np.concatenate(parts)
 a,sr=sf.read(OUT/'user_20261021_170604.wav',dtype='int16');assert sr==48000
 real=features(np.r_[np.zeros(98304,dtype=np.int16),a,np.zeros(73728,dtype=np.int16)],adaptive_vad=True,vad_hysteresis=not args.candidate)
 cases={'boundaries':boundary,'real':real};logs={}
 sources=[engine,Path(__file__),ROOT/'voice/tools/robust_common.py',ROOT/'voice/tools/kws_common.py',ROOT/'sim/tb_voice_robust.v',model/'weights.mem',model/'bias.mem',model/'config.json',OUT/'user_20261021_170604.wav']
 hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
 for name,f in cases.items():
  pairs=list(utterances(f,prequiet=8 if args.candidate else 6));assert pairs
  x=np.concatenate([normalized_windows(f,s,e) for s,e in pairs])
  z=integer_infer(x,w[:36864].reshape(48,768),b[:48],w[36864:].reshape(3,48),b[48:],cfg['shift']).reshape(-1,3,3)
  pred=decisions(z,cfg['margin'],relaxed_margin=0 if args.candidate else 650,relaxed_total=3600)
  mapping=np.full(len(f),0xffffffff,dtype=np.uint32)
  for i,(s,e) in enumerate(pairs):mapping[e-1]=i
  def write(name,a,bits): (OUT/name).write_text(''.join(f'{int(v)&((1<<bits)-1):0{bits//4}x}\n' for v in a.ravel()))
  write('robust_inputs.mem',f,8);write('robust_map.mem',mapping,32);write('robust_logits.mem',z,32);write('robust_class.mem',pred,8)
  iver=ROOT/'tools/iverilog/app/bin/iverilog.exe';binary=OUT/'tb_voice_robust.vvp'
  cp=subprocess.run([str(iver),'-g2012','-s','tb_voice_robust',f'-Ptb_voice_robust.FRAMES={len(f)}',f'-Ptb_voice_robust.RESULTS={len(pairs)}','-o',str(binary),str(engine),str(ROOT/'sim/tb_voice_robust.v')],cwd=ROOT,capture_output=True,text=True)
  assert cp.returncode==0,cp.stdout+cp.stderr
  cp=subprocess.run([str(iver.with_name('vvp.exe')),str(binary)],cwd=ROOT,capture_output=True,text=True,timeout=180)
  log=OUT/('robust_'+name+'.run.log');log.write_text(cp.stdout+cp.stderr)
  assert cp.returncode==0 and 'PASS' in cp.stdout,cp.stdout+cp.stderr
  logs[name]=dict(endpoints=len(pairs),predictions=pred.tolist(),log_sha256=hashlib.sha256(log.read_bytes()).hexdigest())
  print(name,cp.stdout.strip(),flush=True)
 assert hashes=={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
 (OUT/'voice_robust_rtl.json').write_text(json.dumps(dict(passed=True,candidate=args.candidate,cases=logs,sources=hashes),indent=2))
if __name__=='__main__':main()
