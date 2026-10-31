"""Compile real production CTC RTL; keep compiler warnings as diagnostics."""
from pathlib import Path
import argparse,subprocess,json,re,sys

def main():
 parser=argparse.ArgumentParser()
 parser.add_argument('--iverilog')
 parser.add_argument('--output',default='verification')
 args=parser.parse_args()
 board=Path(__file__).resolve().parents[1];root=board.parent
 iv=Path(args.iverilog) if args.iverilog else root/'tools/iverilog/app/bin/iverilog.exe'
 out=board/args.output;out.mkdir(parents=True,exist_ok=True)
 cases={
  'tb_audio_top':list((board/'rtl').glob('*.v'))+list((root/'common').glob('*.v')),
  'tb_ctc_model_rom':[board/'rtl/aca_ctc_engine.v'],
  'tb_i2s_capture':[board/'rtl/aca_i2s_capture.v'],
  'tb_clap_detector':[board/'rtl/aca_clap_detector.v'],
  'tb_uart_report':[board/'rtl/aca_uart_report.v'],
  'tb_es8388_init':[board/'rtl'/s for s in ['aca_es8388_init.v','aca_i2c_control.v','aca_i2c_bit_shift.v']],
 }
 cases['tb_audio_top']=[p for p in cases['tb_audio_top'] if p.name!='aca_audio_pll.v']
 results=[]
 for name,sources in cases.items():
  binary=out/(name+'.vvp')
  cp=subprocess.run([str(iv),'-g2012','-Wall','-s',name,'-o',str(binary),*map(str,sources),str(board/'sim'/(name+'.v'))],cwd=board,capture_output=True)
  (out/(name+'.compile.log')).write_bytes(cp.stdout+cp.stderr)
  if cp.returncode:
   print((cp.stdout+cp.stderr).decode(errors='replace'));return 1
  cp=subprocess.run([str(iv.with_name('vvp.exe')),str(binary)],cwd=board,capture_output=True,timeout=180)
  (out/(name+'.run.log')).write_bytes(cp.stdout+cp.stderr)
  s=(cp.stdout+cp.stderr).decode(errors='replace')
  print(s,flush=True)
  passed=cp.returncode==0 and 'PASS' in s and not re.search(r'ERROR:|FATAL:|Unable to open|Not enough words',s)
  results.append(dict(name=name,passed=passed))
  if not passed:return 1
 (out/'regressions.json').write_text(json.dumps(results,indent=2))
 return 0
if __name__=='__main__':sys.exit(main())
