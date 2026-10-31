"""Seal the continuity fix, paired firmware, exact sources and bounded evidence."""
from pathlib import Path
from datetime import datetime,timezone
import hashlib,json,shutil
from build_verified import validate_record
ROOT=Path(__file__).resolve().parents[1]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
builds={b:validate_record(b) for b in ['aca420','hx4s20']}
baseline=ROOT.parents[1]/'deliverable/voice_gate_fix_20261023'
for board,record in builds.items():
 old=json.loads((baseline/f'{board}_verified_build_inputs.json').read_text(encoding='utf-8'))
 assert set(old['inputs']['files'])==set(record['inputs']['files'])
 changed={s.replace('\\','/') for s,h in old['inputs']['files'].items() if sha(ROOT/s)!=h}
 assert changed==({'aca420/rtl/aca_kws_frontend.v','aca420/rtl/aca420_audio_top.v','aca420/build_verified.tcl'} if board=='aca420' else set()),changed
files={Path(__file__),ROOT/'tools/build_verified.py',ROOT/'docs/voice_continuity_20261023.md',
 ROOT/'voice/tools/probe_vad_continuity.py',ROOT/'voice/tools/kws_common.py',ROOT/'tools/capture_voice.ps1',
 ROOT/'tools/decode_voice_pcm.py',ROOT/'tools/decode_voice_capture.py',ROOT/'voice/tools/robust_common.py'}
tests={}
for name in ['vad_continuity','voice_robust_rtl','voice_robust_noise','pcm_report','dual_board_music',
             'voice_gate_policy','voice_reject_flags','voice_feedback','antiglitch','music_diagnostics','feature_report']:
 p=ROOT/'verification'/f'{name}.json';d=json.loads(p.read_text(encoding='utf-8'));assert d['passed'],name
 for s,h in d['sources'].items():assert sha(ROOT/s)==h,(name,s);files.add(ROOT/s)
 files.add(p);tests[name]=d
 if 'log_sha256' in d:
  p=ROOT/'verification'/('tb_dual_board_music.run.log' if name=='dual_board_music' else f'{name}.run.log')
  assert sha(p)==d['log_sha256'];files.add(p)
 if name in ['vad_continuity','voice_robust_rtl','pcm_report']:
  for case,r in d['cases'].items():
   log=(f'vad_{case}' if name=='vad_continuity' else f'robust_{case}' if name=='voice_robust_rtl' else case)+'.run.log'
   p=ROOT/'verification'/log;assert sha(p)==r['log_sha256'];files.add(p)
 if name=='antiglitch':
  for r in d['cases']:
   p=ROOT/'verification'/(r['name']+'.run.log');assert sha(p)==r['log_sha256'];files.add(p)
for case in ['tb_prefetch','tb_voice_noise','tb_return_guard']:
 p=ROOT/'verification'/f'{case}.run.log';text=p.read_text(encoding='utf-8-sig')
 assert 'PASS' in text and 'FATAL' not in text and 'ERROR:' not in text;files.add(p)
 tests[case]=dict(passed=True,simulation_only=True,log_sha256=sha(p))
audits={}
for split in ['validation','test']:
 p=ROOT/f'voice/experiments/vad_continuity/{split}_report.json';d=json.loads(p.read_text());files.add(p)
 expected={'validation':[(383,13,8),(410,13,7)],'test':[(352,1,6),(400,1,8)]}[split]
 for policy,e in zip(['baseline','hysteresis'],expected):
  r=d['policies'][policy];assert tuple(r[k] for k in ['correct','wrong_direction','false_accepts'])==e
 audits[split]=d
manifest=Path('E:/anlo_project/liantiao/voice/data/manifest.json')
rows=json.loads(manifest.read_text(encoding='utf-8'))
data_hashes={}
for i,row in enumerate(rows):
 if row['split'] not in ['validation','test']:continue
 p=manifest.parent.parent/row['path'];digest=sha(p);assert digest==row['sha256']
 data_hashes[row['path']]=digest
 cache=ROOT/'voice/experiments/vad_continuity/cache'/f'{digest}_{i}_powers_v1.npz';assert cache.exists();files.add(cache)
dst=ROOT.parents[1]/'deliverable/voice_continuity_20261023';dst.mkdir(exist_ok=False)
for board,record in builds.items():
 shutil.copy2(ROOT/board/'deliverable'/f'{board}_liantiao.bit',dst/f'{board}_voice_continuity.bit')
 for n in ['verified_build_inputs.json','final_timing_status.txt','final_timing.rpt','final_area.rpt']:
  shutil.copy2(ROOT/board/n,dst/f'{board}_{n}')
 files.update(ROOT/s for s in record['inputs']['files'])
for p in sorted(files):
 target=dst/'source_snapshot'/p.relative_to(ROOT);target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,target)
shutil.copy2(manifest,dst/'synthetic_data_manifest.json')
shutil.copy2(ROOT/'docs/voice_continuity_20261023.md',dst/'说明.md')
assert sha(dst/'hx4s20_voice_continuity.bit')==sha(baseline/'hx4s20_voice_gate_fix.bit')
record=dict(created_utc=datetime.now(timezone.utc).isoformat(),baseline='voice_gate_fix_20261023',
 model_unchanged=True,selected_policy='hysteresis',selection_split='validation',
 human_accuracy_improvement_verified=False,hardware_accuracy_validation_pending=True,
 old_real_recording_predictions=[2,0],old_real_recording_next_still_rejected=True,
 protocol=dict(voice_baud=460800,opcode=85,packet_bytes=596),builds=builds,tests=tests,audits=audits,
 synthetic_data_hashes=data_hashes,
 files={str(p.relative_to(dst)):sha(p) for p in dst.rglob('*') if p.is_file()})
(dst/'release_manifest.json').write_text(json.dumps(record,ensure_ascii=False,indent=2),encoding='utf-8')
for p,h in record['files'].items():assert sha(dst/p)==h
print('PASS source-bound continuity package:',dst)
