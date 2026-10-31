`timescale 1ns/1ps
module tb_analysis;
 reg clk=0,rst=1,valid=0;reg signed [15:0] sample=0;
 always #5 clk=~clk;
 wire [63:0] bars;wire [127:0] wave;wire overrun,overflow;
 aca_analysis dut(.clk(clk),.rst(rst),.sample_valid(valid),.sample(sample),.bars(bars),.waveform(wave),.overrun(overrun),.overflow(overflow));
 integer n,k,low_count,high_count;reg [7:0] height;
 task send;input signed [15:0] v;begin
  @(negedge clk);sample=v;valid=1;@(negedge clk);valid=0;
  repeat(98)@(negedge clk);
 end endtask
 initial begin
  repeat(5)@(negedge clk);rst=0;
  for(n=0;n<2048;n=n+1)send((n%64)<32?16'sd6000:-16'sd6000);
  repeat(100)@(negedge clk);height=bars[23:16];
  if(height<60 || overrun || overflow)$fatal(1,"750Hz spectrum or DSP fault");
  low_count=0;high_count=0;
  for(k=0;k<16;k=k+1)begin
   if(wave[k*8+:8]==104)low_count=low_count+1;
   if(wave[k*8+:8]==151)high_count=high_count+1;
  end
  if(low_count==0 || high_count==0)$fatal(1,"waveform alias or incomplete capture");
  for(n=0;n<6144;n=n+1)send(0);
  repeat(100)@(negedge clk);
  if(wave!=={16{8'd128}})$fatal(1,"silence timeout did not refresh waveform");
  if(bars[23:16]>=height)$fatal(1,"spectrum decay missing");
  rst=1;repeat(3)@(negedge clk);
  if(bars!==0 || wave!=={16{8'd128}})$fatal(1,"reset");
  $display("PASS analysis: real 750Hz square PCM, 8-bin processing, triggered nonflat waveform, silence refresh/decay, reset");$finish;
 end
 initial begin #10000000;$fatal(1,"analysis watchdog");end
endmodule

