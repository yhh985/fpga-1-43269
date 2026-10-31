"""Package the request-retention fix with exact source/build/test provenance."""
from pathlib import Path
from datetime import datetime,timezone
import hashlib,json,re,shutil
from build_verified import validate_record
ROOT=Path(__file__).resolve().parents[1]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def package():
    builds={b:validate_record(b) for b in ('aca420','hx4s20')}
    files={Path(__file__),ROOT/'tools/build_verified.py'}
    tests={}
    for name in ['music_controls','dual_board_music','music_frequency_probe','music_prefetch']:
        record=ROOT/'verification'/(name+'.json');data=json.loads(record.read_text())
        assert data['passed'],name
        for source,digest in data['sources'].items():
            assert sha(ROOT/source)==digest,(name,source)
            files.add(ROOT/source)
        log=ROOT/'verification'/('tb_'+name+'.run.log')
        assert sha(log)==data['log_sha256'],name
        assert 'PASS' in log.read_text() and not re.search(r'FATAL|ERROR:',log.read_text()),name
        files.update([record,log,ROOT/'verification'/('tb_'+name+'.compile.log'),ROOT/'sim'/('run_'+name+'.py')])
        tests[name]=data
    for name in ['tb_music_prefetch.before.log','music_song_analysis.json','live_fix_regressions.json','zoom_regressions.json']:
        p=ROOT/'verification'/name
        if p.exists():files.add(p)
    doc=ROOT/'docs/音乐切图请求保留修复_20261029.md';files.add(doc)
    dst=ROOT.parents[1]/'deliverable/music_switch_queue_fix_20261029'
    assert not dst.exists(),dst
    dst.mkdir()
    for board,build in builds.items():
        source=ROOT/board/'deliverable'/(board+'_liantiao.bit')
        target=dst/(board+'_music_switch_queue_fix.bit')
        shutil.copy2(source,target);assert sha(source)==sha(target)
        for name in ['verified_build_inputs.json','final_timing_status.txt','final_timing.rpt','final_area.rpt','build_console.log']:
            shutil.copy2(ROOT/board/name,dst/(board+'_'+name))
        files.update(ROOT/source for source in build['inputs']['files'])
        files.add(ROOT/board/('aca420_audio.al' if board=='aca420' else 'contest_proj.al'))
    for source in sorted(files):
        target=dst/'source_snapshot'/source.relative_to(ROOT)
        target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,target)
    shutil.copy2(doc,dst/'烧录与操作说明.md')
    record=dict(created_utc=datetime.now(timezone.utc).isoformat(),project_root=str(ROOT),physical_board_test=False,
               现场原因='用户确认SW1未置ON',change='Retain/coalesce music requests during SD prefetch; preserve source/memory/reader ownership guards',
                builds=builds,tests=tests,files={str(p.relative_to(dst)):sha(p) for p in dst.rglob('*') if p.is_file()})
    (dst/'release_manifest.json').write_text(json.dumps(record,ensure_ascii=False,indent=2),encoding='utf8')
    for path,digest in record['files'].items():assert sha(dst/path)==digest,path
    print('PASS source-bound queue fix package:',dst)
if __name__=='__main__':package()
