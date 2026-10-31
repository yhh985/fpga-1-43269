"""Inject asynchronous cable spikes into each audio wire, then run UART recovery."""
from pathlib import Path
import hashlib, json, subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT/'verification'
IVER = ROOT/'tools/iverilog/app/bin/iverilog.exe'
SOURCES = ['common/music_fx_return.v', 'common/link_packet.v',
           'common/link_host.v', 'common/link_sensor.v', 'common/uart_rx.v',
           'common/uart_tx.v', 'sim/tb_music_checked.v', 'sim/tb_link.v',
           'sim/tb_packet.v', 'sim/run_antiglitch.py', 'sim/tb_uart_antiglitch.v']
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
snapshot = {s: sha(ROOT/s) for s in SOURCES}
rows = []

def run(name, top, sources, parameters=()):
    binary = OUT/(name+'.vvp')
    cp = subprocess.run([str(IVER), '-g2012', '-s', top, *parameters,
                         '-o', str(binary), *sources], cwd=ROOT,
                        capture_output=True, text=True, timeout=60)
    (OUT/(name+'.compile.log')).write_text(cp.stdout+cp.stderr)
    assert cp.returncode == 0, cp.stdout+cp.stderr
    cp = subprocess.run([str(IVER.with_name('vvp.exe')), str(binary)], cwd=ROOT,
                        capture_output=True, text=True, timeout=360)
    log = OUT/(name+'.run.log')
    log.write_text(cp.stdout+cp.stderr)
    assert cp.returncode == 0 and 'PASS' in cp.stdout, cp.stdout+cp.stderr
    rows.append(dict(name=name, log_sha256=sha(log)))
    print(cp.stdout, flush=True)

for noise in range(1, 5):
    run(f'antiglitch_audio_{noise}', 'tb_music_checked',
        ['hx4s20/hdl/audio_wav_i2s.v', 'common/music_fx_return.v',
         'hx4s20/hdl/I2S_receiver.v', 'sim/tb_music_checked.v'],
        ['-Ptb_music_checked.QUICK=1', f'-Ptb_music_checked.NOISE={noise}'])
for name in ['tb_link', 'tb_packet']:
    run('antiglitch_'+name, name, SOURCES[1:6]+['sim/'+name+'.v'])
run('antiglitch_uart', 'tb_uart_antiglitch', SOURCES[1:6]+['sim/tb_uart_antiglitch.v'])
assert snapshot == {s: sha(ROOT/s) for s in SOURCES}
(OUT/'antiglitch.json').write_text(json.dumps(dict(passed=True, sources=snapshot,
    cases=rows, hardware_tested=False), indent=2))
