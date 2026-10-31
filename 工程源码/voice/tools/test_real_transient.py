"""Replay real-recording features and boundary controls through actual KWS RTL.

The user confirmed the order previous/next. Only the first phrase is recovered;
the second remains rejected by prequiet. No training or model changes occur.
"""
from pathlib import Path
import hashlib,json,subprocess
import numpy as np
import soundfile as sf
from kws_common import features,endpoints,endpoint_windows,integer_infer,read_hex

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'verification'

def main():
    audio,sr=sf.read(OUT/'user_20261021_170604.wav',dtype='int16')
    assert sr==48000
    cfg=json.loads((ROOT/'voice/model/config.json').read_text())
    w=read_hex(ROOT/'voice/model/weights.mem',8);b=read_hex(ROOT/'voice/model/bias.mem',32)
    quiet=lambda n:np.zeros((n,16),dtype=np.int8)
    active=lambda n:np.full((n,16),20,dtype=np.int8)
    cases={}
    for pad in [0,49152]:
        pcm=np.concatenate([np.zeros(pad,dtype=np.int16),audio,np.zeros(73728,dtype=np.int16)])
        cases['real_pad_'+str(pad)]=features(pcm,adaptive_vad=True)
    # Qualified transient is ignored; an unqualified one cannot create credit.
    cases['boundary_controls']=np.concatenate([
        quiet(64),active(1),quiet(6),active(10),quiet(64),
        active(10),quiet(6),active(10),quiet(64),
        active(10),quiet(6),active(1),quiet(6),active(10),quiet(64),
        active(6),quiet(6),active(10),quiet(64)])
    records={}
    def write(name,a,bits):
        (OUT/name).write_text(''.join(f'{int(x)&((1<<bits)-1):0{bits//4}x}\n' for x in np.asarray(a).ravel()))
    for name,f in cases.items():
        ends=list(endpoints(f,robust=True));old=list(endpoints(f,robust=True,transient_credit=False))
        assert ends
        if name=='boundary_controls':assert len(ends)==4 and len(old)==3,(ends,old)
        windows=np.concatenate([endpoint_windows(f,e) for e in ends])
        z=integer_infer(windows,w[:36864].reshape(48,768),b[:48],w[36864:].reshape(3,48),b[48:],cfg['shift']).reshape(-1,3,3)
        winners=z.argmax(2);margins=np.diff(np.sort(z,axis=2)[:,:,-2:],axis=2)[:,:,0]
        accepted=np.where((winners==winners[:,0,None]).all(1)&(margins>=cfg['margin']).all(1),winners[:,0],0)
        mapping=np.full(len(f),0xffffffff,dtype=np.uint32)
        for i,e in enumerate(ends):mapping[e-1]=i
        write('transient_inputs.mem',f,8);write('transient_map.mem',mapping,32)
        write('transient_logits.mem',z[:,-1],32);write('transient_class.mem',accepted,8)
        iver=ROOT/'tools/iverilog/app/bin/iverilog.exe';binary=OUT/'tb_voice_transient.vvp'
        command=[str(iver),'-g2012','-s','tb_voice_transient',f'-Ptb_voice_transient.FRAMES={len(f)}',
                 f'-Ptb_voice_transient.RESULTS={len(ends)}','-o',str(binary),
                 str(ROOT/'aca420/rtl/aca_kws_engine.v'),str(ROOT/'sim/tb_voice_transient.v')]
        cp=subprocess.run(command,cwd=ROOT,capture_output=True,text=True)
        assert cp.returncode==0,cp.stderr
        run=subprocess.run([str(iver.with_name('vvp.exe')),str(binary)],cwd=ROOT,capture_output=True,text=True)
        log=OUT/(name+'_transient.run.log');log.write_text(run.stdout+run.stderr)
        assert run.returncode==0 and 'PASS' in run.stdout,run.stdout+run.stderr
        if name.startswith('real_'):assert not old and accepted.tolist()==[2],name
        records[name]=dict(old_end_frames=old,new_end_frames=ends,winners=winners.tolist(),
                           margins=margins.tolist(),predicted_classes=accepted.tolist(),
                           log_sha256=hashlib.sha256(log.read_bytes()).hexdigest())
        if name=='real_pad_0':
            negative_command=command[:1]+['-Ptb_voice_transient.CREDIT=0']+command[1:]
            cp=subprocess.run(negative_command,cwd=ROOT,capture_output=True,text=True)
            assert cp.returncode==0,cp.stderr
            negative=subprocess.run([str(iver.with_name('vvp.exe')),str(binary)],cwd=ROOT,capture_output=True,text=True)
            text=negative.stdout+negative.stderr
            assert negative.returncode!=0 and 'results/fault 0/0' in text,text
            (OUT/'real_transient_negative_control.run.log').write_text(text)
            records[name]['old_rtl_negative_control_failed_as_expected']=True
        print(name,run.stdout.strip(),flush=True)
    report=dict(passed=True,real_direction_labels_confirmed=True,spoken_classes=[2,1],
                recognized_correct=1,spoken_commands=2,second_command_still_rejected=True,
                trained_on_recording=False,cases=records,
                sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [
                    ROOT/'aca420/rtl/aca_kws_engine.v',ROOT/'voice/tools/kws_common.py',Path(__file__),
                    ROOT/'sim/tb_voice_transient.v',OUT/'user_20261021_170604.wav',
                    ROOT/'voice/model/weights.mem',ROOT/'voice/model/bias.mem',ROOT/'voice/model/config.json']})
    (OUT/'real_voice_transient.json').write_text(json.dumps(report,indent=2))

if __name__=='__main__':main()
