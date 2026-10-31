"""Compare actual RTL frontend and every integer MLP logit to Python goldens."""
import json,subprocess,hashlib
from pathlib import Path
import numpy as np
import soundfile as sf
from kws_common import *

ROOT=Path(__file__).resolve().parents[1]
WS=ROOT.parents[1]
OUT=ROOT/'verification'
IVER=ROOT.parent/'tools/iverilog/app/bin/iverilog.exe'
VVP=IVER.with_name('vvp.exe')
RTL=ROOT.parent/'aca420/rtl'

def writehex(path,data,bits):
    path.write_text('\n'.join(f'{int(x)&((1<<bits)-1):0{bits//4}x}' for x in np.asarray(data).ravel())+'\n')

def run(name,files,parameters=()):
    binary=OUT/(name+'.vvp')
    command=[str(IVER),'-g2012','-Wall','-s',name,*parameters,'-o',str(binary),*[str(f) for f in files]]
    p=subprocess.run(command,capture_output=True,text=True)
    (OUT/(name+'.compile.log')).write_text(p.stdout+p.stderr)
    if p.returncode:raise RuntimeError(p.stdout+p.stderr)
    p=subprocess.run([str(VVP),str(binary)],cwd=OUT,capture_output=True,text=True)
    (OUT/(name+'.run.log')).write_text(p.stdout+p.stderr)
    if p.returncode or 'PASS' not in p.stdout:raise RuntimeError(p.stdout+p.stderr)
    print(p.stdout.strip(),flush=True)
    return p.stdout.strip()

def verify_mel():
    OUT.mkdir(exist_ok=True)
    rng=np.random.default_rng(217)
    t=np.arange(128)
    mel_input=np.concatenate([np.zeros(128),np.full(128,32767),np.full(128,-32768),
        rng.integers(-32768,32768,128),32767*np.cos(2*np.pi*t/128),
        32767*np.cos(2*np.pi*31*t/128),32767*np.cos(2*np.pi*63*t/128),
        np.where(t%2,32767,-32768)]).astype(np.int16)
    writehex(OUT/'mel_pcm8.mem',mel_input,16)
    writehex(OUT/'mel_powers.mem',mel_powers(mel_input),32)
    return run('tb_mel_powers',[RTL/'kws_goertzel.v',ROOT/'tb_mel_powers.v'])

