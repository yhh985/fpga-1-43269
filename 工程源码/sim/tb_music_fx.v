`timescale 1ns/1ps
module tb_music_fx;
parameter PHASE=0, LINK_DELAY=0,SLOT_BITS=64;
reg clk=0,mclk=0,vclk=0,rst=1;initial begin #(PHASE);forever #10 clk=~clk;end always #40.667 mclk=~mclk;always #20 vclk=~vclk;
reg [1:0] mode=0;reg [31:0] frame={16'(-15000),16'(12000)};
wire re,b,l,d,q,valid;wire bd,ld,dd,qd;
assign #(LINK_DELAY) bd=b;assign #(LINK_DELAY) ld=l;assign #(LINK_DELAY) dd=d;assign #(LINK_DELAY) qd=q;wire [23:0] left,right;reg fv=0;
always @(posedge mclk)fv<=re;
audio_wav_i2s #(.PREFILL(1),.SLOT_BITS(SLOT_BITS)) tx(.mclk(mclk),.rst(rst),.enable(1'b1),.paused(1'b0),.stream_ok(1'b1),
 .fifo_used(13'd4096),.fifo_empty(1'b0),.fifo_valid(fv),.fifo_data(frame),.fifo_re(re),.bclk(b),.lrck(l),.dout(d),.playing(),.underflow(),.underruns());
music_fx_return fx(.clk(clk),.rst(rst),.serial_bclk(bd),.serial_lrck(ld),.serial_data(dd),.mode(mode),.serial_return(q));
I2S_receiver #(.DATA_DELAY(2),.SLOT_BITS(SLOT_BITS)) rx(.I_clk(vclk),.I_rst(rst),.I_i2s_BCLK(b),.I_i2s_LRCK(l),.I_i2s_DOUT(qd),.O_audio_valid(valid),.O_audio_left_data(left),.O_audio_right_data(right));
integer i,n,a,c,checks=0;integer wantl,wantr;
wire local_valid;wire [23:0] local_l,local_r;
I2S_receiver #(.DATA_DELAY(2),.SLOT_BITS(SLOT_BITS)) local_rx(.I_clk(vclk),.I_rst(rst),
 .I_i2s_BCLK(b),.I_i2s_LRCK(l),.I_i2s_DOUT(d),.O_audio_valid(local_valid),
 .O_audio_left_data(local_l),.O_audio_right_data(local_r));
reg dynamic=0;reg [31:0] seed=32'h12345678;
integer dynamic_frames=0;reg signed [15:0] prior_l,prior_r;
always @(negedge l)if(dynamic)begin
 seed={seed[30:0],seed[31]^seed[21]^seed[1]^seed[0]};
 frame={seed[15:0],seed[31:16]};
end
always @(posedge valid)begin
 #1;
 if(dynamic)begin
  if(dynamic_frames>4)begin
   if(($signed(left)>>>8)!==($signed(prior_l)>>>1) ||
      ($signed(right)>>>8)!==($signed(prior_r)>>>1))
    $fatal(1,"dynamic stereo return corrupt frame%0d L%0d R%0d expected%0d %0d",dynamic_frames,$signed(left)>>>8,$signed(right)>>>8,$signed(prior_l)>>>1,$signed(prior_r)>>>1);
   checks=checks+1;
  end
  prior_l=local_l[23:8];prior_r=local_r[23:8];dynamic_frames=dynamic_frames+1;
 end
end
task check;input integer wl,wr,tolerance;begin
 repeat(30)@(posedge valid);
 for(n=0;n<30;n=n+1)begin @(posedge valid);#1;a=$signed(left)>>>8;c=$signed(right)>>>8;
  if(a<wl-tolerance||a>wl+tolerance||c<wr-tolerance||c>wr+tolerance)$fatal(1,"effect=%0d got L=%0d R=%0d want L=%0d R=%0d",mode,a,c,wl,wr);checks=checks+1;
 end
end endtask
initial begin
 #300;rst=0;check(12000,-15000,0);mode=1;check(6000,-7500,0);frame={16'(-32767),16'(32767)};check(16383,-16384,0);frame={16'(-15000),16'(12000)};mode=2;check(12000,-15000,2);mode=3;check(32767,-32768,0);
 frame={16'(-8192),16'(8191)};check(32764,-32768,0);frame=0;check(0,0,0);
 mode=1;repeat(30)@(posedge valid);dynamic=1;repeat(256)@(posedge valid);#2;dynamic=0;
 $display("PASS external music return: %0d stereo frames, four effects, dynamic signed stereo samples; SLOT_BITS=%0d phase=%0d delay=%0d ns",checks,SLOT_BITS,PHASE,LINK_DELAY);$finish;
end
initial begin #25000000;$fatal(1,"timeout");end
endmodule


