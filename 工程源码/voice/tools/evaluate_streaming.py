"""Report first accepted command per continuous recording, including wrong direction.
Can evaluate a JSON manifest of independent REAL recordings via --manifest PATH.
Each row: path (relative to manifest dir), label 0/1/2, speaker, synthetic false.
"""
import argparse,hashlib,json
from pathlib import Path
import numpy as np
import soundfile as sf
from kws_common import *

ROOT=Path(__file__).resolve().parents[1]

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--manifest',type=Path)
    ap.add_argument('--split',choices=['validation','test'],default='test')
    ap.add_argument('--model-dir',type=Path,default=ROOT/'model')
    ap.add_argument('--output',type=Path)
    ap.add_argument('--adaptive-vad',action='store_true')
    ap.add_argument('--noise-amplitude',type=int,default=0,help='Uniform PCM16 background amplitude, with fixed seed')
    args=ap.parse_args()
    manifest=args.manifest or ROOT/'data/manifest.json'
    rows=json.loads(manifest.read_text(encoding='utf8'))
    base=manifest.parent if args.manifest else ROOT
    if not args.manifest:rows=[r for r in rows if r['split']==args.split]
    cfg=json.loads((args.model_dir/'config.json').read_text())
    assert cfg['feature_version']==FEATURE_VERSION,'Model/frontend feature version mismatch'
    w=read_hex(args.model_dir/'weights.mem',8);b=read_hex(args.model_dir/'bias.mem',32)
    cm=np.zeros((3,3),dtype=int);details=[]
    rng=np.random.default_rng(20261020)
    for row in rows:
        a,sr=sf.read(base/row['path'])
        if a.ndim==2:a=a.mean(axis=1)
        pcm=pcm48(a,sr)
        if args.adaptive_vad:
            pcm=np.concatenate([np.zeros(49152,dtype=np.int16),pcm,np.zeros(73728,dtype=np.int16)])
            if args.noise_amplitude:
                pcm=np.clip(pcm.astype(np.int32)+rng.integers(-args.noise_amplitude,args.noise_amplitude+1,len(pcm)),-32768,32767).astype(np.int16)
        f=features(pcm,adaptive_vad=args.adaptive_vad)
        # 1 second of quiet before and after, as after entering voice mode.
        if not args.adaptive_vad:
            f=np.concatenate([np.zeros((32,16),dtype=np.int8),f,np.zeros((48,16),dtype=np.int8)])
        ends=list(endpoints(f,robust=args.adaptive_vad))
        windows=(np.concatenate([endpoint_windows(f,i) for i in ends]) if ends else np.zeros((0,768))) if args.adaptive_vad else np.array([f[i-48:i].ravel() for i in ends]).reshape(-1,768)
        logits=integer_infer(windows,w[:768*48].reshape(48,768),b[:48],w[768*48:].reshape(3,48),b[48:],cfg['shift'])
        pred=0;frame=None
        if args.adaptive_vad:
            batches=logits.reshape(-1,3,3)
            winners=batches.argmax(axis=2)
            margins=np.diff(np.sort(batches,axis=2)[:,:,-2:],axis=2)[:,:,0]
            consensus=(winners==winners[:,0,None]).all(axis=1) & (margins>=cfg['margin']).all(axis=1)
            logits=batches[:,-1].copy()
            logits[~consensus]=0
        for i,z in enumerate(logits):
            best=int(z.argmax());sort=np.sort(z)
            if best and sort[-1]-sort[-2]>=cfg['margin']:
                pred=best;frame=ends[i];break
        cm[row['label'],pred]+=1
        details.append(dict(path=row['path'],speaker=row['speaker'],label=row['label'],predicted=pred,frame=frame))
    synthetic=any(r.get('synthetic',True) for r in rows)
    report=dict(synthetic_only=synthetic,labels=['reject','next','previous'],confusion=cm.tolist(),
                weight_sha256=hashlib.sha256((args.model_dir/'weights.mem').read_bytes()).hexdigest(),
                feature_version=FEATURE_VERSION,
                reference_sha256=hashlib.sha256((ROOT/'tools/kws_common.py').read_bytes()).hexdigest(),
                frontend_sha256=hashlib.sha256((ROOT.parent/'aca420/rtl/aca_kws_frontend.v').read_bytes()).hexdigest(),
                adaptive_vad=args.adaptive_vad,noise_amplitude=args.noise_amplitude,
                clips=len(rows),correct=int(np.trace(cm)),details=details,
                command_correct=int(cm[1,1]+cm[2,2]),command_count=int(cm[1:].sum()),
                wrong_direction=int(cm[1,2]+cm[2,1]),false_accepts=int(cm[0,1:].sum()),
                note='First accepted command per clip, NOT an hours-long false-alarm-rate measurement.')
    out=args.output or ROOT/'verification'/('real_recordings.json' if args.manifest else
                    'streaming_tts.json' if args.split=='test' else 'streaming_validation.json')
    out.write_text(json.dumps(report,indent=2),encoding='utf8')
    print(json.dumps({k:v for k,v in report.items() if k!='details'},indent=2))

if __name__=='__main__':main()
