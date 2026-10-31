`timescale 1ns/1ps
module tb_mic_overlay;
 reg clk=0,rst=1,vs=1,de=0,enable=1,online=1;
 always #5 clk=~clk;
 reg [255:0] status=0;reg [23:0] rgb=24'h123456;wire [23:0] out;
 mic_overlay dut(.clk(clk),.rst(rst),.vs(vs),.de(de),.enable(enable),.online(online),.status(status),.rgb(rgb),.out_rgb(out));
 integer x,y,i,count=0,b,h,w;reg [23:0] expected,col;
 initial begin
  status[7:0]=1;status[9:8]=1;status[12:10]=2;status[18:16]=5;
  for(i=0;i<8;i=i+1)status[32+i*8+:8]=(i+1)*15;
  for(i=0;i<16;i=i+1)status[96+i*8+:8]=i*16;
  repeat(5)@(negedge clk);rst=0;vs=0;repeat(2)@(negedge clk);
  for(y=0;y<480;y=y+1)begin
   for(x=0;x<640;x=x+1)begin
    de=1;#1;expected=rgb;
    if(x>=16 && x<176 && y>=144 && y<150)expected=24'hf0b020;
    if(x>=16 && x<176 && y>=156 && y<164)begin
     expected=24'h102028;
     for(i=0;i<3;i=i+1)if(x>=16+i*52 && x<60+i*52)
      expected=i==1?24'h20d0c0:24'h208040;
    end
    if(x>=16 && x<176 && y>=168 && y<172)expected=x<96?24'hffffff:24'h202020;
    if(x>=16 && x<144 && y>=180 && y<302)begin
     expected=24'h101820;b=(x-16)/16;h=(b+1)*15;
     case(b)0,1:col=24'h4080ff;2,3:col=24'h20d0c0;4,5:col=24'hd0d020;default:col=24'hf06030;endcase
     if((x-16)%16<12 && y>=300-h && y<300)expected=col;
    end
    if(x>=16 && x<144 && y>=312 && y<378)begin
     expected=y==344?24'h304050:24'h101820;
     w=312+((x-16)/8)*4;
     if(y==w || y==w+1)expected=24'hf0f0f0;
    end
    if(out!==expected)$fatal(1,"pixel x%0d y%0d got%h expected%h",x,y,out,expected);
    if(x==143 && y==180)count=count+1;
    @(negedge clk);
   end
   de=0;#1;if(out!==rgb)$fatal(1,"blanking");repeat(2)@(negedge clk);
  end
  force dut.x=16;force dut.y=144;de=1;online=0;#1;
  if(out!==24'hc03030)$fatal(1,"offline indicator");
  online=1;status[5]=1;#1;if(out!==24'hff20d0)$fatal(1,"clip indicator");
  status=0;status[23]=1;force dut.y=156;#1;
  if(out!==24'h4080ff)$fatal(1,"MUSIC MODE text");
  status[15:14]=2'b11;#1;if(out!==24'h20d0c0)$fatal(1,"VOICE READY text");
  force dut.x=176;status[25:24]=1;#1;if(out!==24'h20d0c0)$fatal(1,"NEXT command text");
  enable=0;#1;if(out!==rgb)$fatal(1,"bypass");
  if(count!=1)$fatal(1,"incomplete raster");
  $display("PASS mic overlay: 307200 pixels, all 8 bars / 16 waveform points, bounds, blanking, offline, clipping, zero-latency bypass");$finish;
 end
 initial begin #5000000;$fatal(1,"overlay watchdog");end
endmodule
