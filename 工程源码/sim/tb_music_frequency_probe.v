`timescale 1ns/1ps
module tb_music_frequency_probe;
 reg clk=0,rst=1,valid=0;
 reg signed [11:0] pcm=0;
 wire ready,overflow;wire [1:0] band;wire [31:0] power;
 integer n,i,expected,tests=0;
 always #5 clk=~clk;
 music_frequency_probe dut(.clk(clk),.rst(rst),.sample_valid(valid),.sample_in(pcm),
  .result_valid(ready),.result_overflow(overflow),.peak_index(band),.peak_power(power));
 task reset_probe;begin
  @(negedge clk);rst=1;valid=0;@(negedge clk);rst=0;
 end endtask
 task put;input integer value;begin
  pcm=value;valid=1;@(negedge clk);
 end endtask
 task check;input integer wanted_band,wanted_loud;begin
  if(!ready || overflow || band!==wanted_band[1:0] || power!==(wanted_loud?32'd8192:32'd0))
   $fatal(1,"frequency probe case=%0d band=%d expected=%d power=%d loud=%d ready=%b",tests,band,wanted_band,power,wanted_loud,ready);
  valid=0;@(negedge clk);if(ready)$fatal(1,"result pulse repeated");tests=tests+1;
 end endtask
 initial begin
  // Exhaust every realizable crossing count, including saturation/wrap risks.
  for(n=0;n<=512;n=n+1)begin
   reset_probe;
   for(i=0;i<1024;i=i+1)put(i<2*n ? (i%2==0?-256:256) : 0);
   expected=n<7?0:n<13?1:n<26?2:3;
   check(expected,n!=0);
  end
  // Signed amplitude gate, deadband, full-scale negative and accepted-sample timing.
  for(n=0;n<7;n=n+1)begin
   reset_probe;
   for(i=0;i<1024;i=i+1)begin
    case(n)
     0:put(31);1:put(-31);2:put(i==1023?32:0);3:put(i==1023?-32:0);
     4:put(i==0?-2048:0);5:put(i%2==0?-8:8);
     6:begin
      valid=0;pcm=-2048;repeat(3)@(negedge clk);
      if(ready)$fatal(1,"unaccepted samples advanced window");put(0);
     end
    endcase
   end
   check(0,n>=2 && n<=4);
  end
  reset_probe;repeat(100)put(256);reset_probe;
  repeat(1023)put(0);if(ready)$fatal(1,"reset did not clear sample count");
  put(0);check(0,0);
  $display("PASS frequency probe: %0d windows, crossing counts 0..512, saturation, silence threshold, signed extrema, deadband, sample gaps and reset",tests);
  $finish;
 end
endmodule
