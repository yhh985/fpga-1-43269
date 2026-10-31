"""Package validated PCM/command-trace firmware without modifying older releases."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib,json,shutil
from build_verified import validate_record

ROOT=Path(__file__).resolve().parents[1]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
builds={b:validate_record(b) for b in ('aca420','hx4s20')}
baseline=ROOT.parents[1]/'deliverable/voice_response_20261023'
for b,record in builds.items():
 old=json.loads((baseline/(b+'_verified_build_inputs.json')).read_text(encoding='utf-8'))
 assert set(old['inputs']['files'])==set(record['inputs']['files'])
 changed={s.replace('\\','/') for s,h in old['inputs']['files'].items() if sha(ROOT/s)!=h}
 allowed={'aca420/rtl/aca420_audio_top.v','aca420/rtl/aca_kws_frontend.v','aca420/rtl/aca_uart_report.v'} if b=='aca420' else {'hx4s20/hdl/mic_overlay.v'}
 assert changed==allowed,(b,changed)
files={Path(__file__),ROOT/'tools/build_verified.py',ROOT/'tools/capture_voice.ps1',
 ROOT/'docs/voice_pcm_trace_20261023.md',ROOT/'docs/voice_failure_analysis_20261023_151059.md'}
tests={}
for name in ('feature_report','voice_reject_flags','voice_robust_rtl','voice_feedback',
             'dual_board_music','music_diagnostics','antiglitch','pcm_report'):
 p=ROOT/'verification'/(name+'.json');d=json.loads(p.read_text(encoding='utf-8'));assert d['passed'],name;files.add(p)
 for s,h in d['sources'].items():assert sha(ROOT/s)==h,(name,s);files.add(ROOT/s)
 if 'log_sha256' in d:
  p=ROOT/'verification'/({'dual_board_music':'tb_dual_board_music.run.log'}.get(name,name+'.run.log'))
  assert sha(p)==d['log_sha256'];files.add(p)
 if name in ('voice_robust_rtl','pcm_report'):
  for case,c in d['cases'].items():
   p=ROOT/'verification'/((('robust_'+case) if name=='voice_robust_rtl' else case)+'.run.log')
   assert sha(p)==c['log_sha256'];files.add(p)
 if name=='antiglitch':
  for c in d['cases']:
   p=ROOT/'verification'/(c['name']+'.run.log');assert sha(p)==c['log_sha256'];files.add(p)
 tests[name]=d
for name in ('tb_prefetch','tb_voice_noise','tb_return_guard'):
 p=ROOT/'verification'/(name+'.run.log');s=p.read_text(encoding='utf-8-sig')
 assert 'PASS' in s and 'FATAL:' not in s and 'ERROR:' not in s;files.add(p)
 tests[name]=dict(passed=True,simulation_only=True,log_sha256=sha(p))
files.update((ROOT/'sim').glob('*.v'));files.update((ROOT/'sim').glob('run*.py'));files.update((ROOT/'sim').glob('run*.ps1'))
files.update((ROOT/'docs/research_voice_20261023').glob('*.txt'))
files.update(ROOT/p for p in ('tools/decode_voice_pcm.py','tools/decode_voice_capture.py',
 'tools/replay_voice_capture.py','verification/voice_capture_annotations_20261023.json',
 'verification/voice_capture_20261023_151059.bin','verification/voice_capture_20261023_151059.replay.json',
 'voice/experiments/dtw_pilot/validation_report.json'))
dst=ROOT.parents[1]/'deliverable/voice_pcm_trace_20261023';dst.mkdir(exist_ok=False)
for b,record in builds.items():
 shutil.copy2(ROOT/b/'deliverable'/(b+'_liantiao.bit'),dst/(b+'_voice_pcm_trace.bit'))
 for n in ('verified_build_inputs.json','final_timing_status.txt','final_timing.rpt','final_area.rpt'):
  shutil.copy2(ROOT/b/n,dst/(b+'_'+n))
 files.update(ROOT/s for s in record['inputs']['files'])
for p in sorted(files):
 target=dst/'source_snapshot'/p.relative_to(ROOT);target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,target)
shutil.copy2(ROOT/'docs/voice_pcm_trace_20261023.md',dst/'说明.md')
record=dict(created_utc=datetime.now(timezone.utc).isoformat(),baseline='voice_response_20261023',
 model_unchanged=True,recognition_accuracy_improved=False,hardware_accuracy_validation_pending=True,
 protocol=dict(voice_baud=460800,opcode=0x55,packet_bytes=596),builds=builds,tests=tests,
 files={str(p.relative_to(dst)):sha(p) for p in dst.rglob('*') if p.is_file()})
(dst/'release_manifest.json').write_text(json.dumps(record,ensure_ascii=False,indent=2),encoding='utf-8')
for p,h in record['files'].items():assert sha(dst/p)==h
print('PASS source-bound PCM trace package:',dst)
