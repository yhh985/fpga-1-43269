"""Check the compact estimator's bin and silence boundaries."""
from pathlib import Path
import hashlib,json,subprocess

root=Path(__file__).resolve().parents[1]
out=root/'verification'
sources=[root/'hx4s20/hdl/audio_visual_link.v',root/'sim/tb_music_frequency_probe.v']
iver=root/'tools/iverilog/app/bin/iverilog.exe'
binary=out/'tb_music_frequency_probe.vvp'
cp=subprocess.run([str(iver),'-g2012','-s','tb_music_frequency_probe','-o',str(binary),*map(str,sources)],capture_output=True,text=True,check=True)
(out/'tb_music_frequency_probe.compile.log').write_text(cp.stdout+cp.stderr)
cp=subprocess.run([str(iver.with_name('vvp.exe')),str(binary)],capture_output=True,text=True,check=True,timeout=60)
log=out/'tb_music_frequency_probe.run.log'
log.write_text(cp.stdout+cp.stderr)
print(cp.stdout+cp.stderr)
assert 'PASS frequency probe:' in cp.stdout
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
(out/'music_frequency_probe.json').write_text(json.dumps(dict(passed=True,simulation_only=True,
 sources={str(p.relative_to(root)):sha(p) for p in sources},log_sha256=sha(log)),indent=2))
