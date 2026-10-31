"""Independent wire skew regression, including the physical FX WAIT failure case."""
from pathlib import Path
import concurrent.futures, hashlib, json, subprocess
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'verification'
SOURCES=['hx4s20/hdl/audio_wav_i2s.v','common/music_fx_return.v',
         'hx4s20/hdl/I2S_receiver.v','sim/tb_music_checked.v','sim/run_audio_skew.py']
IVER=ROOT/'tools/iverilog/app/bin/iverilog.exe'

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def run(case):
    phase,wire,lrck,data,video=case
    name=f'skew_p{phase}_w{wire}_l{lrck}_d{data}_v{video}'
    args=[str(IVER),'-g2012','-s','tb_music_checked','-Ptb_music_checked.QUICK=1',
          f'-Ptb_music_checked.PHASE={phase}',f'-Ptb_music_checked.LINK_DELAY={wire}',
          f'-Ptb_music_checked.LRCK_SKEW={lrck}',f'-Ptb_music_checked.DATA_SKEW={data}',
          f'-Ptb_music_checked.VIDEO_PHASE={video}','-o',str(OUT/(name+'.vvp')),*SOURCES[:4]]
    cp=subprocess.run(args,cwd=ROOT,capture_output=True,text=True,timeout=60)
    (OUT/(name+'.compile.log')).write_text(cp.stdout+cp.stderr)
    assert cp.returncode==0,cp.stderr
    cp=subprocess.run([str(IVER.with_name('vvp.exe')),str(OUT/(name+'.vvp'))],
                      cwd=ROOT,capture_output=True,text=True,timeout=240)
    log=OUT/(name+'.run.log');log.write_text(cp.stdout+cp.stderr)
    assert cp.returncode==0 and 'PASS checked effects:' in cp.stdout,name+' '+cp.stdout+cp.stderr
    print(name,'PASS',flush=True)
    return dict(name=name,phase_ns=phase,common_wire_delay_ns=wire,lrck_skew_ns=lrck,
                data_skew_ns=data,video_phase_ns=video,log_sha256=sha(log))

if __name__=='__main__':
    snapshot={s:sha(ROOT/s) for s in SOURCES}
    cases=[(p,0,l,15,v) for p,v in [(0,0),(7,13),(19,29)] for l in [0,15,25,35,60,90]]
    cases += [(p,35,35,d,v) for p,v in [(0,7),(11,33)] for d in [0,25,60]]
    # LRCK leads BCLK by 15ns: every absolute path delay remains nonnegative.
    cases += [(p,35,-15,0,17) for p in [0,7,19]]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:rows=list(pool.map(run,cases))
    assert snapshot=={s:sha(ROOT/s) for s in SOURCES},'sources changed during skew tests'
    (OUT/'audio_skew.json').write_text(json.dumps(dict(passed=len(rows),cases=rows,
        digital_simulation_only=True,sources=snapshot),indent=2))
    print('PASS independent audio wire skew:',len(rows),flush=True)
