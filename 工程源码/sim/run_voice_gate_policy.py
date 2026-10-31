from pathlib import Path
import hashlib,json,subprocess
root=Path(__file__).resolve().parents[1]
sources=['aca420/rtl/aca_kws_engine.v','sim/tb_voice_gate_policy.v','sim/run_voice_gate_policy.py']
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
snapshot={s:sha(root/s) for s in sources}
iver=root/'tools/iverilog/app/bin/iverilog.exe';binary=root/'verification/tb_voice_gate_policy.vvp'
p=subprocess.run([str(iver),'-g2012','-s','tb_voice_gate_policy','-o',str(binary),*sources[:2]],cwd=root,capture_output=True,text=True)
assert p.returncode==0,p.stdout+p.stderr
p=subprocess.run([str(iver.with_name('vvp.exe')),str(binary)],cwd=root,capture_output=True,text=True,timeout=30)
log=root/'verification/voice_gate_policy.run.log';log.write_text(p.stdout+p.stderr)
assert p.returncode==0 and 'PASS' in p.stdout,p.stdout+p.stderr
assert snapshot=={s:sha(root/s) for s in sources}
(root/'verification/voice_gate_policy.json').write_text(json.dumps(dict(passed=True,sources=snapshot,log_sha256=sha(log)),indent=2))
print(p.stdout)
