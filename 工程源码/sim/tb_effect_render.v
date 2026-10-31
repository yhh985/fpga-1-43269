`timescale 1ns/1ps
// DSP audition only. Serial transport is checked in separate end-to-end tests.
module tb_effect_render;
 parameter FRAMES=96000;
 reg clk=0,rst=1,valid=0,channel=0;
 reg signed [15:0] pcm=0;
 reg [31:0] input_frames[0:FRAMES-1];
 wire q0,q1,q2,q3;
 always #10 clk=~clk;
 music_checked_fx fx0(.clk(clk),.rst(rst),.bclk(1'b0),.lrck(1'b0),.din(1'b0),.mode(2'd0),.dout(q0));
 music_checked_fx fx1(.clk(clk),.rst(rst),.bclk(1'b0),.lrck(1'b0),.din(1'b0),.mode(2'd1),.dout(q1));
 music_checked_fx fx2(.clk(clk),.rst(rst),.bclk(1'b0),.lrck(1'b0),.din(1'b0),.mode(2'd2),.dout(q2));
 music_checked_fx fx3(.clk(clk),.rst(rst),.bclk(1'b0),.lrck(1'b0),.din(1'b0),.mode(2'd3),.dout(q3));
 integer i,j,outfile;
 initial begin
  force fx0.sv=valid;force fx1.sv=valid;force fx2.sv=valid;force fx3.sv=valid;
  force fx0.ch=channel;force fx1.ch=channel;force fx2.ch=channel;force fx3.ch=channel;
  force fx0.pcm=pcm;force fx1.pcm=pcm;force fx2.pcm=pcm;force fx3.pcm=pcm;
  force fx0.good=1'b1;force fx1.good=1'b1;force fx2.good=1'b1;force fx3.good=1'b1;
  $readmemh("verification/dsp_input.mem",input_frames);
  outfile=$fopen("verification/dsp_output.txt","w");
  #100;@(negedge clk);rst=0;
  for(i=0;i<FRAMES;i=i+1)begin
   for(j=0;j<2;j=j+1)begin
    @(negedge clk);channel=j;pcm=j?input_frames[i][31:16]:input_frames[i][15:0];valid=1;
    @(negedge clk);valid=0;
    $fwrite(outfile,"%0d %0d %0d %0d ",$signed(fx0.limited),$signed(fx1.limited),$signed(fx2.limited),$signed(fx3.limited));
    repeat(4)@(negedge clk);
   end
   $fwrite(outfile,"\n");
  end
  $fclose(outfile);$display("PASS rendered %0d stereo DSP frames, all four modes",FRAMES);$finish;
 end
endmodule
