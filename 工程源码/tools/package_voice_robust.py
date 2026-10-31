"""Package a source-bound variable-rate voice candidate and compatible HX image."""
from pathlib import Path
import hashlib,json,shutil
from datetime import datetime,timezone
from build_verified import validate_record
ROOT=Path(__file__).resolve().parents[1]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
builds={b:validate_record(b) for b in ['aca420','hx4s20']}
baseline=ROOT.parents[1]/'deliverable/voice_feedback_20261023'
for board,new in builds.items():
 old=json.loads((baseline/(board+'_verified_build_inputs.json')).read_text())
 changed={s.replace('\\','/') for s,d in old['inputs']['files'].items() if sha(ROOT/s)!=d}
 assert changed==({'aca420/rtl/aca_kws_engine.v','aca420/build_verified.tcl'} if board=='aca420' else set()),changed
exp=ROOT/'voice/experiments/robust_normalized';cfg=json.loads((exp/'model/config.json').read_text())
assert cfg['normalization']=='utterance_nearest_38_40_42_v1'
files={Path(__file__),ROOT/'tools/build_verified.py',ROOT/'docs/语速与噪声鲁棒版20261023.md',
       ROOT/'voice/tools/prepare_robust_rtl.py',ROOT/'archive/before_voice_robust_20261023/aca_kws_engine.v'}
tests={}
for name in ['voice_robust_rtl','voice_robust_noise','voice_feedback','dual_board_music','music_diagnostics','antiglitch']:
 p=ROOT/'verification'/(name+'.json');data=json.loads(p.read_text());assert data['passed'],name
 for s,d in data['sources'].items():assert sha(ROOT/s)==d,(name,s);files.add(ROOT/s)
 if name=='voice_robust_rtl':
  assert not data['candidate']
  for case,result in data['cases'].items():
   log=ROOT/'verification'/('robust_'+case+'.run.log');assert sha(log)==result['log_sha256'];files.add(log)
 if 'log_sha256' in data:
  logs={'voice_feedback':'voice_feedback.run.log','dual_board_music':'tb_dual_board_music.run.log','music_diagnostics':'music_diagnostics.run.log'}
  log=ROOT/'verification'/logs[name];assert sha(log)==data['log_sha256'];files.add(log)
 if name=='antiglitch':
  for case in data['cases']:
   log=ROOT/'verification'/(case['name']+'.run.log');assert sha(log)==case['log_sha256'];files.add(log)
 tests[name]=data;files.add(p)
for split in ['validation','test']:
 p=exp/(split+'_comparison.json');data=json.loads(p.read_text())
 for s,d in data['source_sha256'].items():assert sha(ROOT/s)==d,(split,s);files.add(ROOT/s)
 assert data['overall']['candidate']['correct']>data['overall']['baseline']['correct']
 assert data['overall']['candidate']['wrong_direction']<data['overall']['baseline']['wrong_direction']
 assert data['overall']['candidate']['false_accepts']<data['overall']['baseline']['false_accepts']
 files.add(p)
training=json.loads((exp/'training.json').read_text());assert sha(exp/'model/weights.mem')==training['weight_sha256']
for s,d in training['sources'].items():assert sha(ROOT/s)==d;files.add(ROOT/s)
files.add(exp/'training.json')
dst=ROOT.parents[1]/'deliverable/voice_robust_20261023';dst.mkdir(exist_ok=False)
for board,build in builds.items():
 bit=ROOT/board/'deliverable'/(board+'_liantiao.bit')
 shutil.copy2(bit,dst/('aca420_voice_robust.bit' if board=='aca420' else 'hx4s20_voice_feedback.bit'))
 for name in ['verified_build_inputs.json','final_timing_status.txt','final_timing.rpt','final_area.rpt']:
  shutil.copy2(ROOT/board/name,dst/(board+'_'+name))
 files.update(ROOT/s for s in build['inputs']['files'])
 assert sha(bit)==sha(dst/('aca420_voice_robust.bit' if board=='aca420' else 'hx4s20_voice_feedback.bit'))
assert sha(dst/'hx4s20_voice_feedback.bit')==sha(baseline/'hx4s20_voice_feedback.bit')
for p in files:
 target=dst/'source_snapshot'/p.relative_to(ROOT);target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,target)
manifest=ROOT.parents[1]/'voice/data/manifest.json';assert sha(manifest)==training['data_manifest_sha256']
shutil.copy2(manifest,dst/'training_data_manifest.json')
shutil.copy2(ROOT/'docs/语速与噪声鲁棒版20261023.md',dst/'上板测试说明.md')
record=dict(created_utc=datetime.now(timezone.utc).isoformat(),baseline='voice_feedback_20261023',
 hardware_tested=False,synthetic_only=True,normal_clean_accuracy_regressed=True,
 hx_bitstream_reused=True,builds=builds,tests=tests,
 files={str(p.relative_to(dst)):sha(p) for p in dst.rglob('*') if p.is_file()})
(dst/'release_manifest.json').write_text(json.dumps(record,ensure_ascii=False,indent=2),encoding='utf8')
for s,d in record['files'].items():assert sha(dst/s)==d,s
print('PASS robust voice build/test/source/ROM/release hashes:',dst)
