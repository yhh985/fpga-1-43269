from pathlib import Path
import hashlib,json,subprocess
root=Path(__file__).resolve().parents[1]
out=root/'verification'
sources=['aca420/rtl/aca_kws_engine.v','sim/tb_voice_feedback.v','sim/run_voice_feedback.py']
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
snapshot={s:sha(root/s) for s in sources}
iver=root/'tools/iverilog/app/bin/iverilog.exe'
binary=out/'tb_voice_feedback.vvp'
cp=subprocess.run([str(iver),'-g2012','-s','tb_voice_feedback','-o',str(binary),*sources[:2]],cwd=root,capture_output=True,text=True)
assert cp.returncode==0,cp.stdout+cp.stderr
cp=subprocess.run([str(iver.with_name('vvp.exe')),str(binary)],cwd=root,capture_output=True,text=True,timeout=60)
log=out/'voice_feedback.run.log';log.write_text(cp.stdout+cp.stderr)
assert cp.returncode==0 and 'PASS voice feedback:' in cp.stdout,cp.stdout+cp.stderr
assert snapshot=={s:sha(root/s) for s in sources}
(out/'voice_feedback.json').write_text(json.dumps(dict(passed=True,sources=snapshot,log_sha256=sha(log),hardware_tested=False),indent=2))
print(cp.stdout)
