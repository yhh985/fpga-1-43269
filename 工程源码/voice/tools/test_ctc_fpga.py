"""Check every RTL output logit against the quantized V5 reference."""
import argparse,json,subprocess,hashlib
from pathlib import Path
import numpy as np
import torch
import soundfile as sf
from export_ctc_fpga import ROOT,load,OUT
from train_masked_acoustic_codes import batch
from train_sequence_ctc import candidates
from kws_common import mel_powers,decimate

def resample(x,rate):
    n=max(8,round(len(x)/rate));pos=np.arange(n)*rate
    return np.floor(np.stack([np.interp(pos,np.arange(len(x)),x[:,j]) for j in range(16)],1)+.500001).astype(np.int8)

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--reuse-logs',action='store_true');args=ap.parse_args()
    torch.set_num_threads(2);net=load();audio,sr=sf.read(ROOT/'verification/user_20261021_170604.wav',dtype='int16')
    clips=candidates(mel_powers(decimate(np.r_[np.zeros(98304,dtype=np.int16),audio,np.zeros(73728,dtype=np.int16)])))
    report=[]
    for index,(x,*_) in enumerate(clips):
        source=ROOT/'verification/ctc_input.mem';source.write_text(''.join(f'{int(v):02x}\n' for v in x.ravel()))
        tb=f'''`timescale 1ns/1ps
module tb_ctc;
reg clk=0;always #10 clk=~clk;reg rst=1;wire rv,ev,fault;wire[1:0]cmd;
aca_ctc_engine dut(.clk(clk),.rst(rst),.feature_valid(1'b0),.feature_index(4'd0),.feature_data(8'd0),.feature_active(1'b0),.frame_done(1'b0),.result_valid(rv),.event_valid(ev),.event_command(cmd),.fault(fault));
reg[7:0] data[0:{x.size-1}];integer i,cycles=0;
initial begin $readmemh("verification/ctc_input.mem",data);repeat(4)@(negedge clk);rst=0;@(negedge clk);
for(i=0;i<{x.size};i=i+1)dut.hist[i]=data[i];
dut.clip_start=0;dut.clip_len={len(x)};dut.pass=0;dut.state=1;for(i=0;i<13;i=i+1)dut.totals[i]=0;
end
always @(negedge clk)if(!rst)begin
cycles=cycles+1;if(cycles>20000000)$fatal(1,"timeout");
if(dut.state==16 && dut.layer==3)$display("Z %0d %0d %0d %0d",dut.pass,dut.t,dut.ch,$signed(dut.scaled));
if(dut.state==40 && dut.phrase==0)for(i=0;i<13;i=i+1)$display("S %0d %0d",i,$signed(dut.totals[i]));
if(rv)begin $display("RESULT %0d %0d %0d %0d",ev,cmd,$signed(dut.best),$signed(dut.second));$finish;end
end
endmodule
'''
        test=ROOT/'verification/tb_ctc.v';test.write_text(tb);iver=ROOT/'tools/iverilog/app/bin/iverilog.exe';binary=ROOT/'verification/tb_ctc.vvp'
        if args.reuse_logs:
            p=subprocess.CompletedProcess([],0,stdout=(ROOT/f'verification/ctc_clip_{index}.log').read_text(),stderr='')
        else:
            p=subprocess.run([str(iver),'-g2012','-s','tb_ctc','-o',str(binary),str(ROOT/'aca420/rtl/aca_ctc_engine.v'),str(test)],cwd=ROOT,capture_output=True,text=True);assert p.returncode==0,p.stderr
            p=subprocess.run([str(iver.with_name('vvp.exe')),str(binary)],cwd=ROOT,capture_output=True,text=True,timeout=300)
            (ROOT/f'verification/ctc_clip_{index}.log').write_text(p.stdout+p.stderr);assert p.returncode==0,p.stdout[-2000:]+p.stderr
        expected=[]
        with torch.no_grad():
            for view,rate in enumerate([.8,1,1.25]):
                xx=resample(x,rate);bx,ln=batch([xx]);z,_=net(bx,ln);z=torch.round(z[0]*64).numpy().astype(int)
                expected.extend((view,t,c,int(z[t,c])) for t in range(len(xx)) for c in range(39))
        actual=[tuple(map(int,line.split()[1:])) for line in p.stdout.splitlines() if line.startswith('Z ')]
        mismatches=[(a,b) for a,b in zip(actual,expected) if a!=b]
        assert len(actual)==len(expected),(len(actual),len(expected))
        assert not mismatches,mismatches[:12]
        from evaluate_ctc_fixed import score,decode
        qscore=score(net,[x])[0]
        rtl_scores=np.array([int(s.split()[2]) for s in p.stdout.splitlines() if s.startswith('S ')])
        assert np.array_equal(qscore,rtl_scores),(qscore,rtl_scores)
        command=decode(qscore[None,:],[len(x)])[0][0]
        result=[s for s in p.stdout.splitlines() if s.startswith('RESULT ')];ev,cmd,*_=map(int,result[0].split()[1:])
        assert (ev,cmd)==(int(command!=0),command),result
        expected_commands=[1,1]
        assert command==expected_commands[index],(index,command)
        record=dict(clip=index,logits=len(actual),integer_logits_exact=True,q6_ctc_scores_exact=True,logs_reused=args.reuse_logs,result=result,scores=rtl_scores.tolist())
        report.append(record);print(json.dumps(record),flush=True)
    (ROOT/'verification/ctc_rtl.json').write_text(json.dumps(dict(cases=report,rtl_sha256=hashlib.sha256((ROOT/'aca420/rtl/aca_ctc_engine.v').read_bytes()).hexdigest()),indent=2))

if __name__=='__main__':main()
