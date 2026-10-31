"""Sweep the current CRC transport, separately from legacy effect regressions."""
from pathlib import Path
import concurrent.futures
import hashlib
import json
import subprocess

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'verification'; OUT.mkdir(exist_ok=True)
IVER=ROOT/'tools/iverilog/app/bin/iverilog.exe'
SOURCES=['hx4s20/hdl/audio_wav_i2s.v','common/music_fx_return.v',
         'hx4s20/hdl/I2S_receiver.v','sim/tb_music_checked.v']

def run(case):
    phase,delay,quick=case
    name=f'checked_p{phase}_d{delay}_q{quick}'
    args=[str(IVER),'-g2012','-Wall','-s','tb_music_checked',
          f'-Ptb_music_checked.PHASE={phase}',f'-Ptb_music_checked.LINK_DELAY={delay}',
          f'-Ptb_music_checked.QUICK={quick}','-o',str(OUT/(name+'.vvp')),*SOURCES]
    cp=subprocess.run(args,cwd=ROOT,capture_output=True,text=True,timeout=60)
    (OUT/(name+'.compile.log')).write_text(cp.stdout+cp.stderr)
    assert cp.returncode==0,cp.stderr
    cp=subprocess.run([str(IVER.with_name('vvp.exe')),str(OUT/(name+'.vvp'))],
                      cwd=ROOT,capture_output=True,text=True,timeout=360)
    log=OUT/(name+'.run.log');log.write_text(cp.stdout+cp.stderr)
    assert cp.returncode==0 and 'PASS checked effects:' in cp.stdout, name+' '+cp.stdout+cp.stderr
    print(name,'PASS',flush=True)
    return dict(name=name,phase_ns=phase,one_way_delay_ns=delay,full_tremolo=not quick,
                log_sha256=hashlib.sha256(log.read_bytes()).hexdigest())

if __name__=='__main__':
    snapshot={s:hashlib.sha256((ROOT/s).read_bytes()).hexdigest() for s in SOURCES}
    cases=[(p,d,1) for p in [0,3,7,11,15,19] for d in [0,5,20,35,50]]+[(0,0,0)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        rows=list(pool.map(run,cases))
    assert snapshot=={s:hashlib.sha256((ROOT/s).read_bytes()).hexdigest() for s in SOURCES},'Sources changed during tests'
    report=dict(passed=len(rows),cases=rows,digital_simulation_only=True,sources=snapshot)
    (OUT/'checked_audio.json').write_text(json.dumps(report,indent=2))
    print('PASS checked audio matrix:',len(rows),flush=True)
