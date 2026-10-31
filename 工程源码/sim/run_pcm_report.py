from pathlib import Path
import hashlib,json,subprocess,sys
import numpy as np
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'tools'))
from decode_voice_pcm import decode
sources=['aca420/rtl/aca_uart_report.v','aca420/rtl/aca_kws_frontend.v',
 'aca420/rtl/kws_goertzel.v','common/uart_rx.v','sim/tb_pcm_report.v',
 'sim/tb_pcm_frontend.v','sim/run_pcm_report.py','tools/decode_voice_pcm.py',
 'tools/decode_voice_capture.py']
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
snapshot={s:sha(root/s) for s in sources}
iver=root/'tools/iverilog/app/bin/iverilog.exe';cases={}
for top in ['tb_pcm_report','tb_pcm_frontend']:
 binary=root/'verification'/(top+'.vvp')
 cp=subprocess.run([str(iver),'-g2012','-s',top,'-o',str(binary),*sources[:6]],cwd=root,capture_output=True,text=True)
 assert cp.returncode==0,cp.stdout+cp.stderr
 cp=subprocess.run([str(iver.with_name('vvp.exe')),str(binary)],cwd=root,capture_output=True,text=True,timeout=240)
 log=root/'verification'/(top+'.run.log');log.write_text(cp.stdout+cp.stderr)
 assert cp.returncode==0 and 'PASS' in cp.stdout,cp.stdout+cp.stderr
 cases[top]={'passed':True,'log_sha256':sha(log)};print(cp.stdout,flush=True)
for name,frames in [('pcm_report_fixture',2),('pcm_frontend_fixture',3)]:
 raw=(root/'verification'/(name+'.bin')).read_bytes();r,f,pcm=decode(raw)
 assert r['audio_contiguous'] and r['valid_packets']==frames,r
 if frames==3:assert np.array_equal(pcm,(np.arange(768)%31-15)*60)
 bad=bytearray(raw);bad[100]^=1
 assert not decode(bad)[0]['audio_contiguous']
 assert not decode(raw[:596]+raw[-596:])[0]['audio_contiguous'] if frames==3 else True
 r['command_trace']=r['command_trace'][:3]
 (root/'verification'/(name+'.host.json')).write_text(json.dumps(r,indent=2))
assert snapshot=={s:sha(root/s) for s in sources}
(root/'verification/pcm_report.json').write_text(json.dumps(dict(passed=True,sources=snapshot,cases=cases),indent=2))
print('PASS host PCM decoder: exact audio, CRC rejection, frame-gap rejection and command trace')
