"""Production 32-bit I2S slots: signed stereo under clock phase/link delay sweeps."""
import json,subprocess,hashlib
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
IVER=ROOT/'tools/iverilog/app/bin/iverilog.exe'
sources=['hx4s20/hdl/audio_wav_i2s.v','hx4s20/hdl/I2S_receiver.v',
         'common/music_fx_return.v','sim/tb_music_fx.v']
results=[]
for phase in [0,3,7,11,15,19]:
    for delay in [0,5,20,35,50]:
        name=f'fx32_phase_{phase}_delay_{delay}'
        binary=ROOT/f'verification/{name}.vvp'
        cp=subprocess.run([str(IVER),'-g2012','-s','tb_music_fx',
            '-Ptb_music_fx.SLOT_BITS=32',f'-Ptb_music_fx.PHASE={phase}',
            f'-Ptb_music_fx.LINK_DELAY={delay}','-o',str(binary),*sources],
            cwd=ROOT,capture_output=True,text=True)
        (ROOT/f'verification/{name}.compile.log').write_text(cp.stdout+cp.stderr)
        assert cp.returncode==0,cp.stderr
        run=subprocess.run([str(IVER.with_name('vvp.exe')),str(binary)],cwd=ROOT,capture_output=True,text=True)
        path=ROOT/f'verification/{name}.run.log';path.write_text(run.stdout+run.stderr)
        assert run.returncode==0 and 'PASS' in run.stdout,run.stdout+run.stderr
        results.append(dict(name=name,passed=True,phase_ns=phase,one_way_delay_ns=delay,
                            sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
        print(name,'PASS',flush=True)
track_sources=['hx4s20/hdl/mic_overlay.v','sim/tb_track_overlay.v']
binary=ROOT/'verification/tb_track_overlay.vvp'
cp=subprocess.run([str(IVER),'-g2012','-s','tb_track_overlay','-o',str(binary),*track_sources],cwd=ROOT,capture_output=True,text=True)
assert cp.returncode==0,cp.stderr
run=subprocess.run([str(IVER.with_name('vvp.exe')),str(binary)],cwd=ROOT,capture_output=True,text=True)
(ROOT/'verification/tb_track_overlay.run.log').write_text(run.stdout+run.stderr)
assert run.returncode==0 and 'PASS track OSD:' in run.stdout,run.stdout+run.stderr
print(run.stdout.strip(),flush=True)
report=dict(passed=len(results),cases=results,
    sources={s:hashlib.sha256((ROOT/s).read_bytes()).hexdigest() for s in sources},
    note='Digital simulation only; delay is a stress budget, not a measured wire delay.')
(ROOT/'verification/noise_fix_audio.json').write_text(json.dumps(report,indent=2))
