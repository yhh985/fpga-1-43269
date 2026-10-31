"""Package ONLY completed timing-checked builds and record their provenance."""
import hashlib,json,re,shutil
from datetime import datetime,timedelta,timezone
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
LINK=ROOT.parent

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()

def main():
    out=ROOT/'deliverable';out.mkdir(exist_ok=True)
    audit=json.loads((ROOT/'verification/rom_audit.json').read_text())
    assert audit['passed'] and audit['weight_sha256']==sha(ROOT/'model/weights.mem')
    rtl=json.loads((ROOT/'verification/rtl_results.json').read_text())
    assert 'PASS Mel powers' in rtl['mel_powers']
    assert all('PASS' in s for s in rtl.values())
    tests={}
    music=LINK/'verification/music_regressions.json'
    rows=json.loads(music.read_text(encoding='utf-8-sig'))
    assert len(rows)>=6 and all(r['passed'] for r in rows)
    tests['music']=dict(passed=len(rows),sha256=sha(music))
    for board,path in [('common',LINK/'verification/regressions.json'),
                       ('aca420',LINK/'aca420/verification/regressions.json')]:
        rows=json.loads(path.read_text(encoding='utf-8-sig'))
        assert all(r['passed'] for r in rows)
        tests[board]=dict(passed=len(rows),sha256=sha(path))
    for name in ['tb_playback_top_keys','tb_top_video_pipeline']:
        path=LINK/'hx4s20/sim/audit_work'/(name+'.log')
        assert 'ALL TESTS PASSED' in path.read_text()
        tests[name]=dict(passed=True,sha256=sha(path))
    scheduler=ROOT/'verification/tb_voice_scheduler.run.log'
    assert 'PASS SD voice scheduler' in scheduler.read_text()
    result={}
    for board,bit in [('aca420','deliverable/aca420_liantiao.bit'),('hx4s20','contest_proj_Runs/best_result/contest_proj.bit')]:
        folder=LINK/board
        assert 'VERIFIED_BUILD_COMPLETE' in (folder/'verified_build_complete.txt').read_text()
        timing=(folder/'final_timing_status.txt').read_text()
        for prefix in ['S','H']:
            m=re.search(prefix+r'WNS:\s*(-?[\d.]+)ns,\s*'+prefix+r'TNS:\s*(-?[\d.]+)ns',timing)
            assert m and float(m[1])>=0 and float(m[2])==0,timing
        source=folder/bit
        target=out/(board+'_voice_test.bit')
        shutil.copy2(source,target)
        for name in ['final_timing_status.txt','final_area.rpt']:
            shutil.copy2(folder/name,out/(board+'_'+name))
        result[board]=dict(file=target.name,bytes=target.stat().st_size,sha256=sha(target),timing=timing.strip())
    sources={str(p.relative_to(LINK)):sha(p)
             for folder in [LINK/'common',LINK/'aca420/rtl',LINK/'hx4s20/hdl']
             for p in folder.rglob('*') if p.is_file() and p.suffix in ['.v','.vh']}
    model={p.name:sha(p) for p in (ROOT/'model').iterdir() if p.name in ['weights.mem','bias.mem','config.json']}
    evaluation=json.loads((ROOT/'verification/streaming_tts.json').read_text())
    training=json.loads((ROOT/'verification/training.json').read_text())
    assert training['weight_sha256']==model['weights.mem']
    assert evaluation['weight_sha256']==model['weights.mem']
    tools={p.name:sha(p) for p in (ROOT/'tools').glob('*.py')}
    manifest=dict(date=datetime.now(timezone(timedelta(hours=8))).isoformat(),boards=result,
                  model=model,sources=sources,tools=tools,tests=tests,rtl=rtl,rom_audit=audit,
                  training_report_sha256=sha(ROOT/'verification/training.json'),
                  evaluation_report_sha256=sha(ROOT/'verification/streaming_tts.json'),
                  status='EXPERIMENTAL - no real-person or board testing',
                  evaluation=evaluation['confusion'],
                  evaluation_summary={k:evaluation[k] for k in ['command_correct','command_count','wrong_direction','false_accepts']})
    (out/'release_manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf8')
    for board,info in result.items():print(board,info)

if __name__=='__main__':main()
