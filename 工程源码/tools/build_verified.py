"""Run TD and bind the resulting bitstream to the exact build inputs."""
from pathlib import Path
import argparse, hashlib, json, re, shutil, subprocess, time
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
PROJECTS = {
    'aca420': ('aca420_audio.al', 'build_verified.tcl', 'deliverable/aca420_liantiao.bit'),
    'hx4s20': ('contest_proj.al', 'build_verified_separate.tcl', 'contest_proj_Runs/best_result/contest_proj.bit'),
}

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def inputs(board):
    folder = ROOT / board
    manifest, script, _ = PROJECTS[board]
    tree = ET.fromstring((folder/manifest).read_text(encoding='utf-8-sig').replace('Name="UsedInP&R"', 'Name="UsedInP&amp;R"'))
    declared = sorted({str((folder/e.attrib['Path']).resolve().relative_to(ROOT)) for e in tree.iter('File')})
    files = {ROOT/p for p in declared}
    files.add(folder/script)
    # Include readmemh/font/model/include dependencies even if TD does not list
    # them as source units. Ignore generated run directories and old backups.
    for base in [folder/'rtl', folder/'hdl', ROOT/'common', ROOT/'voice/model', ROOT/'voice/model_ctc']:
        if base.exists():
            files.update(p for p in base.rglob('*') if p.is_file() and p.suffix.lower() in
                         {'.v', '.vh', '.sv', '.mem', '.mif', '.hex', '.dat', '.json'})
    # Experimental voice ROMs may live outside voice/model. Bind literal
    # engine parameter paths as well, so a new ROM cannot escape provenance.
    for source in list(files):
        if source.suffix.lower() not in {'.v','.sv'}:continue
        for name in re.findall(r'\b(?:WEIGHTS_FILE|BIAS_FILE)\s*=\s*"([^"]+)"', source.read_text(encoding='utf-8-sig')):
            path=Path(name)
            if not path.is_absolute():path=folder/path
            assert path.is_file(),f'Missing ROM dependency: {path}'
            files.add(path)
            config=path.parent/'config.json'
            if config.is_file():files.add(config)
    return dict(declared_files=declared, files={str(p.relative_to(ROOT)): sha(p) for p in sorted(files)})

def validate_record(board):
    folder = ROOT/board
    record = json.loads((folder/'verified_build_inputs.json').read_text(encoding='utf-8'))
    assert record['passed'] and record['inputs'] == inputs(board), f'{board}: build inputs changed; rebuild required'
    manifest = str((folder/PROJECTS[board][0]).relative_to(ROOT))
    assert manifest in record['outputs'], f'{board}: missing final TD project configuration'
    for path, digest in record['outputs'].items():
        assert sha(ROOT/path) == digest, f'{board}: build output changed: {path}'
    assert 'VERIFIED_BUILD_COMPLETE' in (folder/'verified_build_complete.txt').read_text()
    return record

def build(board, td):
    folder = ROOT/board
    manifest, script, bit_path = PROJECTS[board]
    xml = folder/manifest
    normalize = lambda: xml.write_text(xml.read_text(encoding='utf-8-sig').replace('Name="UsedInP&R"', 'Name="UsedInP&amp;R"'), encoding='utf-8')
    normalize()
    marker = folder/'verified_build_complete.txt'
    record_path = folder/'verified_build_inputs.json'
    marker.unlink(missing_ok=True)
    record_path.unlink(missing_ok=True)
    snapshot = inputs(board)
    started = time.time()
    try:
        with (folder/'build_console.log').open('w', encoding='utf-8') as log:
            result = subprocess.run([td, script], cwd=folder, stdout=log, stderr=subprocess.STDOUT)
    finally:
        normalize()
    assert result.returncode == 0 and marker.is_file(), f'{board}: no completed TD build'
    assert marker.stat().st_mtime >= int(started), f'{board}: stale build marker'
    assert snapshot == inputs(board), f'{board}: input changed during build'
    timing = (folder/'final_timing_status.txt').read_text()
    for prefix in ['S', 'H']:
        match = re.search(prefix+r'WNS:\s*(-?[\d.]+)ns,\s*'+prefix+r'TNS:\s*(-?[\d.]+)ns', timing)
        assert match and float(match[1]) >= 0 and float(match[2]) == 0, f'{board}: timing failed'
    bit = folder/bit_path
    assert bit.stat().st_mtime >= int(started), f'{board}: stale bitstream'
    standard = folder/'deliverable'/f'{board}_liantiao.bit'
    standard.parent.mkdir(exist_ok=True)
    if bit.resolve() != standard.resolve():
        shutil.copy2(bit, standard)
    # TD saves its final run properties into the project. Seal that resulting
    # configuration as an output as well as the pre/post source dependency set.
    outputs = [bit, standard, xml, folder/'final_timing_status.txt', folder/'final_area.rpt', folder/'build_console.log']
    record = dict(passed=True, board=board, started_utc=datetime.fromtimestamp(started, timezone.utc).isoformat(),
                  finished_utc=datetime.now(timezone.utc).isoformat(), inputs=snapshot,
                  outputs={str(p.relative_to(ROOT)): sha(p) for p in outputs})
    record_path.write_text(json.dumps(record, indent=2), encoding='utf-8')
    validate_record(board)
    print(f'PASS {board}: fresh timing-checked bitstream bound to {len(snapshot["files"])} unchanged input files')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('board', choices=PROJECTS)
    parser.add_argument('--td', default='E:/Anlogic_fpga/bin/td_commands_prompt.exe')
    args = parser.parse_args()
    build(args.board, args.td)
