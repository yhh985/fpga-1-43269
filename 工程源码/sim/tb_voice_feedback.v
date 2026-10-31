`timescale 1ns/1ps
module tb_voice_feedback;
 reg clk=0,rst=1,fv=0,done=0;reg [3:0] fi=0;reg signed [7:0] fd=0;
 always #10 clk=~clk;
 wire ready,quiet,utterance,busy,rejected,result,fault;
 aca_kws_engine dut(.clk(clk),.rst(rst),.feature_valid(fv),.feature_index(fi),
  .feature_data(fd),.frame_done(done),.result_valid(result),.result_class(),
  .event_valid(),.event_command(),.fault(fault),.window_ready(ready),
  .quiet_ready(quiet),.utterance_active(utterance),.processing(busy),.rejected_pulse(rejected));
 integer rejects=0,k,i;reg saw_busy=0;
 always @(posedge clk)begin if(rejected)rejects=rejects+1;if(busy)saw_busy=1;end
 task frame;input integer value;begin
  for(k=0;k<16;k=k+1)begin @(negedge clk);fv=1;fi=k;fd=value;end
  @(negedge clk);fv=0;done=1;@(negedge clk);done=0;
 end endtask
 initial begin
  repeat(4)@(negedge clk);rst=0;
  if(ready || quiet || utterance || busy)$fatal(1,"reset feedback");
  for(i=0;i<48;i=i+1)frame(0);
  if(!ready || !quiet)$fatal(1,"warmup feedback");
  frame(20);
  if(!utterance || quiet)$fatal(1,"speech feedback");
  for(i=0;i<6;i=i+1)frame(0);
  repeat(4)@(negedge clk);
  if(utterance || rejects!=1 || busy)$fatal(1,"short phrase rejection feedback");
  for(i=0;i<10;i=i+1)frame(20);
  for(i=0;i<6;i=i+1)frame(0);
  wait(result);repeat(4)@(negedge clk);
  if(!saw_busy || fault || busy)$fatal(1,"inference feedback");
  $display("PASS voice feedback: warmup, prequiet, speech, short-utterance rejection, inference completion");
  $finish;
 end
 initial begin #20000000;$fatal(1,"feedback watchdog");end
endmodule
