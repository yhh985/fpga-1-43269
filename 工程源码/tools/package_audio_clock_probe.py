"""Package input-clock diagnosis without claiming a hardware audio fix."""
from pathlib import Path
from datetime import datetime,timezone
import hashlib,json,shutil
from build_verified import validate_record,PROJECTS

ROOT=Path(__file__).resolve().parents[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()

def main(release='audio_clock_probe_20261021', bit_suffix='clock_probe',
         document='docs/FX_IN_CRC实板定位20261021.md', extra_files=()):
    builds={b:validate_record(b) for b in ['aca420','hx4s20']}
    names=['checked_audio','dual_board_music','effect_render','echo_test','audio_skew','music_diagnostics','music_clock_probe','real_voice_transient']
    tests={}
    for name in names:
        data=json.loads((ROOT/'verification'/(name+'.json')).read_text())
        assert data['passed'],name
        for src,digest in data['sources'].items():assert sha(ROOT/src)==digest,(name,src)
        tests[name]=data
    assert tests['checked_audio']['passed']==31 and tests['audio_skew']['passed']==27
    for name in ['checked_audio','audio_skew']:
        for case in tests[name]['cases']:
            assert sha(ROOT/'verification'/(case['name']+'.run.log'))==case['log_sha256']
    for name,log in [('dual_board_music','tb_dual_board_music.run.log'),('echo_test','tb_music_echo.run.log'),
                     ('music_diagnostics','music_diagnostics.run.log'),('music_clock_probe','music_clock_probe.run.log')]:
        assert sha(ROOT/'verification'/log)==tests[name]['log_sha256']
    for audio,digest in tests['effect_render']['audio'].items():
        assert sha(ROOT/'verification/effect_audio'/audio)==digest
    dst=ROOT.parents[1]/'deliverable'/release;dst.mkdir(exist_ok=False)
    files=set()
    for board,build in builds.items():
        shutil.copy2(ROOT/board/'deliverable'/(board+'_liantiao.bit'),dst/(board+'_'+bit_suffix+'.bit'))
        for name in ['verified_build_inputs.json','final_timing_status.txt','final_timing.rpt','final_area.rpt']:
            shutil.copy2(ROOT/board/name,dst/(board+'_'+name))
        files.update(ROOT/src for src in build['inputs']['files'])
        files.add(ROOT/board/PROJECTS[board][0])
    files.update([Path(__file__),ROOT/'tools/build_verified.py',ROOT/'sim/tb_music_clock_probe.v',
                  ROOT/'sim/run_music_clock_probe.py',ROOT/'sim/tb_music_diagnostics.v',
                  ROOT/'sim/run_music_diagnostics.py',ROOT/'sim/tb_dual_board_music.v',ROOT/'sim/run_dual_board_music.py',
                  ROOT/document,*(ROOT/p for p in extra_files)])
    for p in files:
        target=dst/'source_snapshot'/p.relative_to(ROOT);target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,target)
    for name in tests:shutil.copy2(ROOT/'verification'/(name+'.json'),dst/(name+'.json'))
    shutil.copy2(ROOT/document,dst/'上板定位说明.md')
    (dst/'README.txt').write_text(f'两板一起更新 *_{bit_suffix}.bit。\n'
        '本版未完成实板验收，不宣称已修复现场音效无声。\n'
        '支持FX CLK LOW / FX SLOT 64 / FX SLOT ERR，详见上板定位说明.md。\n'
        '保留上版语音短毛刺修复，模型权重不变。\n'
        'source_snapshot是原路径构建输入快照；ROM绝对路径异地重建需调整。\n',encoding='utf-8')
    manifest=dict(release=release,created_utc=datetime.now(timezone.utc).isoformat(),
                  hardware_tested=False,hardware_audio_fixed=False,purpose=('automatic clock order recovery with mandatory CRC' if bit_suffix=='autoclock' else 'measure actual ACA input clock ratio'),
                  builds=builds,tests=tests,
                  files={str(p.relative_to(dst)):sha(p) for p in dst.rglob('*') if p.is_file()})
    (dst/'release_manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
    for p,digest in manifest['files'].items():assert sha(dst/p)==digest,p
    print('PASS build/test/source/package hashes:',dst)

if __name__=='__main__':main()
