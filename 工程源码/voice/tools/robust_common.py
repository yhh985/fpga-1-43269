"""Whole-utterance, integer nearest-frame resampling for variable speaking rates.

The three views fill 38/40/42 frames of a 48-frame window, with six quiet
frames at the end. Reject policy remains unanimous non-background predictions.
"""
import numpy as np

def utterances(f, max_frames=96, prequiet=8):
    quiet_run=0;start=None;quiet=0;voiced=0;allowed=False
    for i,row in enumerate(f):
        active=bool(np.any(row))
        if active:
            if start is None:start=i;allowed=quiet_run>=prequiet
            quiet_run=0;quiet=0;voiced+=1
        else:
            quiet_run=min(15,quiet_run+1)
            if start is not None:quiet+=1
        if start is not None and quiet==6:
            duration=i-start+1
            if allowed and voiced>=6 and duration<=max_frames and i>=47:
                yield start,i+1
            if allowed and voiced<6:quiet_run=max(quiet_run,prequiet)
            start=None;quiet=0;voiced=0

def normalized_windows(f,start,end):
    speech=f[start:end-6]
    assert 0<len(speech)<=90
    out=np.zeros((3,48,16),dtype=np.int8)
    for p,target in enumerate([38,40,42]):
        # Constant-divisor arithmetic and exact truncation, reproducible in RTL.
        indices=np.arange(target)*len(speech)//target
        out[p,42-target:42]=speech[indices]
    return out.reshape(3,768)

def decisions(logits,margin,relaxed_margin=0,relaxed_total=0):
    winners=logits.argmax(-1)
    gaps=np.diff(np.sort(logits,axis=-1)[...,-2:],axis=-1)[...,0]
    threshold=(gaps>=margin).all(-1)
    if relaxed_margin>0:
        threshold|=(gaps>=relaxed_margin).all(-1)&(gaps.sum(-1)>=relaxed_total)
    return np.where((winners==winners[...,:1]).all(-1)&threshold,winners[...,0],0)
