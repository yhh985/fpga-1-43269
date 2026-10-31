"""Package only fresh, source-bound build and regression evidence."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib, json, shutil
from build_verified import validate_record, PROJECTS

ROOT = Path(__file__).resolve().parents[1]
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
builds = {b: validate_record(b) for b in ['aca420', 'hx4s20']}
baseline = ROOT.parents[1]/'deliverable/audio_autoclock_20261021'
baseline_deltas = {}
for board in builds:
    old = json.loads((baseline/(board+'_verified_build_inputs.json')).read_text())
    delta = sorted(s for s, digest in old['inputs']['files'].items() if sha(ROOT/s) != digest)
    expected = {'common/link_packet.v', 'common/music_fx_return.v'}
    if board == 'hx4s20': expected.add('hx4s20/build_verified_separate.tcl')
    assert {s.replace('\\', '/') for s in delta} == expected, delta
    baseline_deltas[board] = delta
names = ['checked_audio', 'audio_skew', 'antiglitch', 'dual_board_music',
         'music_clock_probe', 'music_diagnostics', 'echo_test']
tests = {}
for name in names:
    data = json.loads((ROOT/'verification'/(name+'.json')).read_text())
    assert data['passed'], name
    for src, digest in data['sources'].items():
        assert sha(ROOT/src) == digest, (name, src, 'stale evidence')
    for case in data.get('cases', []):
        assert sha(ROOT/'verification'/(case['name']+'.run.log')) == case['log_sha256']
    tests[name] = data
assert tests['checked_audio']['passed'] == 31
assert tests['audio_skew']['passed'] == 27
dst = ROOT.parents[1]/'deliverable/audio_antiglitch_20261023'
dst.mkdir(exist_ok=False)
files = {Path(__file__), ROOT/'tools/build_verified.py',
         ROOT/'docs/杜邦线抗干扰20261023.md'}
for board, build in builds.items():
    shutil.copy2(ROOT/board/'deliverable'/(board+'_liantiao.bit'), dst/(board+'_antiglitch.bit'))
    for name in ['verified_build_inputs.json', 'final_timing_status.txt', 'final_timing.rpt', 'final_area.rpt']:
        shutil.copy2(ROOT/board/name, dst/(board+'_'+name))
    files.update(ROOT/s for s in build['inputs']['files'])
    files.add(ROOT/board/PROJECTS[board][0])
for name, data in tests.items():
    shutil.copy2(ROOT/'verification'/(name+'.json'), dst/(name+'.json'))
    files.update(ROOT/s for s in data['sources'])
    for case in data.get('cases', []):
        p = ROOT/'verification'/(case['name']+'.run.log')
        files.add(p)
for p in files:
    target = dst/'source_snapshot'/p.relative_to(ROOT)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(p, target)
shutil.copy2(ROOT/'docs/杜邦线抗干扰20261023.md', dst/'上板测试说明.md')
manifest = dict(release='audio_antiglitch_20261023',
    baseline='audio_autoclock_20261021', created_utc=datetime.now(timezone.utc).isoformat(),
    hardware_tested=False, baseline_changed_inputs=baseline_deltas, builds=builds, tests=tests,
    files={str(p.relative_to(dst)): sha(p) for p in dst.rglob('*') if p.is_file()})
(dst/'release_manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
for p, digest in manifest['files'].items():
    assert sha(dst/p) == digest, p
print('PASS source/build/test/package hashes:', dst)
