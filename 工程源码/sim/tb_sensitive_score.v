`timescale 1ns/1ps
module tb_sensitive_score;
 reg clk=0,rst=1;always #10 clk=~clk;
 wire ev,rejected;wire [1:0] cmd;wire [7:0] flags;
 aca_kws_engine #(.CONSENSUS_PASSES(1),.MIN_MARGIN(109),.MIN_WINNER_SCORE(0),
 .RELAXED_MARGIN(0),.COOLDOWN_CYCLES(0)) dut(.clk(clk),.rst(rst),
 .feature_valid(1'b0),.feature_index(4'd0),.feature_data(8'sd0),.frame_done(1'b0),
 .event_valid(ev),.event_command(cmd),.rejected_pulse(rejected),.reject_flags(flags));
 task trial;input integer direction,score,margin,accept;begin
  rst=1;repeat(3)@(negedge clk);rst=0;
  dut.state=4;dut.pass_index=0;
  dut.logit0=score-margin;dut.logit1=direction==1?score:score-margin-1;
  dut.logit2=direction==2?score:score-margin-1;
  @(negedge clk);dut.state=0;
  if(ev!==accept || rejected!==!accept)$fatal(1,"score gate boundary");
  if(accept && cmd!=direction)$fatal(1,"score direction");
 end endtask
 initial begin
  trial(1,0,109,1);trial(2,0,109,1);trial(1,1000,108,0);
  trial(1,-1,1000,0);trial(2,-1,1000,0);trial(1,1,109,1);
  $display("PASS sensitive support gate: signed zero boundary, exact margin, negative evidence veto and both directions");$finish;
 end
endmodule
