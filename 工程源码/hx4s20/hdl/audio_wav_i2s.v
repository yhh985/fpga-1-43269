`timescale 1ns/1ps
// Existing board serial convention: 64 BCLK bits per channel, MCLK/256 Fs.
// Clocks and zero PCM continue when stopped, paused or rebuffering. Fetch on
// the right slot, well before the next stereo frame. Pause retains that frame.
module audio_wav_i2s #(parameter AB=12, PREFILL=3072,SLOT_BITS=64,CHECKSUM=0)(
 input mclk,rst,enable,paused,stream_ok,
 input [AB:0] fifo_used,input fifo_empty,fifo_valid,input [31:0] fifo_data,
 output reg fifo_re,
 output reg bclk,lrck,dout,
 output reg playing,output reg underflow,output reg [15:0] underruns
);
 reg [1:0] en_sync,pause_sync,ok_sync;
 reg [5:0] bit_count;
 reg [63:0] shift;
 reg [31:0] right_word;
 function [31:0] pack_word;
  input [15:0] pcm;input channel;reg [14:0] crc;integer k;
  begin
   crc=15'h7fff ^ channel;
   for(k=15;k>=0;k=k-1)crc={crc[13:0],1'b0} ^ ((crc[14]^pcm[k])?15'h4599:15'd0);
   pack_word=CHECKSUM?{pcm,crc,1'b0}:{pcm,16'd0};
  end
 endfunction
 reg [31:0] next_frame;
 reg have_next;
 reg bit_div;
 always @(posedge mclk or posedge rst)begin
  if(rst)begin
   en_sync<=0;pause_sync<=0;ok_sync<=0;bit_count<=0;shift<=0;
   right_word<=0;next_frame<=0;have_next<=0;fifo_re<=0;
   bclk<=0;lrck<=0;dout<=0;playing<=0;underflow<=0;underruns<=0;
   bit_div<=0;
  end else begin
   en_sync<={en_sync[0],enable};pause_sync<={pause_sync[0],paused};
   ok_sync<={ok_sync[0],stream_ok};fifo_re<=0;bit_div<=~bit_div;
   if(SLOT_BITS==64 || bit_div)bclk<=~bclk;
   if(!en_sync[1]||!ok_sync[1])begin playing<=0;have_next<=0;underflow<=0;end
   else begin
    
    if(fifo_valid)begin next_frame<=fifo_data;have_next<=1;end
   end
   if(bclk && (SLOT_BITS==64 || bit_div))begin
    dout<=shift[63];shift<={shift[62:0],1'b0};
    if(bit_count==SLOT_BITS-1)begin
     bit_count<=0;
     if(!lrck)begin
      lrck<=1;shift<={right_word,32'd0};
      if(en_sync[1]&&ok_sync[1]&&!pause_sync[1]&&!have_next&&!fifo_empty&&
         (playing||fifo_used>=PREFILL))begin fifo_re<=1;playing<=1;end
     end else begin
      lrck<=0;
      if(en_sync[1]&&ok_sync[1]&&!pause_sync[1]&&playing&&have_next)begin
       shift<={pack_word(next_frame[15:0],1'b0),32'd0};
       right_word<=pack_word(next_frame[31:16],1'b1);have_next<=0;
      end else begin
       shift<=0;right_word<=0;
       if(en_sync[1]&&ok_sync[1]&&!pause_sync[1]&&playing&&!have_next)begin
        playing<=0;underflow<=1;if(underruns!=16'hffff)underruns<=underruns+1'b1;
       end
      end
     end
    end else bit_count<=bit_count+1'b1;
   end
  end
 end
endmodule
