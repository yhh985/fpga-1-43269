`timescale 1ns/1ps
// Stereo frames cross as one word. Gray pointers, two synchronizer stages,
// asynchronous assertion and local synchronous release. No reset on RAM.
module audio_pcm_fifo #(parameter AB=12)(
 input rst, wclk, we, input [31:0] din,
 output reg full, output reg [AB:0] wused,
 input rclk, re, output reg [31:0] dout, output reg valid,
 output empty, output [AB:0] rused
);
 reg [1:0] wrs,rrs;
 always @(posedge wclk or posedge rst) if(rst)wrs<=3;else wrs<={wrs[0],1'b0};
 always @(posedge rclk or posedge rst) if(rst)rrs<=3;else rrs<={rrs[0],1'b0};
 reg [AB:0] wb,rb,wg,rg,rbin;
 (* async_reg="true" *) reg [AB:0] rg0,rg1,wg0,wg1;
 wire push=we&&!full&&!wrs[1];
 wire pop=re&&!empty&&!rrs[1];
 wire [AB:0] wn=wb+push, rn=rb+pop;
 wire [AB:0] wgn=(wn>>1)^wn, rgn=(rn>>1)^rn;
 function [AB:0] ungray;input [AB:0] g;integer i;begin
  ungray[AB]=g[AB];for(i=AB-1;i>=0;i=i-1)ungray[i]=ungray[i+1]^g[i];
 end endfunction
 assign empty=rg==wg1;

 assign rused=ungray(wg1)-rb;
 always @(posedge wclk or posedge rst)begin
  if(rst)begin wb<=0;wg<=0;rg0<=0;rg1<=0;full<=0;rbin<=0;wused<=0;end
  else if(wrs[1])begin wb<=0;wg<=0;rg0<=0;rg1<=0;full<=0;rbin<=0;wused<=0;end
  else begin
   rg0<=rg;rg1<=rg0;rbin<=ungray(rg1);wused<=wn-rbin;wb<=wn;wg<=wgn;
   full<=wgn=={~rg1[AB:AB-1],rg1[AB-2:0]};
  end
 end
 always @(posedge rclk or posedge rst)begin
  if(rst)begin rb<=0;rg<=0;wg0<=0;wg1<=0;valid<=0;end
  else if(rrs[1])begin rb<=0;rg<=0;wg0<=0;wg1<=0;valid<=0;end
  else begin wg0<=wg;wg1<=wg0;rb<=rn;rg<=rgn;valid<=pop;end
 end
 (* ram_style="bram" *) reg [31:0] mem[0:(1<<AB)-1];
 always @(posedge wclk)if(push)mem[wb[AB-1:0]]<=din;
 always @(posedge rclk)if(pop)dout<=mem[rb[AB-1:0]];
endmodule
