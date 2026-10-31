from pathlib import Path
import subprocess,json,hashlib
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'verification'
sources=['aca420/rtl/aca_kws_engine.v','sim/tb_voice_reject_flags.v','sim/run_voice_reject_flags.py']
hashes={s:hashlib.sha256((ROOT/s).read_bytes()).hexdigest() for s in sources}
iver=ROOT/'tools/iverilog/app/bin/iverilog.exe';binary=OUT/'tb_voice_reject_flags.vvp'
cp=subprocess.run([str(iver),'-g2012','-s','tb_voice_reject_flags','-o',str(binary),*sources[:2]],cwd=ROOT,capture_output=True,text=True)
assert cp.returncode==0,cp.stdout+cp.stderr
cp=subprocess.run([str(iver.with_name('vvp.exe')),str(binary)],cwd=ROOT,capture_output=True,text=True,timeout=60)
log=OUT/'voice_reject_flags.run.log';log.write_text(cp.stdout+cp.stderr)
assert cp.returncode==0 and 'PASS' in cp.stdout,cp.stdout+cp.stderr
negative=OUT/'tb_voice_prequiet_old.vvp'
old=subprocess.run([str(iver),'-g2012','-s','tb_voice_reject_flags','-Ptb_voice_reject_flags.QUIET=8','-o',str(negative),*sources[:2]],cwd=ROOT,capture_output=True,text=True)
assert old.returncode==0,old.stderr
old=subprocess.run([str(iver.with_name('vvp.exe')),str(negative)],cwd=ROOT,capture_output=True,text=True,timeout=60)
assert old.returncode!=0 and '192ms endpoint failed to rearm' in old.stdout,old.stdout+old.stderr
(OUT/'voice_prequiet_old_negative.run.log').write_text(old.stdout+old.stderr)
assert hashes=={s:hashlib.sha256((ROOT/s).read_bytes()).hexdigest() for s in sources}
(OUT/'voice_reject_flags.json').write_text(json.dumps(dict(passed=True,old_prequiet_negative_control_failed_as_expected=True,sources=hashes,log_sha256=hashlib.sha256(log.read_bytes()).hexdigest()),indent=2))
print(cp.stdout)
