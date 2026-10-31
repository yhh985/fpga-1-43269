"""Render actual HDL DSP outputs and compare every sample with a reference."""
from pathlib import Path
import hashlib,json,math,struct,subprocess,wave

r=Path(__file__).resolve().parents[1];out=r/'verification';out.mkdir(exist_ok=True)
audition=out/'effect_audio';audition.mkdir(exist_ok=True)
count=96000;frames=[]
for i in range(count):
    # Sparse musical chords leave gaps in which the delayed wet audio is audible.
    t=i/48000;gate=1 if i%24000<12000 else 0
    l=int(gate*(8500*math.sin(2*math.pi*440*t)+3500*math.sin(2*math.pi*6500*t)))
    rr=int(gate*(7500*math.sin(2*math.pi*660*t)+3000*math.sin(2*math.pi*8000*t)))
    frames.append((l,rr))
(out/'dsp_input.mem').write_text(''.join(f'{(rr&65535):04x}{(l&65535):04x}\n' for l,rr in frames))
iver=r/'tools/iverilog/app/bin/iverilog.exe'
subprocess.run([str(iver),'-g2012','-s','tb_effect_render','-o',str(out/'tb_effect_render.vvp'),
                'common/music_fx_return.v','sim/tb_effect_render.v'],cwd=r,check=True)
cp=subprocess.run([str(iver.with_name('vvp.exe')),str(out/'tb_effect_render.vvp')],
                  cwd=r,capture_output=True,text=True,timeout=120)
(out/'tb_effect_render.run.log').write_text(cp.stdout+cp.stderr)
assert cp.returncode==0 and 'PASS rendered' in cp.stdout,cp.stdout+cp.stderr
rows=[list(map(int,line.split())) for line in (out/'dsp_output.txt').read_text().splitlines()]
assert len(rows)==count
history=[0,0];wet=[0]*4096;audio=[[],[],[],[]];echo_tail=0
for i,((l,rr),row) in enumerate(zip(frames,rows)):
    delayed=wet[i%4096] if i>=4096 else 0
    wet[i%4096]=(l+rr)>>1
    for ch,sample in enumerate((l,rr)):
        history[ch]+=((sample<<4)-history[ch])>>3
        expected=[sample>>2,((sample>>1)+(delayed>>1))>>2,
                  history[ch]>>6,(sample if i%9600<4800 else sample>>2)>>2]
        got=row[ch*4:ch*4+4]
        assert got==expected,(i,ch,got,expected)
        for mode,value in enumerate(got):audio[mode].append(value)
        if sample==0 and got[1]!=0:echo_tail+=1
names=['00_original','01_echo','02_lowpass','03_tremolo']
for name,samples in zip(names,audio):
    with wave.open(str(audition/(name+'.wav')),'wb') as w:
        w.setparams((2,2,48000,0,'NONE','not compressed'))
        w.writeframes(struct.pack('<'+'h'*len(samples),*samples))
assert echo_tail>1000
report=dict(passed=True,stereo_frames=count,exact_sample_comparisons=count*2*4,
            echo_samples_in_dry_silence=echo_tail,dsp_simulation_only=True,
            sources={p:hashlib.sha256((r/p).read_bytes()).hexdigest()
                     for p in ['common/music_fx_return.v','sim/tb_effect_render.v','sim/render_effect_audio.py']},
            audio={name+'.wav':hashlib.sha256((audition/(name+'.wav')).read_bytes()).hexdigest() for name in names})
(out/'effect_render.json').write_text(json.dumps(report,indent=2))
print('PASS actual HDL effect audio:',report['exact_sample_comparisons'],'exact comparisons;',echo_tail,'echo tail samples',flush=True)
