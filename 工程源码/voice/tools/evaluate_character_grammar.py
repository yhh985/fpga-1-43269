"""Integer-friendly CTC grammar: Viterbi paths, no softmax on hardware.

All twelve existing transcripts plus OTHER compete, including xia-yi-shou and
shang-yi-shou. Validation selects margins; the owner pair is replay only.
"""
import os
os.environ.setdefault('OPENBLAS_NUM_THREADS','1')
from pathlib import Path
import json
import numpy as np
import torch
import soundfile as sf
from train_character_ctc import Net, TOKENS, VOCAB, ROWS, WORDS, OUT, ROOT, batch, metrics

def path_scores(z, lengths):
    """Max-product CTC alignment for complete competing text sequences.

    Log-softmax is unnecessary: per-frame normalizers cancel between paths.
    Staying in a state supports different syllable durations. Skip transitions
    cannot skip a character or merge consecutive identical characters.
    """
    texts = sorted(set(row['text'] for row in ROWS)) + ['<other>', '']
    codes = [[VOCAB[c] for c in text] if text not in ['<other>',''] else
             [1] if text else [] for text in texts]
    states = max(2*len(c)+1 for c in codes)
    unit = np.zeros((len(texts), states), dtype=int)
    valid = np.zeros_like(unit, dtype=bool)
    skip = np.zeros_like(unit, dtype=bool)
    for i, code in enumerate(codes):
        unit[i, 1:2*len(code):2] = code
        valid[i,:2*len(code)+1] = True
        for j in range(2, 2*len(code)+1):
            skip[i,j] = unit[i,j] != 0 and unit[i,j] != unit[i,j-2]
    neg = -1.e20
    alpha = np.full((len(z),len(texts),states),neg,dtype=np.float32)
    alpha[:,:,0] = 0
    for t in range(z.shape[1]):
        one = np.full_like(alpha,neg);one[:,:,1:] = alpha[:,:,:-1]
        two = np.full_like(alpha,neg);two[:,:,2:] = alpha[:,:,:-2]
        two = np.where(skip[None],two,neg)
        next_alpha = np.maximum(np.maximum(alpha,one),two) + z[:,t,unit]
        next_alpha = np.where(valid[None],next_alpha,neg)
        alpha = np.where((t < lengths)[:,None,None],next_alpha,alpha)
    scores=[]
    for i,code in enumerate(codes):
        end=2*len(code)
        scores.append(np.maximum(alpha[:,i,end],alpha[:,i,max(0,end-1)]))
    return np.stack(scores,1),texts

@torch.no_grad()
def score(net,xs):
    out=[]
    for lo in range(0,len(xs),64):
        x,lens=batch(xs[lo:lo+64]);s,texts=path_scores(net(x).numpy(),lens.numpy());out.append(s)
    return np.concatenate(out),texts

def decisions(scores,texts):
    order=np.argsort(scores,axis=1)
    result=[]
    for s,indices in zip(scores,order):
        word=texts[indices[-1]]
        cls=next((c for c,w in WORDS.items() if w==word),0)
        result.append((cls,float(s[indices[-1]]-s[indices[-2]]),word))
    return result

def main():
    torch.set_num_threads(4)
    net=Net();net.load_state_dict(torch.load(OUT/'candidate.pt',weights_only=True));net.eval()
    ds=np.load(ROOT/'voice/experiments/sequence_ctc/dataset.npz')
    def get(name):
        xs=np.split(ds[name+'_x'],np.cumsum(ds[name+'_lengths'])[:-1])
        return xs,ds[name+'_owners'],ds[name+'_labels']
    vx,owners,labels=get('validation');scores,texts=score(net,vx);d=decisions(scores,texts)
    options=[]
    for margin in [0,.5,1,2,3,4,6,8,12,16,24,32]:
        m=metrics(labels,owners,d,margin)
        if m['false_accepts']<=8:
            options.append(((m['correct']-3*m['wrong_direction'],m['correct'],-m['false_accepts']),margin,m))
    rank,margin,selected=max(options,key=lambda x:x[0])
    report=dict(experimental_only=True,deployed=False,margin=margin,validation=selected,
                changes='Viterbi text-grammar search replaces greedy frame argmax',test_used_for_selection=False)
    for name in ['test']:
        x,o,y=get(name);s,t=score(net,x);report[name]=metrics(y,o,decisions(s,t),margin)
    from train_sequence_ctc import candidates,sha
    from kws_common import mel_powers,decimate
    wav=ROOT/'verification/user_20261021_170604.wav';a,sr=sf.read(wav,dtype='int16');assert sr==48000
    samples=candidates(mel_powers(decimate(np.r_[np.zeros(98304,dtype=np.int16),a,np.zeros(73728,dtype=np.int16)])))
    s,t=score(net,[x for x,_,_,_ in samples]);d=decisions(s,t)
    report['real_replay']=[dict(prediction=k if gap>=margin else 0,gap=gap,text=text,
                               command_scores={WORDS[c]:float(row[t.index(WORDS[c])]) for c in [1,2]})
                           for row,(k,gap,text) in zip(s,d)]
    report['sources']={str(p):sha(p) for p in [Path(__file__),OUT/'candidate.pt',wav]}
    (OUT/'grammar_report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf8')
    print(json.dumps(report,ensure_ascii=True,indent=2))

if __name__=='__main__':main()
