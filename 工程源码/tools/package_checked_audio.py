"""Publish only matching CRC source, tests and fresh timing-checked bitstreams."""
from pathlib import Path
from datetime import datetime,timezone
import hashlib,json,re,shutil
from build_verified import validate_record

ROOT=Path(__file__).resolve().parents[1]
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    builds={b:validate_record(b) for b in ['aca420','hx4s20']}
    tests={}
    for name in ['checked_audio','dual_board_music','effect_render','echo_test','audio_skew','music_diagnostics']:
        p=ROOT/'verification'/(name+'.json');data=json.loads(p.read_text())
        assert data['passed'],name
        for src,digest in data['sources'].items():assert sha(ROOT/src)==digest,(name,src)
        if name=='checked_audio':
            assert data['passed']==31 and len(data['cases'])==31
            assert {(c['phase_ns'],c['one_way_delay_ns']) for c in data['cases']}=={
                (p,d) for p in [0,3,7,11,15,19] for d in [0,5,20,35,50]}
            assert sum(c['full_tremolo'] for c in data['cases'])==1
            for c in data['cases']:
                log=ROOT/'verification'/(c['name']+'.run.log')
                assert sha(log)==c['log_sha256']
                assert 'PASS checked effects:' in log.read_text()
        elif name=='audio_skew':
            assert data['passed']==27 and len(data['cases'])==27
            assert any(c['lrck_skew_ns']==35 for c in data['cases'])
            assert any(c['lrck_skew_ns']<0 for c in data['cases'])
            for c in data['cases']:
                log=ROOT/'verification'/(c['name']+'.run.log')
                assert sha(log)==c['log_sha256']
                assert 'PASS checked effects:' in log.read_text()
        elif name=='effect_render':
            assert data['exact_sample_comparisons']==768000
            for audio,digest in data['audio'].items():
                assert sha(ROOT/'verification/effect_audio'/audio)==digest
        else:
            log=ROOT/'verification'/({'dual_board_music':'tb_dual_board_music.run.log',
                                     'echo_test':'tb_music_echo.run.log',
                                     'music_diagnostics':'music_diagnostics.run.log'}[name])
            assert sha(log)==data['log_sha256']
        tests[name]=data
    destination=ROOT.parents[1]/'deliverable/audio_crc_skewfix_20261021'
    if destination.exists():raise SystemExit('Refusing to overwrite release: '+str(destination))
    destination.mkdir(parents=True)
    report=dict(release='audio_crc_skewfix_20261021',created_utc=datetime.now(timezone.utc).isoformat(),
                source_project=str(ROOT),hardware_tested=False,
                protocol='32-bit slot PCM16 CRC15 pad; both boards must be updated together',
                effects=['bypass','85ms mono-wet echo with stereo dry','lowpass','5Hz stereo tremolo'],
                tests=tests,builds=builds,boards={})
    for board in builds:
        bit=ROOT/board/'deliverable'/(board+'_liantiao.bit')
        target=destination/(board+'_crc_skewfix.bit');shutil.copy2(bit,target)
        for name in ['final_area.rpt','final_timing_status.txt','verified_build_inputs.json','final_timing.rpt']:
            shutil.copy2(ROOT/board/name,destination/(board+'_'+name))
        area=(ROOT/board/'final_area.rpt').read_text()
        resources={k:int(re.search(r'^#'+k+r'\s+(\d+)',area,re.M)[1]) for k in ['lut','reg','bram','dsp','pll']}
        report['boards'][board]=dict(file=target.name,sha256=sha(target),resources=resources,
                                  timing=(ROOT/board/'final_timing_status.txt').read_text())
    shutil.copy2(ROOT/'docs/音效CRC版验收.md',destination/'上板测试说明.md')
    shutil.copy2(ROOT/'docs/FX_WAIT定位与时序修复.md',destination/'FX_WAIT定位与时序修复.md')
    shutil.copy2(ROOT/'verification/skew_before_failure.json',destination/'skew_before_failure.json')
    shutil.copytree(ROOT/'verification/effect_audio',destination/'DSP仿真试听')
    for name in tests:shutil.copy2(ROOT/'verification'/(name+'.json'),destination/(name+'.json'))
    (destination/'README.txt').write_text(
        '两板同时更新本目录成对的 *_crc_skewfix.bit。旧版与CRC版不兼容。\n'
        '这是经过数字仿真与内部时序检查的待上板测试版，尚未经实板播放验收。\n'
        '先关小音箱音量，不要首次戴耳机复测。详细操作见上板测试说明.md。\n'
        '修复独立帧时钟延迟导致的持续FX WAIT；加入去程/回程诊断。\n'
        'ACA S3长按约1秒：原声→回声→低通→颤音→原声。\n'
        'DSP仿真试听是HDL效果输出，不是实体双板录音。\n'
        '源码工程：'+str(ROOT)+'\n',encoding='utf-8')
    report['files']={str(p.relative_to(destination)):sha(p) for p in destination.rglob('*') if p.is_file()}
    (destination/'release_manifest.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    for name,digest in report['files'].items():assert sha(destination/name)==digest,name
    for board in builds:validate_record(board)
    print('PASS CRC audio release:',destination)
    print(json.dumps(report['boards'],ensure_ascii=False,indent=2))

if __name__=='__main__':main()
