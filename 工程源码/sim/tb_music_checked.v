`timescale 1ns/1ps
module tb_music_checked;
parameter PHASE=0,LINK_DELAY=0,QUICK=0,LRCK_SKEW=0,DATA_SKEW=0,VIDEO_PHASE=0,NOISE=0;
reg clk=0,mclk=0,vclk=0,rst=1;
initial begin #(PHASE);forever #10 clk=~clk;end
always #40.667 mclk=~mclk;
initial begin #(VIDEO_PHASE);forever #20 vclk=~vclk;end
reg [1:0] mode=0;reg [31:0] frame={16'(-15000),16'(12000)};
wire re,b,l,d,q;wire bd,ld,dd,qd;reg fv=0,bad_in=0,bad_out=0;
reg spike=0;
// Asynchronous 10ns cable spikes, sweeping across 20ns/40ns receiver clocks.
initial if(NOISE)begin #901;forever begin #1733;spike=1;#10;spike=0;end end
assign #(LINK_DELAY) bd=b^(spike && NOISE==1);
assign #(LINK_DELAY+LRCK_SKEW) ld=l^(spike && NOISE==2);
assign #(LINK_DELAY+DATA_SKEW) dd=d^bad_in^(spike && NOISE==3);
assign #(LINK_DELAY) qd=q^bad_out^(spike && NOISE==4);
always @(posedge mclk)fv<=re;
audio_wav_i2s #(.PREFILL(1),.SLOT_BITS(32),.CHECKSUM(1)) tx(.mclk(mclk),.rst(rst),
 .enable(1'b1),.paused(1'b0),.stream_ok(1'b1),.fifo_used(13'd4096),.fifo_empty(1'b0),
 .fifo_valid(fv),.fifo_data(frame),.fifo_re(re),.bclk(b),.lrck(l),.dout(d),.playing(),.underflow(),.underruns());
music_fx_return #(.CHECKSUM(1)) fx(.clk(clk),.rst(rst),.serial_bclk(bd),.serial_lrck(ld),
 .serial_data(dd),.mode(mode),.serial_return(q));
wire [23:0] left,right;wire present;wire [15:0] errors;
music_checked_stereo rx(.clk(vclk),.rst(rst),.bclk(b),.lrck(l),.din(qd),
 .left(left),.right(right),.present(present),.errors(errors));
integer checks=0,i,lo,hi;reg [31:0] seed=32'h8b5f3901;
reg dynamic=0,alternating=0;reg signed [15:0] history_l[0:3],history_r[0:3];
wire lv;wire [23:0] local_l,local_r;
I2S_receiver #(.DATA_DELAY(2),.SLOT_BITS(32)) local_rx(.I_clk(vclk),.I_rst(rst),
 .I_i2s_BCLK(b),.I_i2s_LRCK(l),.I_i2s_DOUT(d),.O_audio_valid(lv),
 .O_audio_left_data(local_l),.O_audio_right_data(local_r));
always @(negedge l)begin
 if(dynamic)begin seed={seed[30:0],seed[31]^seed[21]^seed[1]^seed[0]};frame=seed;end
 if(alternating)frame=frame[15]?{16'(12000),16'(12000)}:{16'(-12000),16'(-12000)};
end
integer n=0;
always @(posedge lv)begin
 #1;
 if(dynamic && n>8 && present)begin
  // Return is one full stereo frame behind the local PCM stream.
  if(($signed(left)>>>8)!==($signed(history_l[0])>>>2) ||
     ($signed(right)>>>8)!==($signed(history_r[0])>>>2))
   $fatal(1,"dynamic checked output got %0d/%0d expected %0d/%0d",$signed(left)>>>8,$signed(right)>>>8,$signed(history_l[0])>>>2,$signed(history_r[0])>>>2);
  checks=checks+1;
 end
 history_l[0]=local_l[23:8];history_r[0]=local_r[23:8];n=n+1;
end
task check;input integer wl,wr,tolerance;begin
 repeat(80)@(posedge lv);
 if(!present)$fatal(1,"no valid checked return, errors=%0d",errors);
 repeat(30)begin @(posedge lv);#2;
  if(($signed(left)>>>8)<wl-tolerance || ($signed(left)>>>8)>wl+tolerance ||
     ($signed(right)>>>8)<wr-tolerance || ($signed(right)>>>8)>wr+tolerance)
   $fatal(1,"mode%0d got%0d/%0d want%0d/%0d",mode,$signed(left)>>>8,$signed(right)>>>8,wl,wr);
  checks=checks+1;
 end
end endtask
initial begin
 #300;rst=0;check(3000,-3750,0);mode=1;check(1500,-1875,0);
 mode=2;check(3000,-3750,2);
 alternating=1;repeat(150)@(posedge lv);
 repeat(40)begin @(posedge lv);#2;
  if($signed(left)>24'sd600*256 || $signed(left)< -24'sd600*256)$fatal(1,"lowpass fails to attenuate high frequency");
  checks=checks+1;
 end
 alternating=0;frame={16'(-15000),16'(12000)};
 mode=3;lo=0;hi=0;
 if(!QUICK)begin
 repeat(11000)begin @(posedge lv);#2;
  if(($signed(left)>>>8)==750)lo=lo+1;
  if(($signed(left)>>>8)==3000)hi=hi+1;
  if(($signed(left)>>>8)>8191 || ($signed(left)>>>8)< -8192)$fatal(1,"output exceeds commissioning level");
 end
 if(lo<1000 || hi<1000)$fatal(1,"tremolo did not change gain %0d/%0d",lo,hi);
 // Full-length run has filled the actual 4096-frame echo RAM. Verify the
 // nonzero wet signal through both physical serial directions, not only DSP.
 mode=1;check(1312,-2063,0);
 end
 mode=0;check(3000,-3750,0);dynamic=1;repeat(300)@(posedge lv);dynamic=0;
 if(NOISE)begin
  frame={16'(-15000),16'(12000)};check(3000,-3750,0);
  // Corrupt exactly one returned left-channel slot. Conceal that pair, but
  // retain the error evidence. The following pair must recover immediately.
  @(negedge l);bad_out=1;@(posedge l);bad_out=0;
  repeat(3)begin @(posedge lv);#2;
   if(!present || left!==24'(3000*256) || right!==24'(-3750*256))
    $fatal(1,"isolated bad pair was not concealed");
  end
 end
 bad_out=1;repeat(8)@(posedge lv);#2;
 if(present || left || right)$fatal(1,"corrupt return was audible");
 bad_out=0;frame={16'(-15000),16'(12000)};check(3000,-3750,0);
 bad_in=1;repeat(10)@(posedge lv);#2;
 if(present || left || right)$fatal(1,"corrupt source was accepted by ACA");
 bad_in=0;check(3000,-3750,0);
 if(errors==0)$fatal(1,"missing checksum errors");
 $display("PASS checked effects: checks=%0d phase=%0d delay=%0d full_tremolo=%0d",checks,PHASE,LINK_DELAY,!QUICK);$finish;
end
initial begin #400000000;$fatal(1,"checked timeout");end
endmodule
