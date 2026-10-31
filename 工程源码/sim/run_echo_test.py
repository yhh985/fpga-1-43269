from pathlib import Path
import hashlib,json,subprocess
r=Path(__file__).resolve().parents[1];out=r/'verification'
iver=r/'tools/iverilog/app/bin/iverilog.exe'
sources=['common/music_fx_return.v','sim/tb_music_echo.v']
snapshot={s:hashlib.sha256((r/s).read_bytes()).hexdigest() for s in sources}
cp=subprocess.run([str(iver),'-g2012','-s','tb_music_echo','-o',str(out/'tb_music_echo.vvp'),*sources],
                  cwd=r,capture_output=True,text=True,check=True)
(out/'tb_music_echo.compile.log').write_text(cp.stdout+cp.stderr)
cp=subprocess.run([str(iver.with_name('vvp.exe')),str(out/'tb_music_echo.vvp')],cwd=r,capture_output=True,text=True,check=True)
log=out/'tb_music_echo.run.log';log.write_text(cp.stdout+cp.stderr)
assert 'PASS echo: 20501 exact stereo frames' in cp.stdout
assert snapshot=={s:hashlib.sha256((r/s).read_bytes()).hexdigest() for s in sources}
(out/'echo_test.json').write_text(json.dumps(dict(passed=True,frames=20501,sources=snapshot,
        log_sha256=hashlib.sha256(log.read_bytes()).hexdigest()),indent=2))
print(cp.stdout)
