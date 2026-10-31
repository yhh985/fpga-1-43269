`timescale 1ns/1ps
module tb_voice_ram_pack;
 reg clk=0,rst=1,valid=0;reg signed [15:0] sample=0;
 always #5 clk=~clk;
 wire ready,overrun,overflow,old_ready,old_overrun,old_overflow;
 wire [31:0] power[0:15],old_power[0:15];
 kws_goertzel dut(.clk(clk),.rst(rst),.sample_valid(valid),.sample_in(sample),
 .result_valid(ready),.sample_overrun(overrun),.result_overflow(overflow),
 .power0(power[0]),.power1(power[1]),.power2(power[2]),.power3(power[3]),
 .power4(power[4]),.power5(power[5]),.power6(power[6]),.power7(power[7]),
 .power8(power[8]),.power9(power[9]),.power10(power[10]),.power11(power[11]),
 .power12(power[12]),.power13(power[13]),.power14(power[14]),.power15(power[15]));
 kws_goertzel_old baseline(.clk(clk),.rst(rst),.sample_valid(valid),.sample_in(sample),
 .result_valid(old_ready),.sample_overrun(old_overrun),.result_overflow(old_overflow),
 .power0(old_power[0]),.power1(old_power[1]),.power2(old_power[2]),.power3(old_power[3]),
 .power4(old_power[4]),.power5(old_power[5]),.power6(old_power[6]),.power7(old_power[7]),
 .power8(old_power[8]),.power9(old_power[9]),.power10(old_power[10]),.power11(old_power[11]),
 .power12(old_power[12]),.power13(old_power[13]),.power14(old_power[14]),.power15(old_power[15]));
 reg [15:0] inputs[0:1023];reg [31:0] golden[0:127],original[0:127];
 integer count=0,old_count=0,cycle=0,last_sample=0,max_latency=0,i,j;
 always @(posedge clk)cycle<=cycle+1;
 always @(negedge clk)if(!rst && old_ready)begin
  if(old_count>=8 || old_overrun || old_overflow)$fatal(1,"Original fault");
  for(j=0;j<16;j=j+1)original[old_count*16+j]=old_power[j];
  old_count=old_count+1;
 end
 always @(negedge clk)if(!rst && ready)begin
  if(count>=8 || overrun || overflow || old_count!=count+1)$fatal(1,"Packed RAM fault/count");
  for(j=0;j<16;j=j+1)
   if(power[j]!==golden[count*16+j] || power[j]!==original[count*16+j])
    $fatal(1,"Packed power mismatch frame %0d band %0d: %0d/%0d/%0d",count,j,power[j],golden[count*16+j],original[count*16+j]);
  if(cycle-last_sample>=6246)$fatal(1,"Actual board sample budget exceeded: %0d",cycle-last_sample);
  if(cycle-last_sample>max_latency)max_latency=cycle-last_sample;
  count=count+1;
 end
 initial begin
  $readmemh("mel_pcm8.mem",inputs);$readmemh("mel_powers.mem",golden);
  repeat(5)@(negedge clk);rst=0;
  repeat(17)begin
   @(negedge clk);valid=1;sample=32767;
   @(negedge clk);valid=0;repeat(6244)@(negedge clk);
  end
  rst=1;repeat(5)@(negedge clk);rst=0;
  for(i=0;i<1024;i=i+1)begin
   @(negedge clk);valid=1;sample=inputs[i];last_sample=cycle;
   @(negedge clk);valid=0;repeat(6244)@(negedge clk);
  end
  if(count!=8 || old_count!=8 || overrun || overflow)$fatal(1,"Result count/fault");
  $display("PASS packed RAM: 128 powers equal original and integer golden, reset; max %0d/6246 clocks",max_latency);
  $finish;
 end
 initial begin #100000000;$fatal(1,"Packed RAM timeout");end
endmodule
