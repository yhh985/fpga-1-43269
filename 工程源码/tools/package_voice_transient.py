"""Package the verified ACA voice change with the compatible unchanged HX bit."""
from pathlib import Path
from datetime import datetime,timezone
import hashlib,json,shutil
from build_verified import validate_record

ROOT=Path(__file__).resolve().parents[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()

def main():
    builds={b:validate_record(b) for b in ['aca420','hx4s20']}
    report={}
    paths=[ROOT/'verification/real_voice_transient.json',ROOT/'voice/verification/continuous_noise.json',
           ROOT/'verification/voice_rejection_audit_noise0.json',ROOT/'verification/voice_rejection_audit_noise250.json',
           *[ROOT/'verification'/(n+'.json') for n in ['checked_audio','dual_board_music','effect_render','echo_test','audio_skew','music_diagnostics']]]
    for p in paths:
        data=json.loads(p.read_text())
        assert data.get('passed',True),p
        for src,digest in data['sources'].items():
            srcpath=Path(src)
            assert sha(srcpath if srcpath.is_absolute() else ROOT/srcpath)==digest,(p,src)
        if 'policies' in data:assert data['policies']['current_three_all']['false_accepts']==0
        report[p.name]=data
    real=report['real_voice_transient.json']
    assert real['recognized_correct']==1 and real['second_command_still_rejected']
    assert report['continuous_noise.json']['false_commands']==0
    destination=ROOT.parents[1]/'deliverable/voice_transient_20261021'
    destination.mkdir(exist_ok=False)
    # Copy a reviewable source snapshot containing every hashed build input.
    sources=set()
    for board,record in builds.items():
        for p in record['inputs']['files']:sources.add(ROOT/p)
        for name in ['verified_build_inputs.json','final_timing_status.txt','final_area.rpt','final_timing.rpt']:
            shutil.copy2(ROOT/board/name,destination/(board+'_'+name))
    sources.update([ROOT/'voice/tools/kws_common.py',ROOT/'voice/tools/test_real_transient.py',
                    ROOT/'voice/tools/audit_rejection.py',ROOT/'voice/tools/test_continuous_noise.py',
                    ROOT/'sim/tb_voice_transient.v',ROOT/'tools/build_verified.py',Path(__file__)])
    sources.add(ROOT/'verification/user_20261021_170604.wav')
    for p in sources:
        dst=destination/'source_snapshot'/p.relative_to(ROOT);dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,dst)
    for board,name in [('aca420','aca420_voice_transient.bit'),('hx4s20','hx4s20_crc_skewfix.bit')]:
        shutil.copy2(ROOT/board/'deliverable'/(board+'_liantiao.bit'),destination/name)
    previous=ROOT.parents[1]/'deliverable/audio_crc_skewfix_20261021/hx4s20_crc_skewfix.bit'
    assert sha(previous)==sha(destination/'hx4s20_crc_skewfix.bit'),'HX unexpectedly changed'
    for p in paths:shutil.copy2(p,destination/p.name)
    shutil.copy2(ROOT/'docs/语音短毛刺修复20261021.md',destination/'上板说明.md')
    (destination/'README.txt').write_text(
        'ACA使用aca420_voice_transient.bit；HX使用本目录hx4s20_crc_skewfix.bit。\n'
        '若HX已经是audio_crc_skewfix_20261021版，可以只更新ACA。\n'
        '仅修复短毛刺撤销安静资格的漏检，未训练模型。\n'
        '真实录音第一句上一张恢复；第二句下一张仍被短停顿门槛拒绝。\n'
        '独立说指令，间隔至少半秒。当前为待实板验收版。\n'
        'source_snapshot保留构建输入；原工程路径见build provenance，ROM绝对路径需相应调整才能异地重建。\n',encoding='utf-8')
    manifest=dict(release='voice_transient_20261021',created_utc=datetime.now(timezone.utc).isoformat(),
                  hardware_tested=False,model_retrained=False,real_recording_correct=1,real_recording_commands=2,
                  builds=builds,verification=report,
                  files={str(p.relative_to(destination)):sha(p) for p in destination.rglob('*') if p.is_file()})
    (destination/'release_manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
    for p,digest in manifest['files'].items():assert sha(destination/p)==digest,p
    print('PASS source, build, test and package hashes:',destination)

if __name__=='__main__':main()
