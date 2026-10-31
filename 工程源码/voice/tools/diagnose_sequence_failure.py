"""Inspect why the preserved character CTC candidate rejects commands.

Measures information loss and transcript mismatches; makes no firmware changes.
"""
import os
os.environ.setdefault('OPENBLAS_NUM_THREADS','1')
import hashlib,json
from pathlib import Path
from collections import Counter
import numpy as np
import torch
import soundfile as sf
from train_character_ctc import Net,TOKENS,VOCAB,ROWS,WORDS,OUT,ROOT,batch,infer
from train_sequence_ctc import candidates
from kws_common import mel_powers,decimate

@torch.no_grad()
def emission_timeline(net, xs):
    output=[]
    for sample in xs:
        x,lens=batch([sample]);z=net(x)[0,:len(sample)].numpy()
        last=0;emissions=[]
        for t,k in enumerate(z.argmax(1)):
            if k and k!=last:
                emissions.append(dict(frame=t,token=TOKENS[k],feature_mean=float(sample[t].mean()),
                                      gap=float(z[t,k]-np.max(np.delete(z[t],k)))))
            last=k
        output.append(emissions)
    return output

@torch.no_grad()
def activations(net,xs):
    x,lens=batch(xs)
    h0=torch.clamp(net.front(x.transpose(1,2)),0,4)
    h1=net.mem1(h0);h2=net.mem2(h1);z=net.out(h2).transpose(1,2)
    output=[]
    for i,n in enumerate(lens):
        layers=[]
        for h in [h0,h1,h2]:
            a=h[i,:,:n].numpy()
            layers.append(dict(zero_fraction=float((a==0).mean()),ceiling_fraction=float((a==4).mean()),
                               mean_temporal_std=float(a.std(1).mean()),unique_frames=int(len(np.unique(a.T,axis=0)))))
        zz=z[i,:n].numpy();delta=zz[:,VOCAB['下']]-zz[:,VOCAB['上']]
        output.append(dict(frames=int(n),layers=layers,xia_minus_shang_min=float(delta.min()),
                           xia_minus_shang_max=float(delta.max()),
                           xia_minus_shang_std=float(delta.std()),
                           decoded=infer(net,[xs[i]])[0]))
    return output

def main():
    torch.set_num_threads(2)
    net=Net();net.load_state_dict(torch.load(OUT/'candidate.pt',weights_only=True));net.eval()
    ds=np.load(ROOT/'voice/experiments/sequence_ctc/dataset.npz');full=np.load(ROOT/'voice/experiments/acoustic_codes_v2/full_clips.npz')
    report={}
    for split in ['train','validation']:
        rows=[r for r in ROWS if r['split']==split]
        xs=np.split(ds[split+'_x'],np.cumsum(ds[split+'_lengths'])[:-1]);owners=ds[split+'_owners']
        lengths=ds[split+'_lengths'];old=np.split(ds[split+'_targets'],np.cumsum(ds[split+'_target_lengths'])[:-1])
        longest={}
        for i,o in enumerate(owners):
            if o not in longest or lengths[i]>lengths[longest[o]]:longest[o]=i
        counts=Counter()
        for i,o in enumerate(owners):
            r=rows[o//6];counts['candidates']+=1
            if r['label']:counts['command_candidates']+=1;counts['fragment_label_other']+=int(len(old[i])!=3)
            else:counts['negative_candidates']+=1;counts['negative_label_guessed_full_text']+=int(longest[o]==i)
        ids=[i for i,o in enumerate(owners) if rows[o//6]['label']]
        decoded=infer(net,[xs[i] for i in ids]);hits=Counter()
        for i,(c,g,text) in zip(ids,decoded):
            lab=rows[owners[i]//6]['label'];expected=WORDS[lab]
            hits['command_candidates']+=1;hits['exact_correct_text']+=int(text==expected)
            hits['missing_or_wrong_first_character']+=int(not text.startswith(expected[0]))
            hits['empty_text']+=int(not text)
        fxs=np.split(full[split+'_x'],np.cumsum(full[split+'_lengths'])[:-1]);fl=full[split+'_labels']
        fi=np.flatnonzero(fl!=0);fd=infer(net,[fxs[i] for i in fi]);full_correct=sum(c==fl[i] for i,(c,_,_) in zip(fi,fd))
        report[split]=dict(label_audit=dict(counts),candidate_text=dict(hits),
                            whole_clip_command_count=len(fi),whole_clip_exact_correct=int(full_correct))
    wav=ROOT/'verification/user_20261021_170604.wav';a,sr=sf.read(wav,dtype='int16');assert sr==48000
    clips=candidates(mel_powers(decimate(np.r_[np.zeros(98304,dtype=np.int16),a,np.zeros(73728,dtype=np.int16)])))
    report['real_development']=activations(net,[x for x,_,_,_ in clips])
    report['silence_emissions']={str(n):emission_timeline(net,[np.zeros((n,16),dtype=np.int8)])[0] for n in [15,40,80]}
    report['real_emission_timeline']=emission_timeline(net,[x for x,_,_,_ in clips])
    report['limits']=['Only two confirmed real utterances; reused development evidence.',
                      'Fragment labels use coverage or longest-fragment heuristics, not acoustic forced alignment.',
                      'Activation saturation can explain a failure without identifying its sole root cause.']
    report['sources']={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path(__file__),wav,OUT/'candidate.pt',ROOT/'voice/tools/train_character_ctc.py',ROOT/'voice/tools/train_sequence_ctc.py']}
    dest=ROOT/'voice/experiments/acoustic_codes_v2/previous_failure_diagnosis.json'
    dest.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf8')
    print(json.dumps({k:v for k,v in report.items() if k!='sources'},ensure_ascii=True,indent=2))

if __name__=='__main__':main()
