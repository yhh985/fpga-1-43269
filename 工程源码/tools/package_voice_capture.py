"""Source-bound acquisition firmware; recognition model deliberately unchanged."""
from pathlib import Path
from datetime import datetime,timezone
import json,hashlib,shutil
from build_verified import validate_record
ROOT=Path(__file__).resolve().parents[1];sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
builds={b:validate_record(b) for b in ['aca420','hx4s20']}
baseline=ROOT.parents[1]/'deliverable/voice_robust_20261023'
for board,record in builds.items():
 old=json.loads((baseline/(board+'_verified_build_inputs.json')).read_text())
 changed={s.replace('\\','/') for s,d in old['inputs']['files'].items() if sha(ROOT/s)!=d}
 allowed={'aca420/rtl/aca_kws_engine.v','aca420/rtl/aca420_audio_top.v','aca420/rtl/aca_uart_report.v'} if board=='aca420' else set()
 assert changed==allowed,(board,changed)
 assert set(record['inputs']['files'])==set(old['inputs']['files'])
tests={};files={Path(__file__),ROOT/'tools/build_verified.py',ROOT/'tools/capture_voice.ps1',ROOT/'tools/decode_voice_capture.py',ROOT/'docs/板上语音抓取20261023.md'}
for name in ['feature_report','voice_reject_flags','voice_robust_rtl','voice_feedback','dual_board_music','music_diagnostics','antiglitch']:
 p=ROOT/'verification'/(name+'.json');d=json.loads(p.read_text());assert d['passed'],name;files.add(p)
 for s,h in d['sources'].items():assert sha(ROOT/s)==h,(name,s);files.add(ROOT/s)
 if 'log_sha256' in d:
  log=ROOT/'verification'/({'dual_board_music':'tb_dual_board_music.run.log'}.get(name,name+'.run.log'))
  assert sha(log)==d['log_sha256'];files.add(log)
 if name=='voice_robust_rtl':
  for n,c in d['cases'].items():
   log=ROOT/'verification'/('robust_'+n+'.run.log');assert sha(log)==c['log_sha256'];files.add(log)
 if name=='antiglitch':
  for c in d['cases']:
   log=ROOT/'verification'/(c['name']+'.run.log');assert sha(log)==c['log_sha256'];files.add(log)
 tests[name]=d
dst=ROOT.parents[1]/'deliverable/voice_capture_20261023';dst.mkdir(exist_ok=False)
for board,build in builds.items():
 bit=ROOT/board/'deliverable'/(board+'_liantiao.bit')
 shutil.copy2(bit,dst/('aca420_voice_capture.bit' if board=='aca420' else 'hx4s20_voice_feedback.bit'))
 for n in ['verified_build_inputs.json','final_timing_status.txt','final_timing.rpt','final_area.rpt']:
  shutil.copy2(ROOT/board/n,dst/(board+'_'+n))
 files.update(ROOT/s for s in build['inputs']['files'])
assert sha(dst/'hx4s20_voice_feedback.bit')==sha(baseline/'hx4s20_voice_feedback.bit')
for p in files:
 target=dst/'source_snapshot'/p.relative_to(ROOT);target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,target)
shutil.copy2(ROOT/'docs/板上语音抓取20261023.md',dst/'上板抓取说明.md')
record=dict(created_utc=datetime.now(timezone.utc).isoformat(),baseline='voice_robust_20261023',
 recognition_accuracy_improved=False,model_unchanged=True,hardware_feature_capture_pending=True,
 builds=builds,tests=tests,files={str(p.relative_to(dst)):sha(p) for p in dst.rglob('*') if p.is_file()})
(dst/'release_manifest.json').write_text(json.dumps(record,ensure_ascii=False,indent=2),encoding='utf8')
for p,h in record['files'].items():assert sha(dst/p)==h
print('PASS voice acquisition package:',dst)
