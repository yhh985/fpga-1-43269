"""Replay the preserved sensitive recognizer; do not change deployed firmware.

Verify its original ROM hashes, use its original preprocessor and endpoints,
then show what increasing a score margin can and cannot change.
"""
from pathlib import Path
import importlib.util,json,hashlib
import numpy as np
import soundfile as sf
from kws_common import read_hex

ROOT=Path(__file__).resolve().parents[2]
LEGACY=Path('E:/anlo_project/liantiao/verification/before_noise_fix_20261020')
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()

def main():
 release=json.loads((LEGACY/'deliverable/release_manifest.json').read_text(encoding='utf-8'))
 model=ROOT/'voice/model'
 for name in ['weights.mem','bias.mem']:
  assert sha(model/name)==release['model'][name],f'Original ROM changed: {name}'
 source=LEGACY/'voice/tools/kws_common.py'
 spec=importlib.util.spec_from_file_location('sensitive_reference',source)
 old=importlib.util.module_from_spec(spec);spec.loader.exec_module(old)
 wav=ROOT/'verification/user_20261021_170604.wav'
 annotation=ROOT/'verification/real_voice_transient.json'
 ann=json.loads(annotation.read_text());assert ann['real_direction_labels_confirmed'] and ann['spoken_classes']==[2,1]
 assert ann['sources']['verification\\user_20261021_170604.wav']==sha(wav)
 audio,sr=sf.read(wav,dtype='int16');assert sr==48000
 pcm=np.r_[np.zeros(98304,dtype=np.int16),audio,np.zeros(73728,dtype=np.int16)]
 f=old.features(pcm,adaptive_vad=True);ends=list(old.endpoints(f));assert len(ends)==2
 w=read_hex(model/'weights.mem',8);b=read_hex(model/'bias.mem',32)
 x=np.stack([f[e-48:e].ravel() for e in ends])
 z=old.integer_infer(x,w[:36864].reshape(48,768),b[:48],w[36864:].reshape(3,48),b[48:],9)
 winners=z.argmax(1);margins=np.diff(np.sort(z,axis=1)[:,-2:]).ravel()
 thresholds=[109,200,400,600,800,1000,1400]
 policies={str(t):np.where((winners!=0)&(margins>=t),winners,0).tolist() for t in thresholds}
 assert all(p[1]!=1 for p in policies.values()),'Unexpected NEXT recovery: examine the claim'
 result=dict(production_changed=False,original_rom_hash_verified=True,
  labels=[2,1],real_recording_used_for_training=False,software_replay_only=True,
  endpoint_frames=ends,logits=z.tolist(),winners=winners.tolist(),margins=margins.tolist(),
  threshold_predictions=policies,
  conclusion='Higher margins only reject existing winners; cannot change background into NEXT.',
  sources={str(p):sha(p) for p in [Path(__file__),source,LEGACY/'aca420/rtl/aca_kws_engine.v',
   LEGACY/'aca420/rtl/aca_kws_frontend.v',LEGACY/'deliverable/release_manifest.json',
   model/'weights.mem',model/'bias.mem',wav,annotation]})
 out=ROOT/'verification/legacy_threshold_replay.json'
 out.write_text(json.dumps(result,indent=2),encoding='utf-8')
 print(json.dumps({k:v for k,v in result.items() if k!='sources'},indent=2))

if __name__=='__main__':main()
