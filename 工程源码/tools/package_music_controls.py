"""Package the music controls only after validating builds and current tests."""
from pathlib import Path
from datetime import datetime,timezone
import hashlib,json,re,shutil
from build_verified import validate_record

ROOT=Path(__file__).resolve().parents[1]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()

def package():
    builds={b:validate_record(b) for b in ('aca420','hx4s20')}
    tests={}
    test_files=set()
    for name,log_name in [('music_controls','tb_music_controls'),
                          ('dual_board_music','tb_dual_board_music'),
                          ('music_frequency_probe','tb_music_frequency_probe')]:
        path=ROOT/'verification'/(name+'.json')
        data=json.loads(path.read_text())
        assert data['passed'],name
        for source,digest in data['sources'].items():
            assert sha(ROOT/source)==digest,(name,source,'stale simulation sources')
            test_files.add(ROOT/source)
        log=ROOT/'verification'/(log_name+'.run.log')
        assert sha(log)==data['log_sha256'],name
        contents=log.read_text()
        assert 'PASS' in contents and not re.search(r'FATAL|ERROR:',contents),name
        tests[name]=data
        test_files.update([path,log,ROOT/'verification'/(log_name+'.compile.log')])
    doc=ROOT/'docs/背景音乐与频率切图_20261029.md'
    files=test_files|{doc,Path(__file__),ROOT/'tools/build_verified.py',
        ROOT/'sim/run_music_controls.py',ROOT/'sim/run_dual_board_music.py',
        ROOT/'sim/run_music_frequency_probe.py'}
    for board,build in builds.items():
        files.update(ROOT/source for source in build['inputs']['files'])
    dst=ROOT.parents[1]/'deliverable/music_controls_20261029'
    dst.mkdir(exist_ok=False)
    for board,build in builds.items():
        source=ROOT/board/'deliverable'/(board+'_liantiao.bit')
        target=dst/(board+'_music_controls.bit')
        shutil.copy2(source,target)
        assert sha(source)==sha(target)
        for name in ['verified_build_inputs.json','final_timing_status.txt',
                     'final_timing.rpt','final_area.rpt','build_console.log']:
            shutil.copy2(ROOT/board/name,dst/(board+'_'+name))
        project='aca420_audio.al' if board=='aca420' else 'contest_proj.al'
        files.add(ROOT/board/project)
    for source in sorted(files):
        target=dst/'source_snapshot'/source.relative_to(ROOT)
        target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(source,target)
    shutil.copy2(doc,dst/'烧录与操作说明.md')
    record=dict(created_utc=datetime.now(timezone.utc).isoformat(),project_root=str(ROOT),
        builds=builds,tests=tests,physical_board_test=False,
        features=['ACA B1 background music toggle in manual/automatic mode',
                  'HX SW4 debounce and shared frame-boundary OSD enable',
                  'HX SW1 waveform frequency-band-change image switching in music mode'],
        frequency_method='1024-sample hysteretic zero crossings; four bands; not FFT or beat recognition',
        files={str(p.relative_to(dst)):sha(p) for p in dst.rglob('*') if p.is_file()})
    manifest=dst/'release_manifest.json'
    manifest.write_text(json.dumps(record,ensure_ascii=False,indent=2),encoding='utf-8')
    for path,digest in record['files'].items():assert sha(dst/path)==digest,path
    print('PASS source-bound two-board music controls package:',dst)
    print('Verified files:',len(record['files']))

if __name__=='__main__':package()
