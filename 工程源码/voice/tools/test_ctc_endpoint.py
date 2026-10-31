"""Exercise separate raw/VAD capture, wrap, short-transient rejection, busy freeze."""
import subprocess,json
from export_ctc_fpga import ROOT

TB=r'''`timescale 1ns/1ps
module tb_ctc_endpoint;
reg clk=0;always #10 clk=~clk;
reg rst=1,fv=0,fd=0,fa=0;reg[3:0]fi=0;reg signed[7:0]data=0;
wire ev,reject;wire[1:0]cmd;
aca_ctc_engine dut(.clk(clk),.rst(rst),.feature_valid(fv),.feature_index(fi),.feature_data(data),.feature_active(fa),.frame_done(fd),.event_valid(ev),.event_command(cmd),.rejected_pulse(reject));
integer i,j;integer rejects=0;reg signed[7:0]saved;
always @(negedge clk)if(reject)rejects=rejects+1;
task frame;input active;input integer value;begin
 for(j=0;j<16;j=j+1)begin @(negedge clk);fv=1;fi=j;fa=active;data=value;end
 @(negedge clk);fv=0;fd=1;@(negedge clk);fd=0;
end endtask
initial begin
 repeat(4)@(negedge clk);rst=0;
 // Raw nonzero ambient spectrum must not start an utterance by itself.
 for(i=0;i<130;i=i+1)frame(0,23);
 if(dut.state!=0 || dut.utterance || ev)$fatal(1,"noise opened gate");
 for(i=0;i<2;i=i+1)frame(1,50);
 for(i=0;i<6;i=i+1)frame(0,23);
 if(rejects!=1 || dut.state!=0)$fatal(1,"short transient not rejected");
 // Three pre-roll frames plus 10 active + 6 trailing = 19 stored frames.
 for(i=0;i<10;i=i+1)frame(1,40+i);
 for(i=0;i<6;i=i+1)frame(0,23);
 if(dut.state!=1 || dut.clip_len!=19 || dut.debug_voiced!=10 || dut.debug_duration!=16)$fatal(1,"bad endpoint %d %d %d",dut.clip_len,dut.debug_voiced,dut.debug_duration);
 for(i=0;i<19;i=i+1)begin
  for(j=0;j<16;j=j+1)begin
   if($signed(dut.hist[((dut.clip_start+i)%128)*16+j])!=(i<3 || i>=13?23:40+i-3))$fatal(1,"bad pre-roll/ring at %d",i);
  end
 end
 saved=dut.hist[0];for(i=0;i<4;i=i+1)frame(1,64);
 if(dut.hist[0]!==saved)$fatal(1,"busy capture corrupted history");
 $display("PASS raw/VAD separation, transient rejection, ring wrap, exact endpoint, busy freeze");$finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
'''

def main():
    path=ROOT/'verification/tb_ctc_endpoint.v';path.write_text(TB)
    iver=ROOT/'tools/iverilog/app/bin/iverilog.exe';binary=ROOT/'verification/tb_ctc_endpoint.vvp'
    p=subprocess.run([str(iver),'-g2012','-s','tb_ctc_endpoint','-o',str(binary),str(ROOT/'aca420/rtl/aca_ctc_engine.v'),str(path)],cwd=ROOT,capture_output=True,text=True);assert p.returncode==0,p.stderr
    p=subprocess.run([str(iver.with_name('vvp.exe')),str(binary)],cwd=ROOT,capture_output=True,text=True,timeout=20)
    (ROOT/'verification/ctc_endpoint.log').write_text(p.stdout+p.stderr);print(p.stdout,p.stderr);assert p.returncode==0 and 'PASS' in p.stdout

if __name__=='__main__':main()
