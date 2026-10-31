"""Seal diagnostic voice firmware without claiming recognition accuracy improved."""
from pathlib import Path
from datetime import datetime,timezone
import hashlib,json,shutil
from build_verified import validate_record,PROJECTS
ROOT=Path(__file__).resolve().parents[1]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
builds={b:validate_record(b) for b in ['aca420','hx4s20']}
baseline=ROOT.parents[1]/'deliverable/audio_antiglitch_20261023'
changes={}
for board in builds:
    old=json.loads((baseline/(board+'_verified_build_inputs.json')).read_text())
    delta=sorted(s for s,d in old['inputs']['files'].items() if sha(ROOT/s)!=d)
    allowed=({'aca420/rtl/aca420_audio_top.v','aca420/rtl/aca_kws_frontend.v','aca420/rtl/aca_kws_engine.v'}
             if board=='aca420' else {'hx4s20/hdl/mic_overlay.v','hx4s20/build_verified_separate.tcl'})
    assert {s.replace('\\','/') for s in delta}==allowed,delta
    changes[board]=delta
tests={}
for name in ['voice_feedback','real_voice_transient','music_diagnostics','dual_board_music','antiglitch']:
    data=json.loads((ROOT/'verification'/(name+'.json')).read_text())
    assert data['passed'],name
    for s,d in data['sources'].items():assert sha(ROOT/s)==d,(name,s)
    tests[name]=data
dst=ROOT.parents[1]/'deliverable/voice_feedback_20261023'
dst.mkdir(exist_ok=False)
files={Path(__file__),ROOT/'tools/build_verified.py',ROOT/'docs/语音状态反馈20261023.md'}
for board,build in builds.items():
    shutil.copy2(ROOT/board/'deliverable'/(board+'_liantiao.bit'),dst/(board+'_voice_feedback.bit'))
    for name in ['verified_build_inputs.json','final_timing_status.txt','final_timing.rpt','final_area.rpt']:
        shutil.copy2(ROOT/board/name,dst/(board+'_'+name))
    files.update(ROOT/s for s in build['inputs']['files'])
    files.add(ROOT/board/PROJECTS[board][0])
for name,data in tests.items():
    shutil.copy2(ROOT/'verification'/(name+'.json'),dst/(name+'.json'))
    files.update(ROOT/s for s in data['sources'])
    logs=[]
    if 'log_sha256' in data:
        log_name={'voice_feedback':'voice_feedback.run.log','music_diagnostics':'music_diagnostics.run.log',
                  'dual_board_music':'tb_dual_board_music.run.log'}[name]
        logs.append((log_name,data['log_sha256']))
    cases=data.get('cases',[])
    if isinstance(cases,list):logs.extend((c['name']+'.run.log',c['log_sha256']) for c in cases)
    else:logs.extend((k+'_transient.run.log',c['log_sha256']) for k,c in cases.items())
    for log,d in logs:
        path=ROOT/'verification'/log;assert sha(path)==d,(name,log);files.add(path)
for p in files:
    target=dst/'source_snapshot'/p.relative_to(ROOT)
    target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,target)
shutil.copy2(ROOT/'docs/语音状态反馈20261023.md',dst/'上板测试说明.md')
record=dict(created_utc=datetime.now(timezone.utc).isoformat(),release='voice_feedback_20261023',
            baseline='audio_antiglitch_20261023',hardware_tested=False,recognition_accuracy_improved=False,
            changed_inputs=changes,builds=builds,tests=tests,
            files={str(p.relative_to(dst)):sha(p) for p in dst.rglob('*') if p.is_file()})
(dst/'release_manifest.json').write_text(json.dumps(record,ensure_ascii=False,indent=2),encoding='utf-8')
for p,d in record['files'].items():assert sha(dst/p)==d,p
print('PASS voice feedback source/build/test/package hashes:',dst)
