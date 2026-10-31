"""Replay saved audio through the integer frontend and experimental float model.

This is algorithm simulation, NOT an RTL, quantization or board acceptance test.
The two confirmed owner utterances are reused development cases only.
"""
import os
os.environ.setdefault('OPENBLAS_NUM_THREADS','1')
import argparse, copy, hashlib, json, shutil, subprocess
from pathlib import Path
import numpy as np
import torch
import soundfile as sf
from train_masked_acoustic_codes import ROOT,OUT,Net,infer,batch,base
from train_sequence_ctc import candidates,raw_features
from kws_common import mel_powers,decimate

@torch.no_grad()
def structural(net):
    rng=np.random.default_rng(2631)
    samples=[rng.integers(0,65,(n,16),dtype=np.int8) for n in [19,35,72]]
    net.eval();x,lens=batch(samples);z,_=net(x,lens)
    single_error=0.;shift_error=0.
    for i,sample in enumerate(samples):
        a,l=batch([sample]);zz,_=net(a,l)
        single_error=max(single_error,float((z[i,:len(sample)]-zz[0]).abs().max()))
        variants=[np.pad(sample,((n,0),(0,0))) for n in [0,3,6,12]]
        a,l=batch(variants);zz,_=net(a,l)
        for j,n in enumerate([0,3,6,12]):
            shift_error=max(shift_error,float((zz[j,n:n+len(sample)]-z[i,:len(sample)]).abs().max()))
    corrupt=x.clone()
    for i,n in enumerate(lens):corrupt[i,n:]=37.
    zc,_=net(corrupt,lens)
    corrupt_error=max(float((zc[i,:n]-z[i,:n]).abs().max()) for i,n in enumerate(lens))
    # Statistics and valid logits in train mode must ignore arbitrary padding.
    a=copy.deepcopy(net).train();b=copy.deepcopy(net).train()
    za,_=a(x,lens);zb,_=b(torch.nn.functional.pad(corrupt,(0,0,0,17),value=91.),lens)
    train_error=max(float((za[i,:n]-zb[i,:n]).abs().max()) for i,n in enumerate(lens))
    errors=dict(batch_single_max_error=single_error,leading_silence_shift_max_error=shift_error,
                invalid_padding_max_error=corrupt_error,training_padding_max_error=train_error)
    # CPU float32 convolution can change accumulation order with batch shape.
    # Trained logits have larger magnitude than the random initialization.
    errors['passed']=all(v<1e-4 for v in errors.values())
    errors['float32_absolute_tolerance']=1e-4
    assert errors['passed'],errors
    return errors

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--structural-only',action='store_true')
    ap.add_argument('--version',choices=['v4','v5','v6','v5v6'],default='v4')
    ap.add_argument('--tempo-consensus',action='store_true')
    ap.add_argument('--waveform-tempo',action='store_true');a=ap.parse_args()
    if a.tempo_consensus:assert a.version in ['v5','v6','v5v6']
    if a.version=='v5v6':assert a.tempo_consensus
    folder=ROOT/('voice/experiments/acoustic_codes_'+a.version)
    torch.set_num_threads(2);torch.manual_seed(2640);net=Net()
    if not a.structural_only:
        if a.version=='v5v6':
            from evaluate_model_consensus import load_models,score_models,CHECKPOINTS
            models=load_models();net=models[0]
        else:net.load_state_dict(torch.load(folder/'candidate.pt',weights_only=True))
    net.eval();report={'algorithm_simulation_only':True,'fpga_deployed':False,'structural':structural(net)}
    if a.structural_only:
        print(json.dumps(report,indent=2));return
    if a.version=='v5v6':report['second_model_structural']=structural(models[1])
    selected_path=folder/('tempo_selected.json' if a.tempo_consensus else 'selected.json')
    selected=json.loads(selected_path.read_text());margin=selected['margin']
    report['selected_margin']=margin
    wav=ROOT/'verification/user_20261021_170604.wav';audio,sr=sf.read(wav,dtype='int16');assert sr==48000
    report['limits']=['Only two confirmed reused real utterances, not independent accuracy.',
                      'Noise is simulated; does not reproduce all electrical interference.',
                      'Feature-time resampling tests tempo tolerance, not full waveform time stretching.',
                      'No RTL simulation, integer network quantization, or measured hardware latency.']
    padded=np.r_[np.zeros(98304,dtype=np.int16),audio,np.zeros(73728,dtype=np.int16)]
    clean=candidates(mel_powers(decimate(padded)));assert len(clean)==2
    report['real_scenarios']=[];rng=np.random.default_rng(2640)
    def result(xs):
        if xs and a.version in ['v5','v6','v5v6']:
            from train_directional_ctc import scores,decisions
            if a.version=='v5v6':s=score_models(models,xs)
            elif a.tempo_consensus:
                from evaluate_tempo_consensus import score_views
                s=score_views(net,xs)
            else:s=scores(net,xs)
            decoded=decisions(s,[len(x) for x in xs],margin,selected['floor'])
            return [dict(command=c,text=t,gap=g) for c,g,t in decoded]
        return [dict(command=c if g>=margin else 0,text=t,gap=g) for c,g,t in infer(net,xs)] if xs else []
    for name,pcm in [('original',padded),('quarter_gain',(padded.astype(np.int64)//4).astype(np.int16))]:
        clips=candidates(mel_powers(decimate(pcm)))
        report['real_scenarios'].append(dict(name=name,expected=[2,1],results=result([x for x,_,_,_ in clips])))
    power=float(np.mean(audio.astype(float)**2))
    for snr in [20,10,6]:
        noisy=np.clip(padded.astype(float)+rng.normal(0,np.sqrt(power/10**(snr/10)),len(padded)),-32768,32767).astype(np.int16)
        clips=candidates(mel_powers(decimate(noisy)))
        report['real_scenarios'].append(dict(name=f'white_noise_{snr}dB',expected=[2,1],results=result([x for x,_,_,_ in clips])))
    if a.waveform_tempo:
        ffmpeg=shutil.which('ffmpeg')
        if not ffmpeg:raise RuntimeError('--waveform-tempo requires ffmpeg; do not silently skip this test')
        report['waveform_tempo_tool']=subprocess.check_output([ffmpeg,'-version'],text=True).splitlines()[0]
        report['waveform_tempo_note']='FFmpeg atempo pitch-preserving waveform transform; still not newly recorded speech.'
        for rate in [.75,1.3]:
            transformed=subprocess.run([ffmpeg,'-v','error','-f','s16le','-ar','48000','-ac','1','-i','pipe:0',
                '-af',f'atempo={rate}','-f','s16le','pipe:1'],input=audio.astype('<i2').tobytes(),capture_output=True,check=True)
            pcm=np.r_[np.zeros(98304,dtype=np.int16),np.frombuffer(transformed.stdout,dtype='<i2'),np.zeros(73728,dtype=np.int16)]
            clips=candidates(mel_powers(decimate(pcm)))
            report['real_scenarios'].append(dict(name=f'waveform_atempo_{rate}',expected=[2,1],results=result([x for x,_,_,_ in clips])))
    report['feature_replays']=[]
    for i,(x,_,s,e) in enumerate(clean):
        variants=[];names=[]
        for lead in [0,3,6,12]:
            variants.append(np.pad(x,((lead,0),(0,0))));names.append(f'lead_{lead}')
        for rate in [.75,1.3]:
            pos=np.arange(max(3,round(len(x)/rate)))*rate
            variants.append(np.rint(np.stack([np.interp(pos,np.arange(len(x)),x[:,j]) for j in range(16)],1)).astype(np.int8))
            names.append(f'feature_tempo_{rate}')
        report['feature_replays'].append(dict(expected=[2,1][i],names=names,results=result(variants)))
    report['real_batch_single']={'batch':result([x for x,_,_,_ in clean]),
                                 'single':[result([x])[0] for x,_,_,_ in clean]}
    quiet=[np.zeros((n,16),dtype=np.int8) for n in [15,40,80,150]]
    quiet += [np.clip(rng.normal(0,.7,(n,16)),0,64).astype(np.int8) for n in [15,40,80,150]]
    report['silence_feature_results']=result(quiet)
    negatives=[]
    for name in ['zero','white','hum','clicks']:
        t=np.arange(48000*10)/48000
        signal=np.zeros(len(t))
        if name=='white':signal=rng.normal(0,500,len(t))
        if name=='hum':signal=700*np.sin(2*np.pi*120*t)+250*np.sin(2*np.pi*240*t)
        if name=='clicks':
            for start in range(60000,len(t),96000):signal[start:start+96]=12000
        pcm=np.clip(signal,-32768,32767).astype(np.int16)
        powers=mel_powers(decimate(pcm));clips=candidates(powers);r=result([x for x,_,_,_ in clips])
        # Also bypass VAD, so zero candidates cannot hide a weak acoustic model.
        raw=raw_features(powers)
        forced=result([raw[i:i+64] for i in range(0,len(raw)-63,32)])
        negatives.append(dict(name=name,seconds=10,candidates=len(clips),accepted=sum(x['command']!=0 for x in r),results=r,
                              forced_windows=len(forced),forced_accepts=sum(x['command']!=0 for x in forced)))
    report['negative_audio']=negatives
    original=report['real_scenarios'][0]['results']
    report['checks']={
        'original_both_commands_correct':[r['command'] for r in original]==[2,1],
        'batch_single_commands_equal':report['real_batch_single']['batch']==report['real_batch_single']['single'],
        'quiet_has_no_characters':all(not r['text'] for r in report['silence_feature_results']),
        'negative_audio_has_no_commands':all(r['accepted']==0 for r in negatives),
        'forced_noise_windows_have_no_commands':all(r['forced_accepts']==0 for r in negatives),
        'all_audio_stress_pairs_correct':all([r['command'] for r in case['results']]==case['expected'] for case in report['real_scenarios']),
    }
    report['checks']['batch_single_commands_equal']=all(
        a['command']==b['command'] and a['text']==b['text']
        for a,b in zip(report['real_batch_single']['batch'],report['real_batch_single']['single']))
    metricpath=folder/('tempo_report.json' if a.tempo_consensus else 'report.json')
    metrics=json.loads(metricpath.read_text())
    report['synthetic_stream']=dict(validation=metrics['selected']['validation'],test=metrics['test']) if a.tempo_consensus else metrics['results']
    deps=[Path(__file__),wav,metricpath,selected_path]
    if a.version=='v5v6':deps.extend([*CHECKPOINTS,ROOT/'voice/tools/evaluate_model_consensus.py'])
    else:deps.append(folder/'candidate.pt')
    if a.version in ['v5','v6']:deps.append(ROOT/('voice/tools/train_noise_directional_ctc.py' if a.version=='v6' else 'voice/tools/train_directional_ctc.py'))
    if a.tempo_consensus:deps.append(ROOT/'voice/tools/evaluate_tempo_consensus.py')
    report['sources']={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in deps}
    report['version']=a.version
    report['tempo_consensus']=a.tempo_consensus
    suffix='_tempo' if a.tempo_consensus else ''
    if a.waveform_tempo:suffix+='_waveform'
    dest=ROOT/f'verification/acoustic_codes_{a.version}{suffix}_simulation.json'
    dest.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf8')
    print(json.dumps(report,ensure_ascii=True,indent=2))

if __name__=='__main__':main()
