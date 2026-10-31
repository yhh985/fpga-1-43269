"""Integer reference for 48 kHz -> 8 kHz -> 63 Goertzel bins -> 16 Mel bands."""
import numpy as np
from scipy.signal import resample_poly

FS = 8000
FREQUENCIES = np.arange(1,64)*62.5
COEFF = np.rint(2*np.cos(2*np.pi*np.array(FREQUENCIES)/FS)*65536).astype(np.int64)
FRAMES, BANDS, HIDDEN = 48, 16, 48
INPUTS = FRAMES*BANDS
FEATURE_VERSION = 'mel63_q8_v3'
MEL_EDGES = 700*(10**(np.linspace(2595*np.log10(1+40/700),2595*np.log10(1+4000/700),18)/2595)-1)
MEL_WEIGHTS = np.rint(256*np.maximum(0,np.minimum(
    (FREQUENCIES[None,:]-MEL_EDGES[:-2,None])/(MEL_EDGES[1:-1,None]-MEL_EDGES[:-2,None]),
    (MEL_EDGES[2:,None]-FREQUENCIES[None,:])/(MEL_EDGES[2:,None]-MEL_EDGES[1:-1,None])))).astype(np.int64)

def pcm48(audio, sr):
    from math import gcd
    d = gcd(sr,48000)
    return np.clip(np.rint(resample_poly(audio,48000//d,sr//d)*32768),-32768,32767).astype(np.int16)

def decimate(pcm):
    p = np.asarray(pcm,dtype=np.int64)
    # Six-sample box filter, gain 6/8, matches the hardware exactly.
    return (p[:len(p)//6*6].reshape(-1,6).sum(axis=1)>>3).astype(np.int16)

def powers(pcm8):
    n = len(pcm8)//128
    x = np.asarray(pcm8[:n*128],dtype=np.int64).reshape(n,128)
    s1 = np.zeros((n,len(COEFF)),dtype=np.int64); s2=s1.copy()
    for k in range(128):
        s = x[:,k,None]+((s1*COEFF)>>16)-s2
        if np.any(s>2**30-1) or np.any(s<-(2**30)):
            raise OverflowError('Goertzel recurrence clipping')
        s2,s1=s1,s
    p = np.maximum(0,(s1*s1+s2*s2-((s1*COEFF)>>16)*s2)>>17)
    return np.minimum(p,2**32-1).astype(np.uint32)

def log4(p):
    p = np.asarray(p,dtype=np.uint32)
    result = np.zeros(p.shape,dtype=np.int16)
    for k in range(32):
        # 4*floor(log2(p)) plus the following two mantissa bits.
        frac = ((p >> max(k-2,0)) & 3) if k>=2 else ((p<< (2-k)) & 3)
        result = np.where(p >= (1<<k), k*4+frac, result)
    return result

def mel_powers(pcm8):
    bins = powers(pcm8).astype(np.int64)
    # Match the shared signed hardware multiplier: discard one low bit first.
    return np.minimum(((bins>>1)@MEL_WEIGHTS.T)>>7,2**32-1).astype(np.uint32)

def features(pcm, adaptive_vad=False, vad_hysteresis=False):
    p = mel_powers(decimate(pcm))
    l = log4(p)
    f = np.maximum(-64,l-l.max(axis=1,keepdims=True)).astype(np.int16)
    f[p.max(axis=1)<512] = -64
    if adaptive_vad:
        noise_q=0
        calibration=0
        active_run=0
        continuity=False
        band_noise=np.zeros(16,dtype=np.int64)
        for i,row in enumerate(l):
            maximum=int(row.max())
            active=bool(p[i].max()>=512 and maximum>(noise_q>>3)+8 and
                        np.count_nonzero(row.astype(np.int64)>(band_noise>>3)+8)>=3)
            if vad_hysteresis and continuity:
                active |= bool(p[i].max()>=512 and maximum>(noise_q>>3)+4 and
                               np.count_nonzero(row.astype(np.int64)>(band_noise>>3)+4)>=2)
            speech=calibration==16 and active
            if calibration<16:
                calibration+=1
                noise_q=maximum*8 if calibration==1 else noise_q-(noise_q>>3)+maximum
            elif not active or active_run==127:
                noise_q=noise_q-(noise_q>>3)+maximum
            active_run=min(127,active_run+1) if active else 0
            continuity=calibration==16 and active
            if calibration==1:band_noise=row.astype(np.int64)*8
            elif calibration<16 or not speech or active_run==127:
                band_noise=band_noise-(band_noise>>3)+row
            if not speech:
                f[i]=-64
    # Two non-overlapping 16 ms frames averaged, then a 1.536 s history.
    n = len(f)//2
    return (((f[:n*2:2]+f[1:n*2:2])>>1)+64).astype(np.int8)

def integer_infer(x, w1,b1,w2,b2,shift):
    h=np.clip((np.asarray(x,dtype=np.int64)@w1.T+b1)>>shift,0,127)
    return h@w2.T+b2

def endpoints(f, robust=False, prequiet_frames=8, transient_credit=True):
    """Six quiet 32 ms frames terminate an utterance; ignore long conversation."""
    quiet=0;voiced=0;duration=0;running=False;quiet_run=0;allowed=False
    for i,row in enumerate(f):
        active=bool(np.any(row))
        if active:
            if not running:allowed=quiet_run>=prequiet_frames
            quiet_run=0
            running=True;quiet=0;voiced=min(127,voiced+1)
        else:quiet_run=min(15,quiet_run+1)
        if running:
            duration=min(127,duration+1)
            if not active:
                quiet+=1
                if quiet==6:
                    if voiced>=6 and duration<=64 and i>=47 and (not robust or allowed):yield i+1
                    if transient_credit and voiced<6 and allowed:
                        quiet_run=max(quiet_run,prequiet_frames)
                    running=False;quiet=0;voiced=0;duration=0

def endpoint_windows(f,end,passes=3):
    """Match independent utterance masking and adjacent endpoint alignment."""
    start=end-6
    while start>0:
        # Six quiet frames delimit the previous utterance.
        if start>=6 and not np.any(f[start-6:start]):break
        start-=1
    windows=[]
    for offset in range(passes-1,-1,-1):
        stop=end-offset
        window=np.zeros((48,16),dtype=np.int8)
        source=f[max(0,stop-48):stop]
        window[48-len(source):]=source
        window[:max(0,start-(stop-48))]=0
        windows.append(window.ravel())
    return np.array(windows)

def read_hex(path,bits):
    a=np.array([int(s,16) for s in path.read_text().split()],dtype=np.int64)
    return np.where(a>=2**(bits-1),a-2**bits,a)
