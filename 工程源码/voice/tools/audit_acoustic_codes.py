"""Development-only silence and time-origin audit; no model selection here."""
import json, hashlib
from pathlib import Path
import numpy as np
import torch
import soundfile as sf
from train_acoustic_codes import ROOT,Net,infer
from train_sequence_ctc import candidates
from kws_common import mel_powers,decimate

def main():
    torch.set_num_threads(2)
    wav=ROOT/'verification/user_20261021_170604.wav'
    audio,sr=sf.read(wav,dtype='int16');assert sr==48000
    clips=candidates(mel_powers(decimate(np.r_[np.zeros(98304,dtype=np.int16),audio,np.zeros(73728,dtype=np.int16)])))
    rng=np.random.default_rng(20261026)
    report={'warning':'Reused two real development utterances, not an independent accuracy estimate.', 'expected':[2,1], 'models':{}}
    for version in ['v2','v3']:
        folder=ROOT/('voice/experiments/acoustic_codes_'+version)
        net=Net();net.load_state_dict(torch.load(folder/'candidate.pt',weights_only=True));net.eval()
        quiet=[np.zeros((n,16),dtype=np.int8) for n in [15,40,80]]
        quiet += [np.clip(rng.normal(0,.7,(n,16)),0,64).astype(np.int8) for n in [15,40,80]]
        rows=[]
        for x,_,s,e in clips:
            variants=[np.pad(x,((n,0),(0,0))) for n in [0,3,6,12]]
            rows.append({'start':s,'end':e,'lead_frames':[0,3,6,12],'decoded':infer(net,variants)})
        report['models'][version]={'quiet_decoded':infer(net,quiet),'real_shifts':rows,
                                  'real_batched':infer(net,[x for x,_,_,_ in clips]),
                                  'real_individually':[infer(net,[x])[0] for x,_,_,_ in clips],
                                  'checkpoint_sha256':hashlib.sha256((folder/'candidate.pt').read_bytes()).hexdigest()}
    report['audit_source_sha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    (ROOT/'verification/acoustic_codes_audit.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf8')
    print(json.dumps(report,ensure_ascii=True,indent=2))

if __name__=='__main__':main()
