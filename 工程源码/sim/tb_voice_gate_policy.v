`timescale 1ns/1ps
module tb_voice_gate_policy;
 reg clk=0,rst=1;always #10 clk=~clk;
 wire ev,rejected;wire [7:0] flags;wire [1:0] command;
 aca_kws_engine #(.COOLDOWN_CYCLES(0)) dut(.clk(clk),.rst(rst),
 .feature_valid(1'b0),.feature_index(4'd0),.feature_data(8'sd0),.frame_done(1'b0),
 .event_valid(ev),.event_command(command),.rejected_pulse(rejected),.reject_flags(flags));
 task reset;begin rst=1;repeat(3)@(negedge clk);rst=0;end endtask
 task pass;input integer n,direction,margin;begin
  @(negedge clk);dut.state=4;dut.pass_index=n;
  dut.logit0=direction==0?margin:0;
  dut.logit1=direction==1?margin:-100;
  dut.logit2=direction==2?margin:-100;
  // Background score 0 makes the command's actual winner/runner-up gap exact.
  if(direction==0)begin dut.logit1=0;dut.logit2=-100;end
  @(negedge clk);dut.state=0;
 end endtask
 task trial;input integer a,b,c,expect_accept;begin
  reset;pass(0,1,a);pass(1,1,b);pass(2,1,c);
  if(ev!==expect_accept || rejected!==!expect_accept)$fatal(1,"gate result %0d %0d %0d",a,b,c);
  if(expect_accept && (command!=1 || flags!=0))$fatal(1,"accepted command carried rejection flags");
 end endtask
 initial begin
  trial(791,791,791,1); // Existing acceptance is preserved.
  trial(650,1475,1475,1); // Both new boundaries exactly met.
  trial(649,1476,1475,0); // Strong average cannot override weak floor.
  trial(650,1474,1475,0); // Floor cannot override insufficient total.
  trial(790,2000,2000,1);
  trial(622,1083,671,0); // Captured weak NEXT stays rejected by this policy.
  reset;pass(0,1,2000);pass(1,0,2000);pass(2,1,2000);
  if(ev || !rejected)$fatal(1,"background pass overridden");
  reset;pass(0,1,2000);pass(1,2,2000);pass(2,1,2000);
  if(ev || !rejected)$fatal(1,"opposite direction overridden");
  reset;pass(0,2,650);pass(1,2,1475);pass(2,2,1475);
  if(!ev || command!=2)$fatal(1,"PREV not symmetric");
  $display("PASS recognition gate policy: strict acceptance, weak floor, total margin, exact boundaries, background/direction veto, captured weak rejection and PREV symmetry");$finish;
 end
 initial begin #100000;$fatal(1,"policy timeout");end
endmodule
