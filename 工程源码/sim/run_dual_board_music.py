from pathlib import Path
import json
import hashlib
import re
import subprocess
import xml.etree.ElementTree as ET

r=Path(__file__).resolve().parents[1]
out=r/'verification';out.mkdir(exist_ok=True)
script=(r/'hx4s20/sim/run_top_video_pipeline.ps1').read_text(encoding='utf-8-sig')
block=script.split('$sources=@(',1)[1].split("$bench='tb_top_video_pipeline'",1)[0]
sources={(r/'hx4s20'/p.replace('\\','/')).resolve()
         for p in re.findall(r"'([^']+\.v)'",block) if not p.startswith('sim')}
sources.update((r/'aca420/rtl').glob('*.v'))
sources.discard(r/'aca420/rtl/aca_audio_pll.v')
assert (r/'aca420/rtl/audio_goertzel.v').read_bytes()==(r/'hx4s20/hdl/audio_goertzel.v').read_bytes()
sources.discard(r/'aca420/rtl/audio_goertzel.v')
# reset_release is shared identically between projects; compile one definition.
sources.discard(r/'aca420/rtl/reset_release.v')
pll=(r/'aca420/sim/tb_audio_top.v').read_text().split('module tb_audio_top;')[0]
(out/'aca_pll_stub.v').write_text(pll)
sources.update([out/'aca_pll_stub.v',r/'hx4s20/sim/audit_work/top_peripheral_stubs.v',
                r/'sim/tb_dual_board_music.v'])
iver=r/'tools/iverilog/app/bin/iverilog.exe'
args=[str(iver),'-g2012','-Wall','-DSIMULATION','-I',str(r/'hx4s20/hdl/include'),
      '-I',str(r/'hx4s20/hdl'),'-s','tb_dual_board_music','-o',str(out/'tb_dual_board_music.vvp'),
      *map(str,sorted(sources))]
cp=subprocess.run(args,cwd=r/'hx4s20',capture_output=True,text=True)
(out/'tb_dual_board_music.compile.log').write_text(cp.stdout+cp.stderr)
assert cp.returncode==0,cp.stdout+cp.stderr
cp=subprocess.run([str(iver.with_name('vvp.exe')),str(out/'tb_dual_board_music.vvp')],
                  cwd=r/'hx4s20',capture_output=True,text=True,timeout=360)
log=out/'tb_dual_board_music.run.log';log.write_text(cp.stdout+cp.stderr)
print(cp.stdout+cp.stderr,flush=True)
assert cp.returncode==0 and 'PASS dual board music:' in cp.stdout
(out/'dual_board_music.json').write_text(json.dumps(dict(passed=True,simulation_only=True,
    sources={str(p.relative_to(r)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
    log_sha256=hashlib.sha256(log.read_bytes()).hexdigest()),indent=2))
