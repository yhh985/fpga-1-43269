`timescale 1ns/1ps
module tb_music_echo;
 reg clk=0,rst=1,sv=0,ch=0,good=1;
 reg signed [15:0] sample=0;
 wire signed [15:0] echo;
 always #10 clk=~clk;
 music_echo_delay dut(.clk(clk),.rst(rst),.sample_valid(sv),.channel(ch),
  .good(good),.sample(sample),.echo(echo));
 integer i,checks=0;
 task frame;input integer l,r,expected;begin
  @(negedge clk);ch=0;sample=l;sv=1;
  @(negedge clk);sv=0;
  if($signed(echo)!==expected)$fatal(1,"echo frame%0d got%0d expected%0d",i,$signed(echo),expected);
  checks=checks+1;repeat(3)@(negedge clk);
  ch=1;sample=r;sv=1;@(negedge clk);sv=0;repeat(4)@(negedge clk);
  if($signed(echo)!==expected)$fatal(1,"right channel wet mismatch");
 end endtask
 initial begin
  #100;@(negedge clk);rst=0;
  // Impulse must return exactly 4096 frames later, never as uninitialized RAM.
  for(i=0;i<8200;i=i+1)
   frame(i==0?16000:0,i==0?8000:0,i==4096?12000:0);
  for(i=0;i<8200;i=i+1)frame(32767,-32768,i>=4096?-1:0);
  good=0;frame(0,0,0);good=1;
  for(i=0;i<4100;i=i+1)frame(-32768,-32768,i>=4096?-32768:0);
  $display("PASS echo: %0d exact stereo frames; 4096-frame impulse delay, signed limits, error flush, no stale RAM",checks);
  $finish;
 end
 initial begin #10000000;$fatal(1,"echo timeout");end
endmodule
