"""Run focused production-RTL checks and retain honest per-case results."""
from pathlib import Path
import subprocess,json,sys,time,hashlib,re
from concurrent.futures import ThreadPoolExecutor

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'verification'
OUT.mkdir(exist_ok=True)
PS=['powershell','-NoProfile','-ExecutionPolicy','Bypass','-File']
cases=[
 ('aca_peripherals_and_real_model',PS+['aca420/sim/run_tests.ps1']),
 ('video_pipeline',PS+['hx4s20/sim/run_top_video_pipeline.ps1']),
 ('music_controls',[sys.executable,'sim/run_music_controls.py']),
 ('dual_board_music',[sys.executable,'sim/run_dual_board_music.py']),
 ('music_frequency_probe',[sys.executable,'sim/run_music_frequency_probe.py']),
 ('music_prefetch',[sys.executable,'sim/run_music_prefetch.py']),
 ('storage_wav_and_music_fx',PS+['sim/run_music_tests.ps1']),
 ('zoom',PS+['sim/run_zoom_tests.ps1']),
]
def run(case):
 name,args=case;start=time.time()
 try:
  cp=subprocess.run(args,cwd=ROOT,capture_output=True,timeout=600)
  log=cp.stdout+cp.stderr
  (OUT/(name+'.integration.log')).write_bytes(log)
  s=log.decode('utf-8',errors='replace')
  ok=cp.returncode==0 and 'PASS' in s and not re.search(r'(?:ERROR:|FATAL:)',s)
  result=dict(name=name,passed=ok,returncode=cp.returncode,seconds=round(time.time()-start,1),log=name+'.integration.log',summary=s[-1500:])
 except Exception as exc:
  result=dict(name=name,passed=False,error=str(exc),seconds=round(time.time()-start,1))
 print(json.dumps(result,ensure_ascii=False),flush=True)
 return result

if __name__=='__main__':
 # Pipeline script generates its external-peripheral simulation declarations;
 # run it before the dual-board Python tests consume those declarations.
 results=[run(cases[1])]
 with ThreadPoolExecutor(max_workers=2) as pool:
  results.extend(pool.map(run,[c for i,c in enumerate(cases) if i!=1]))
 manifest={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
           for folder in ['aca420/rtl','hx4s20/hdl','common','voice/model_ctc']
           for p in (ROOT/folder).rglob('*') if p.is_file()}
 record=dict(passed=all(r['passed'] for r in results),simulation_only=True,cases=results,source_hashes=manifest)
 (OUT/'showcase_regressions.json').write_text(json.dumps(record,ensure_ascii=False,indent=2),encoding='utf-8')
 sys.exit(0 if record['passed'] else 1)
