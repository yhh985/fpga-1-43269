from pathlib import Path
import hashlib,json,subprocess,sys,binascii
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'verification'
sources=['aca420/rtl/aca_uart_report.v','common/uart_rx.v','sim/tb_feature_report.v','sim/run_feature_report.py','tools/decode_voice_capture.py']
hashes={s:hashlib.sha256((ROOT/s).read_bytes()).hexdigest() for s in sources}
iver=ROOT/'tools/iverilog/app/bin/iverilog.exe';binary=OUT/'tb_feature_report.vvp'
cp=subprocess.run([str(iver),'-g2012','-s','tb_feature_report','-o',str(binary),*sources[:3]],cwd=ROOT,capture_output=True,text=True)
assert cp.returncode==0,cp.stdout+cp.stderr
cp=subprocess.run([str(iver.with_name('vvp.exe')),str(binary)],cwd=ROOT,capture_output=True,text=True)
log=OUT/'feature_report.run.log';log.write_text(cp.stdout+cp.stderr)
assert cp.returncode==0 and 'PASS' in cp.stdout,cp.stdout+cp.stderr
sys.path.insert(0,str(ROOT/'tools'));from decode_voice_capture import decode
def packet(seq):
 b=bytearray(72);b[:3]=b'\xa5\x5a\x52';b[3:5]=seq.to_bytes(2,'little');b[12:28]=bytes(range(16))
 return bytes(b)+binascii.crc_hqx(b,0xffff).to_bytes(2,'little')
bad=bytearray(packet(2));bad[20]^=1
r,f=decode(b'junk'+packet(1)+bad+packet(3)+packet(4)[:30])
assert r['valid_packets']==2 and r['crc_errors']==1 and r['frame_gaps']==[[1,3]] and f.shape==(2,16),r
assert hashes=={s:hashlib.sha256((ROOT/s).read_bytes()).hexdigest() for s in sources}
(OUT/'feature_report.json').write_text(json.dumps(dict(passed=True,sources=hashes,log_sha256=hashlib.sha256(log.read_bytes()).hexdigest()),indent=2))
print(cp.stdout+'PASS host decoder: CRC corruption, junk, truncation and lost-frame detection')
