"""Seal the response-feedback release against fresh builds and regressions."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import shutil
from build_verified import validate_record

ROOT = Path(__file__).resolve().parents[1]
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()

def package():
    builds = {b: validate_record(b) for b in ('aca420', 'hx4s20')}
    baseline = ROOT.parents[1] / 'deliverable/voice_capture_20261023'
    expected = {'common/link_sensor.v', 'aca420/rtl/aca420_audio_top.v'}
    for board, record in builds.items():
        old = json.loads((baseline / (board + '_verified_build_inputs.json')).read_text())
        assert set(old['inputs']['files']) == set(record['inputs']['files'])
        changed = {s.replace('\\', '/') for s, h in old['inputs']['files'].items() if sha(ROOT / s) != h}
        allowed = expected if board == 'aca420' else {'common/link_sensor.v'}
        assert changed == allowed, (board, changed)

    files = {Path(__file__), ROOT / 'tools/build_verified.py', ROOT / 'docs/voice_response_20261023.md'}
    tests = {}
    for name in ('feature_report', 'voice_reject_flags', 'voice_robust_rtl', 'voice_feedback',
                 'dual_board_music', 'music_diagnostics', 'antiglitch'):
        p = ROOT / 'verification' / (name + '.json')
        data = json.loads(p.read_text())
        assert data['passed'], name
        files.add(p)
        for s, h in data['sources'].items():
            assert sha(ROOT / s) == h, (name, s)
            files.add(ROOT / s)
        if 'log_sha256' in data:
            p = ROOT / 'verification' / ({'dual_board_music': 'tb_dual_board_music.run.log'}.get(name, name + '.run.log'))
            assert sha(p) == data['log_sha256'], name
            files.add(p)
        if name == 'voice_robust_rtl':
            for case, c in data['cases'].items():
                p = ROOT / 'verification' / ('robust_' + case + '.run.log')
                assert sha(p) == c['log_sha256']
                files.add(p)
        if name == 'antiglitch':
            for case in data['cases']:
                p = ROOT / 'verification' / (case['name'] + '.run.log')
                assert sha(p) == case['log_sha256']
                files.add(p)
        tests[name] = data

    # Supplementary storage and actual-board-clock tests produce plain logs.
    for name in ('tb_prefetch', 'tb_return_guard', 'tb_voice_noise', 'tb_link_board_clocks', 'tb_voice_image_link'):
        p = ROOT / 'verification' / (name + '.run.log')
        log = p.read_text(encoding='utf-8-sig')
        assert 'PASS' in log and not any(s in log for s in ('FATAL:', 'ERROR:')), name
        files.add(p)
        tests[name] = {'passed': True, 'simulation_only': True, 'log_sha256': sha(p)}
    files.update((ROOT / 'sim').glob('*.v'))
    files.update((ROOT / 'sim').glob('run*.py'))
    files.update((ROOT / 'sim').glob('run*.ps1'))
    files.update((ROOT / 'docs/research_voice_20261023').glob('*.txt'))
    files.update(ROOT / p for p in ('voice/tools/evaluate_dtw_candidate.py',
        'voice/experiments/dtw_pilot/validation_report.json',
        'verification/voice_capture_annotations_20261023.json'))

    dst = ROOT.parents[1] / 'deliverable/voice_response_20261023'
    dst.mkdir(exist_ok=False)
    for board, record in builds.items():
        shutil.copy2(ROOT / board / 'deliverable' / (board + '_liantiao.bit'), dst / (board + '_voice_response.bit'))
        for n in ('verified_build_inputs.json', 'final_timing_status.txt', 'final_timing.rpt', 'final_area.rpt'):
            shutil.copy2(ROOT / board / n, dst / (board + '_' + n))
        files.update(ROOT / s for s in record['inputs']['files'])
    for p in sorted(files):
        target = dst / 'source_snapshot' / p.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(p, target)
    shutil.copy2(ROOT / 'docs/voice_response_20261023.md', dst / '说明.md')
    record = dict(created_utc=datetime.now(timezone.utc).isoformat(), baseline='voice_capture_20261023',
        model_unchanged=True, recognition_accuracy_improved=False,
        end_to_end_two_second_hardware_target_verified=False, builds=builds, tests=tests,
        files={str(p.relative_to(dst)): sha(p) for p in dst.rglob('*') if p.is_file()})
    (dst / 'release_manifest.json').write_text(json.dumps(record, ensure_ascii=False, indent=2), encoding='utf-8')
    for p, h in record['files'].items():
        assert sha(dst / p) == h
    print('PASS source-bound response package:', dst)

if __name__ == '__main__':
    package()
