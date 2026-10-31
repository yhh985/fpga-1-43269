from pathlib import Path
import hashlib,json,subprocess
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'verification'
sources=['aca420/rtl/aca_music_clock_probe.v','sim/tb_music_clock_probe.v','sim/run_music_clock_probe.py']
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
snapshot={s:sha(ROOT/s) for s in sources}
iver=ROOT/'tools/iverilog/app/bin/iverilog.exe';binary=OUT/'tb_music_clock_probe.vvp'
cp=subprocess.run([str(iver),'-g2012','-Wall','-s','tb_music_clock_probe','-o',str(binary),*sources[:2]],cwd=ROOT,capture_output=True,text=True)
assert cp.returncode==0,cp.stderr
cp=subprocess.run([str(iver.with_name('vvp.exe')),str(binary)],cwd=ROOT,capture_output=True,text=True,timeout=60)
log=OUT/'music_clock_probe.run.log';log.write_text(cp.stdout+cp.stderr)
assert cp.returncode==0 and 'PASS clock probe:' in cp.stdout,cp.stdout+cp.stderr
assert snapshot=={s:sha(ROOT/s) for s in sources}
(OUT/'music_clock_probe.json').write_text(json.dumps(dict(passed=True,sources=snapshot,log_sha256=sha(log),hardware_tested=False),indent=2))
print(cp.stdout)