def main():
    tracked=[RTL/'aca_kws_frontend.v',RTL/'aca_kws_engine.v',RTL/'kws_goertzel.v',Path(__file__),ROOT/'tools/kws_common.py']
    fingerprint=lambda:{str(p.relative_to(ROOT.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    initial_sources=fingerprint()
    mel_result=verify_mel()
    a,sr=sf.read(ROOT/'data/s005_p00_0.wav')
    p=pcm48(a,sr)
    # Add silence, noise and a clipped impulse. This validates quiet gating too.
    rng=np.random.default_rng(41)
    p=np.concatenate([np.zeros(6144,dtype=np.int16),p,
                      rng.integers(-1000,1000,12288,dtype=np.int16),np.zeros(6144,dtype=np.int16)])
    f=features(p)
    writehex(OUT/'pcm.mem',p,16);writehex(OUT/'features.mem',f,8)
    result=run('tb_kws_frontend',[RTL/'kws_goertzel.v',RTL/'aca_kws_frontend.v',ROOT/'tb_kws_frontend.v'],
               [f'-Ptb_kws_frontend.SAMPLES={len(p)}',f'-Ptb_kws_frontend.FEATURES={f.size}'])
    # Production path: calibrate on nonzero noise, then speech mixed with that noise.
    a_noise=rng.integers(-250,251,len(p),dtype=np.int16)
    p=np.clip(p.astype(np.int32)+a_noise,-32768,32767).astype(np.int16)
    f=features(p,adaptive_vad=True)
    writehex(OUT/'pcm.mem',p,16);writehex(OUT/'features.mem',f,8)
    adaptive_result=run('tb_kws_frontend',[RTL/'kws_goertzel.v',RTL/'aca_kws_frontend.v',ROOT/'tb_kws_frontend.v'],
        [f'-Ptb_kws_frontend.SAMPLES={len(p)}',f'-Ptb_kws_frontend.FEATURES={f.size}',
         '-Ptb_kws_frontend.ADAPTIVE_VAD=1'])
    (OUT/'tb_kws_frontend_adaptive.run.log').write_text(adaptive_result+'\n')
    c=json.loads((ROOT/'model/config.json').read_text())
    w=read_hex(ROOT/'model/weights.mem',8);bias=read_hex(ROOT/'model/bias.mem',32)
    stream=read_hex(ROOT/'model/test_inputs.mem',8)[:768*3].reshape(-1,16)[:128]
    writehex(OUT/'stream_inputs.mem',stream,8)
    windows=np.array([stream[i-48:i].ravel() for i in range(48,129,4)])
    stream_logits=integer_infer(windows,w[:768*48].reshape(48,768),bias[:48],
                               w[768*48:].reshape(3,48),bias[48:],c['shift'])
    writehex(OUT/'stream_logits.mem',stream_logits,32)
    # Golden feature windows are generated exclusively from held-out TTS voices.
    result2=run('tb_kws_engine',[RTL/'aca_kws_engine.v',ROOT/'tb_kws_engine.v'],
                [f"-Ptb_kws_engine.SHIFT={c['shift']}",f"-Ptb_kws_engine.MARGIN={c['margin']}"])
    chunks=[np.zeros((64,16),dtype=np.int8)]
    for stem in ['s005_p00_0','s005_p01_0','s005_p02_0','s011_p00_0','s011_p01_0','s011_p10_0']:
        chunks.extend([np.load(ROOT/'data'/(stem+'_'+FEATURE_VERSION+'.npz'))['f'],np.zeros((64,16),dtype=np.int8)])
    utterances=np.concatenate(chunks);ends=list(endpoints(utterances,robust=True))
    ewindows=np.concatenate([endpoint_windows(utterances,i) for i in ends])
    el=integer_infer(ewindows,w[:768*48].reshape(48,768),bias[:48],w[768*48:].reshape(3,48),bias[48:],c['shift'])
    fmap=np.full(len(utterances),0xffffffff,dtype=np.uint32)
    for i,end in enumerate(ends):fmap[end-1]=i
    writehex(OUT/'endpoint_inputs.mem',utterances,8);writehex(OUT/'endpoint_map.mem',fmap,32)
    vote=el.reshape(-1,3,3).argmax(axis=2)
    margins=np.diff(np.sort(el,axis=1)[:,-2:],axis=1).reshape(-1,3)
    accepted=np.where((vote==vote[:,0,None]).all(axis=1) & (margins>=c['margin']).all(axis=1),vote[:,0],0)
    writehex(OUT/'endpoint_logits.mem',el.reshape(-1,3,3)[:,-1],32)
    writehex(OUT/'endpoint_accept.mem',accepted,8)
    result3=run('tb_kws_endpoint',[RTL/'aca_kws_engine.v',ROOT/'tb_kws_endpoint.v'],
                [f'-Ptb_kws_endpoint.FRAMES={len(utterances)}',f'-Ptb_kws_endpoint.RESULTS={len(ends)}',
                 f"-Ptb_kws_endpoint.SHIFT={c['shift']}",f"-Ptb_kws_endpoint.MARGIN={c['margin']}"])
    (OUT/'rtl_results.json').write_text(json.dumps(dict(mel_powers=mel_result,frontend=result,adaptive_frontend=adaptive_result,integer_mlp=result2,endpoint=result3),indent=2))
    assert initial_sources==fingerprint(),'Voice verification sources changed while simulation was running'
    (OUT/'rtl_sources.json').write_text(json.dumps(initial_sources,indent=2))

if __name__=='__main__':main()
