"""Read the CRC16 protected on-board features and actual per-pass logits."""
from pathlib import Path
import argparse,binascii,json,hashlib
import numpy as np
REASONS=['short_voiced_span','utterance_too_long','prequiet_not_earned','history_not_ready',
         'model_background','model_low_margin','model_direction_disagreement','command_cooldown']
def packets(raw):
    valid=[];bad=0;offset=0
    while True:
        p=raw.find(b'\xa5\x5a\x52',offset)
        if p<0 or p+74>len(raw):break
        block=raw[p:p+74]
        if binascii.crc_hqx(block[:72],0xffff)!=int.from_bytes(block[72:74],'little'):
            bad+=1;offset=p+1;continue
        valid.append(block);offset=p+74
    return valid,bad
def decode(raw, passes=3):
    if passes not in (1,3):raise ValueError('passes must be 1 or 3')
    blocks,bad=packets(raw);features=[];frames=[];attempts={};gaps=[];last=None
    for b in blocks:
        frame=int.from_bytes(b[3:5],'little');seq=int.from_bytes(b[9:11],'little')
        if last is not None and frame!=(last+1)&65535:gaps.append([last,frame])
        last=frame;frames.append(frame);features.append(list(b[12:28]))
        if seq and not b[11]&8:
            z=np.frombuffer(b[28:64],dtype='<i4').reshape(3,3)[:passes]
            attempts[seq]=dict(sequence=seq,voiced_frames=b[7],duration_frames=b[8],flags=b[6],
                reasons=[r for i,r in enumerate(REASONS) if b[6]&(1<<i)],logits=z.tolist(),
                winners=z.argmax(1).tolist(),margins=(np.sort(z,axis=1)[:,-1]-np.sort(z,axis=1)[:,-2]).tolist())
    return dict(valid_packets=len(blocks),crc_errors=bad,frame_gaps=gaps,overrun=any(b[71]&1 for b in blocks),
                frames=frames,attempts=list(attempts.values())),np.array(features,dtype=np.int8).reshape(-1,16)
def main():
    ap=argparse.ArgumentParser();ap.add_argument('capture',type=Path)
    ap.add_argument('--passes',type=int,choices=[1,3],default=3);args=ap.parse_args()
    report,f=decode(args.capture.read_bytes(),passes=args.passes)
    report['raw_sha256']=hashlib.sha256(args.capture.read_bytes()).hexdigest()
    report['active_frames']=int(np.any(f,axis=1).sum())
    report['feature_file']=str(args.capture.with_suffix('.features.npy'))
    np.save(args.capture.with_suffix('.features.npy'),f)
    args.capture.with_suffix('.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf8')
    print(json.dumps({k:v for k,v in report.items() if k!='frames'},ensure_ascii=False,indent=2))
    if not len(f):raise SystemExit('No voice feature packets: enter voice mode and use the capture firmware. Legacy packets are not KWS features.')
if __name__=='__main__':main()
