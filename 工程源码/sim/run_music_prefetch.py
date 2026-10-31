from pathlib import Path
import hashlib,json,subprocess
r=Path(__file__).resolve().parents[1]
names=['SD/fat32_bmp_source.v','SD/sd_media_arbiter.v','SD/wav_sector_reader.v','wav_pcm_parser.v','audio_pcm_fifo.v','SD/sd_card_bmp.v','SD/bmp_read.v','image_resizer.v','image_resizer_sd_quality.v','SD/sd_card_top.v','SD/sd_card_cmd.v','SD/sd_card_sec_read_write.v','SD/spi_master.v']
sources=[r/'hx4s20/hdl'/s for s in names]+[r/'sim/tb_music_prefetch.v']
iv=r/'tools/iverilog/app/bin/iverilog.exe'
out=r/'verification';binary=out/'tb_music_prefetch.vvp'
cp=subprocess.run([str(iv),'-g2012','-I',str(r/'hx4s20/hdl'),'-s','tb_music_prefetch','-o',str(binary),*map(str,sources)],capture_output=True,text=True)
(out/'tb_music_prefetch.compile.log').write_text(cp.stdout+cp.stderr)
assert cp.returncode==0,cp.stdout+cp.stderr
cp=subprocess.run([str(iv.with_name('vvp.exe')),str(binary)],capture_output=True,text=True,timeout=60)
log=out/'tb_music_prefetch.run.log';log.write_text(cp.stdout+cp.stderr)
print(cp.stdout+cp.stderr,flush=True)
assert cp.returncode==0 and 'PASS music prefetch:' in cp.stdout
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
(out/'music_prefetch.json').write_text(json.dumps(dict(passed=True,simulation_only=True,sources={str(p.relative_to(r)):sha(p) for p in sources},log_sha256=sha(log)),indent=2))
