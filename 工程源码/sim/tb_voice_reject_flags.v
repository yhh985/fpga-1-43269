`timescale 1ns/1ps
module tb_voice_reject_flags;
 parameter QUIET=6;
 reg clk=0,rst=1,fv=0,done=0;reg [3:0] fi=0;reg signed [7:0] fd=0;
 always #10 clk=~clk;
 wire rejected,rv,ev;wire [7:0] flags;wire [6:0] voiced,duration;wire [15:0] seq;
 aca_kws_engine #(.COOLDOWN_CYCLES(0),.RELAXED_MARGIN(0),.PREQUIET_FRAMES(QUIET)) dut(.clk(clk),.rst(rst),.feature_valid(fv),
  .feature_index(fi),.feature_data(fd),.frame_done(done),.rejected_pulse(rejected),
  .result_valid(rv),.event_valid(ev),.reject_flags(flags),.debug_voiced(voiced),.debug_duration(duration),.debug_sequence(seq));
 integer i,k;
 task reset;begin rst=1;repeat(3)@(negedge clk);rst=0;end endtask
 task frame;input integer value;begin
  for(k=0;k<16;k=k+1)begin @(negedge clk);fv=1;fi=k;fd=value;end
  @(negedge clk);fv=0;done=1;@(negedge clk);done=0;
 end endtask
 task quiet;input integer n;begin for(i=0;i<n;i=i+1)frame(0);end endtask
 task speech;input integer n;begin for(i=0;i<n;i=i+1)frame(20);end endtask
 task check;input [7:0] expected;begin
  #1;if(flags!==expected)$fatal(1,"reject flags got %h expected %h",flags,expected);
 end endtask
 task final_pass;input integer a,b,c,prior,agree,vote,cool;input [7:0] expected;input integer accepted;begin
  reset;
  force dut.state=4;force dut.pass_index=2;
  // Icarus requires static task arguments for procedural force RHS.
  dut.logit0=a;dut.logit1=b;dut.logit2=c;dut.pass_flags=prior;
  dut.votes_ok=agree;dut.vote_class=vote;dut.cooldown=cool;
  @(negedge clk);check(expected);
  if(ev!==accepted || rejected!==!accepted)$fatal(1,"event/rejection pulse");
  release dut.state;release dut.pass_index;
 end endtask
 initial begin
  reset;quiet(48);speech(1);quiet(6);check(1);
  if(voiced!=1 || duration!=7 || seq!=1)$fatal(1,"short metadata");
  reset;quiet(48);speech(91);quiet(6);check(2);
  if(voiced!=91 || duration!=97)$fatal(1,"long metadata");
  reset;quiet(8);speech(6);quiet(6);check(8);
  reset;quiet(48);speech(6);quiet(6);wait(rv);repeat(3)@(negedge clk);
  speech(6);quiet(6);
  if(flags[2])$fatal(1,"192ms endpoint failed to rearm next utterance");
  wait(rv);repeat(3)@(negedge clk);
  final_pass(5000,0,0,0,1,0,0,8'h10,0);
  final_pass(999,1000,0,0,1,1,0,8'h20,0);
  final_pass(0,0,5000,0,1,1,0,8'h40,0);
  final_pass(0,5000,0,32,0,1,0,8'h20,0);
  final_pass(0,5000,0,0,1,1,1,8'h80,0);
  final_pass(0,5000,0,0,1,1,0,8'h00,1);
  $display("PASS rejection flags: short, long, prequiet, warmup, background, margin, consensus, prior failure, cooldown and valid command");$finish;
 end
 initial begin #100000000;$fatal(1,"reject watchdog");end
endmodule
