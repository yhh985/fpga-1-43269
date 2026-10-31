from pathlib import Path
import hashlib,json,subprocess
root=Path(__file__).resolve().parents[1]
out=root/'verification'
sources=['common/music_fx_return.v','hx4s20/hdl/mic_overlay.v',
         'sim/tb_music_diagnostics.v','sim/run_music_diagnostics.py']
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
snapshot={s:sha(root/s) for s in sources}
iver=root/'tools/iverilog/app/bin/iverilog.exe'
cp=subprocess.run([str(iver),'-g2012','-s','tb_music_diagnostics','-o',
                  str(out/'music_diagnostics.vvp'),*sources[:3]],cwd=root,capture_output=True,text=True)
(out/'music_diagnostics.compile.log').write_text(cp.stdout+cp.stderr)
assert cp.returncode==0,cp.stderr
cp=subprocess.run([str(iver.with_name('vvp.exe')),str(out/'music_diagnostics.vvp')],
                  cwd=root,capture_output=True,text=True,timeout=30)
log=out/'music_diagnostics.run.log';log.write_text(cp.stdout+cp.stderr)
assert cp.returncode==0 and 'PASS music diagnostics:' in cp.stdout,cp.stdout+cp.stderr
assert snapshot=={s:sha(root/s) for s in sources}
(out/'music_diagnostics.json').write_text(json.dumps(dict(passed=True,sources=snapshot,
    log_sha256=sha(log),digital_simulation_only=True),indent=2))
print(cp.stdout)
