"""Package the explicitly requested sensitive legacy comparison branch."""
from pathlib import Path
from datetime import datetime,timezone
import json,hashlib,shutil
from build_verified import validate_record
ROOT=Path(__file__).resolve().parents[1]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
builds={b:validate_record(b) for b in ['aca420','hx4s20']}
baseline=ROOT.parents[1]/'deliverable/voice_continuity_20261023'
for board,r in builds.items():
 old=json.loads((baseline/f'{board}_verified_build_inputs.json').read_text(encoding='utf-8'))
 assert set(r['inputs']['files'])==set(old['inputs']['files'])
 changed={p.replace('\\','/') for p,h in old['inputs']['files'].items() if sha(ROOT/p)!=h}
 assert changed==({'aca420/rtl/aca_kws_engine.v','aca420/rtl/aca420_audio_top.v'} if board=='aca420' else set()),changed
files={Path(__file__),ROOT/'tools/build_verified.py',ROOT/'docs/voice_sensitive_guard_20261023.md',
 ROOT/'tools/capture_voice.ps1',ROOT/'tools/decode_voice_capture.py',ROOT/'tools/decode_voice_pcm.py',
 ROOT/'tools/replay_voice_capture.py',ROOT/'voice/tools/audit_sensitive_guard.py',ROOT/'voice/tools/probe_vad_continuity.py'}
tests={}
for name in ['sensitive_guard_rtl','sensitive_host','vad_continuity','voice_robust_rtl','pcm_report',
 'dual_board_music','voice_gate_policy','voice_reject_flags','voice_feedback','antiglitch','music_diagnostics','feature_report']:
 p=ROOT/'verification'/f'{name}.json';d=json.loads(p.read_text(encoding='utf-8'));assert d['passed'],name;files.add(p)
 for s,h in d['sources'].items():assert sha(ROOT/s)==h,(name,s);files.add(ROOT/s)
 if 'log_sha256' in d:
  p=ROOT/'verification'/('tb_dual_board_music.run.log' if name=='dual_board_music' else f'{name}.run.log');assert sha(p)==d['log_sha256'];files.add(p)
 if name in ['sensitive_guard_rtl','vad_continuity','voice_robust_rtl','pcm_report']:
  for case,r in d['cases'].items():
   prefix={'sensitive_guard_rtl':'sensitive_','vad_continuity':'vad_','voice_robust_rtl':'robust_','pcm_report':''}[name]
   p=ROOT/'verification'/f'{prefix}{case}.run.log';assert sha(p)==r['log_sha256'];files.add(p)
 if name=='antiglitch':
  for r in d['cases']:
   p=ROOT/'verification'/(r['name']+'.run.log');assert sha(p)==r['log_sha256'];files.add(p)
 tests[name]=d
p=ROOT/'verification/sensitive_noise.json';noise=json.loads(p.read_text());assert noise['completed'] and noise['false_commands']==0
for s,h in noise['sources'].items():assert sha(ROOT/s)==h;files.add(ROOT/s)
files.add(p)
experiment=ROOT/'voice/experiments/sensitive_guard'
selected=json.loads((experiment/'selected_policy.json').read_text());assert selected['policy']==['guard',True,109,0]
audits={}
for split,expected in [('validation',[(382,76,62),(380,54,48)]),('test',[(380,53,74),(367,37,54)])]:
 p=experiment/f'{split}_report.json';d=json.loads(p.read_text());files.add(p)
 for source,h in d['sources'].items():assert sha(Path(source))==h,(split,source)
 for key,e in zip(['original','guard_iso1_m109_s0' if split=='validation' else 'selected'],expected):
  r=d['policies'][key];assert tuple(r[k] for k in ['correct','wrong_direction','false_accepts'])==e
 audits[split]=d
files.add(experiment/'selected_policy.json')
legacy=Path('E:/anlo_project/liantiao/verification/before_noise_fix_20261020')
original=json.loads((legacy/'deliverable/release_manifest.json').read_text(encoding='utf-8'))
for n in ['weights.mem','bias.mem']:assert sha(ROOT/'voice/model'/n)==original['model'][n]
dst=ROOT.parents[1]/'deliverable/voice_sensitive_guard_20261023';dst.mkdir(exist_ok=False)
for board,r in builds.items():
 shutil.copy2(ROOT/board/'deliverable'/f'{board}_liantiao.bit',dst/f'{board}_voice_sensitive_guard.bit')
 for n in ['verified_build_inputs.json','final_timing_status.txt','final_timing.rpt','final_area.rpt']:
  shutil.copy2(ROOT/board/n,dst/f'{board}_{n}')
 files.update(ROOT/p for p in r['inputs']['files'])
for p in sorted(files):
 target=dst/'source_snapshot'/p.relative_to(ROOT);target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,target)
for p in ['deliverable/release_manifest.json','aca420/rtl/aca_kws_engine.v','aca420/rtl/aca_kws_frontend.v','voice/tools/kws_common.py']:
 target=dst/'historical_baseline'/p;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(legacy/p,target)
shutil.copy2(ROOT/'docs/voice_sensitive_guard_20261023.md',dst/'说明.md')
assert sha(dst/'hx4s20_voice_sensitive_guard.bit')==sha(baseline/'hx4s20_voice_continuity.bit')
record=dict(created_utc=datetime.now(timezone.utc).isoformat(),branch='sensitive_legacy_comparison',
 legacy_rom_hash_verified=True,selection=selected,audits=audits,noise=noise,builds=builds,tests=tests,
 human_accuracy_improvement_verified=False,known_real_next_still_rejected=True,
 more_false_accepts_and_wrong_directions_than_continuity=True,hardware_validation_pending=True,
 protocol=dict(voice_baud=460800,opcode=85,packet_bytes=596,passes=1,layout='native_isolated_48'),
 files={str(p.relative_to(dst)):sha(p) for p in dst.rglob('*') if p.is_file()})
(dst/'release_manifest.json').write_text(json.dumps(record,ensure_ascii=False,indent=2),encoding='utf-8')
for p,h in record['files'].items():assert sha(dst/p)==h
print('PASS sealed sensitive comparison branch:',dst)
