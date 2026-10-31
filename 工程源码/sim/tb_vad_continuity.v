`timescale 1ns/1ps
// Feed actual band powers, check every emitted feature against integer Python.
module tb_vad_continuity;
 parameter integer FRAMES=100,HYSTERESIS=1;
 reg clk=0,rst=1,result=0;always #10 clk=~clk;
 reg [31:0] powers[0:FRAMES*16-1];
 reg [7:0] expected[0:(FRAMES/2)*16-1];
 reg [31:0] p0,p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15;
 wire fv,done,fault;wire [3:0] fi;wire signed [7:0] fd;
 integer i,j,count=0,frames=0;
 aca_kws_frontend #(.ADAPTIVE_VAD(1),.VAD_HYSTERESIS(HYSTERESIS)) dut(
  .clk(clk),.rst(rst),.sample_valid(1'b0),.sample(16'sd0),
  .feature_valid(fv),.feature_index(fi),.feature_data(fd),.frame_done(done),.fault(fault));
 always @(negedge clk)if(!rst)begin
  if(fv)begin
   if(fi!==(count%16) || fd!==expected[count])
    $fatal(1,"feature mismatch at %0d actual=%0d expected=%0d",count,fd,expected[count]);
   count=count+1;
  end
  if(done)frames=frames+1;
 end
 initial begin
  $readmemh("verification/vad_powers.mem",powers);
  $readmemh("verification/vad_features.mem",expected);
  force dut.result=result;
  force dut.p[0]=p0;force dut.p[1]=p1;force dut.p[2]=p2;force dut.p[3]=p3;
  force dut.p[4]=p4;force dut.p[5]=p5;force dut.p[6]=p6;force dut.p[7]=p7;
  force dut.p[8]=p8;force dut.p[9]=p9;force dut.p[10]=p10;force dut.p[11]=p11;
  force dut.p[12]=p12;force dut.p[13]=p13;force dut.p[14]=p14;force dut.p[15]=p15;
  repeat(4)@(negedge clk);rst=0;
  for(i=0;i<FRAMES;i=i+1)begin
   p0=powers[i*16];p1=powers[i*16+1];p2=powers[i*16+2];p3=powers[i*16+3];
   p4=powers[i*16+4];p5=powers[i*16+5];p6=powers[i*16+6];p7=powers[i*16+7];
   p8=powers[i*16+8];p9=powers[i*16+9];p10=powers[i*16+10];p11=powers[i*16+11];
   p12=powers[i*16+12];p13=powers[i*16+13];p14=powers[i*16+14];p15=powers[i*16+15];
   result=1;@(negedge clk);result=0;repeat(70)@(negedge clk);
  end
  if(fault || count!=(FRAMES/2)*16 || frames!=FRAMES/2)$fatal(1,"counts/fault");
  $display("PASS VAD feature equivalence: %0d features hysteresis=%0d",count,HYSTERESIS);$finish;
 end
endmodule
