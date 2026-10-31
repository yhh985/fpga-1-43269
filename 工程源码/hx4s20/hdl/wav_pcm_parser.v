`timescale 1ns/1ps
// RIFF chunk walker, PCM1, 16-bit LE, 48 kHz, mono/stereo. Handles extended
// fmt, unknown chunks and odd padding. File cap 64 MiB. No guessed 44-byte
// offset. Byte input may pause anywhere; CHECK uses <=4 clocks, while the
// production CRC-checked SD release spacing is at least 4 clocks. ready is explicit.
module wav_pcm_parser(
 input clk,rst,input [31:0] file_size,
 input byte_valid,input [7:0] byte_data,output byte_ready,
 output reg pcm_valid,output reg [31:0] pcm_frame,
 output reg format_ok,done,error
);
 localparam HEADER=0,CHUNK=1,CHECK=2,FMT=3,FMT_CHECK=4,SKIP=5,PAD=6,DATA=7,FINISH=8,FAIL=9,HEADER_SUM=10,HEADER_CHECK=11,CHUNK_VALIDATE=12,HEADER_COMMIT=13,FMT_COMMIT=14,CHUNK_DECIDE=15;
 // Branch-based state transitions let TD extract and encode this FSM.
 (* fsm_encoding = "one_hot" *) reg [3:0] state;
 reg [27:0] riff_total,chunk_padded;
 reg [26:0] chunk_available;
 reg chunk_in_bounds,chunk_ok,header_ok,fmt_ok;
 reg [26:0] file_limit;
 reg file_bounds_valid;
 reg in_file;
 always @(posedge clk)begin in_file<=offset<file_limit;file_limit<=file_size[26:0];file_bounds_valid<=file_size>=12&&file_size<=32'd67108864;end
 reg [26:0] offset,riff_end,remaining;
 reg [31:0] id,size,riff_id,wave_id,riff_size;
 reg [4:0] index;
 reg [15:0] format,channels,align,bits;
 reg [31:0] rate,byte_rate;
 reg odd;
 reg [1:0] pcm_index;
 reg [23:0] pcm_bytes;
 wire [31:0] complete_word={byte_data,size[23:0]};
 wire [27:0] padded_size={1'b0,size[26:0]}+size[0];
 assign byte_ready=state==HEADER||state==CHUNK||state==FMT||state==SKIP||state==PAD||state==DATA||state==FINISH;
 // Format-byte capture has a direct state/byte/index enable, independent of
 // the walker's next-state priority. FMT itself always asserts byte_ready.
 always @(posedge clk or posedge rst)begin
  if(rst)begin format<=0;channels<=0;align<=0;bits<=0;rate<=0;byte_rate<=0;end
  else if(byte_valid && state==FMT && in_file)begin
   case(index)
    0:format[7:0]<=byte_data;1:format[15:8]<=byte_data;
    2:channels[7:0]<=byte_data;3:channels[15:8]<=byte_data;
    4:rate[7:0]<=byte_data;5:rate[15:8]<=byte_data;6:rate[23:16]<=byte_data;7:rate[31:24]<=byte_data;
    8:byte_rate[7:0]<=byte_data;9:byte_rate[15:8]<=byte_data;10:byte_rate[23:16]<=byte_data;11:byte_rate[31:24]<=byte_data;
    12:align[7:0]<=byte_data;13:align[15:8]<=byte_data;
    14:bits[7:0]<=byte_data;15:bits[15:8]<=byte_data;
   endcase
  end
 end
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   riff_total<=0;chunk_padded<=0;chunk_available<=0;chunk_in_bounds<=0;chunk_ok<=0;header_ok<=0;fmt_ok<=0;state<=HEADER;offset<=0;riff_end<=0;remaining<=0;id<=0;size<=0;
   riff_id<=0;wave_id<=0;riff_size<=0;index<=0;
   odd<=0;pcm_index<=0;pcm_bytes<=0;
   pcm_valid<=0;pcm_frame<=0;format_ok<=0;done<=0;error<=0;
  end else begin
   pcm_valid<=0;
   if(byte_valid&&!byte_ready)begin error<=1;state<=FAIL;end
   else if(byte_valid&&byte_ready)begin
    offset<=offset+1'b1;
    if(state!=FINISH&&!in_file)begin error<=1;state<=FAIL;end
    else case(state)
     HEADER:begin
      if(index<4)riff_id<={byte_data,riff_id[31:8]};
      else if(index<8)riff_size<={byte_data,riff_size[31:8]};
      else wave_id<={byte_data,wave_id[31:8]};
      if(index==11)begin state<=HEADER_SUM;index<=0;
      end else index<=index+1'b1;
     end
     CHUNK:begin
      if(index<4)id<={byte_data,id[31:8]};else size<={byte_data,size[31:8]};
      if(index==7)begin index<=0;state<=CHECK;end else index<=index+1'b1;
     end
     FMT:begin
      if(index<16)index<=index+1'b1;
      remaining<=remaining-1'b1;
      if(remaining==1)state<=FMT_CHECK;
     end
     SKIP:begin remaining<=remaining-1'b1;if(remaining==1)begin index<=0;if(odd)state<=PAD;else state<=CHUNK;end end
     PAD:begin index<=0;state<=CHUNK;end
     DATA:begin
      pcm_bytes<={byte_data,pcm_bytes[23:8]};
      if(channels==1&&pcm_index==1)begin
       pcm_frame<={{byte_data,pcm_bytes[23:16]},{byte_data,pcm_bytes[23:16]}};pcm_valid<=1;pcm_index<=0;
      end else if(pcm_index==3)begin pcm_frame<={byte_data,pcm_bytes};pcm_valid<=1;pcm_index<=0;end
      else pcm_index<=pcm_index+1'b1;
      remaining<=remaining-1'b1;
      if(remaining==1)begin done<=1;state<=FINISH;end
     end
    endcase
   end else if(state==HEADER_SUM)begin
    riff_total<={1'b0,riff_size[26:0]}+28'd8;state<=HEADER_CHECK;
   end else if(state==HEADER_CHECK)begin
    header_ok<=riff_id==32'h46464952&&wave_id==32'h45564157&&file_bounds_valid&&
       riff_size>=4&&riff_size[31:27]==0&&riff_total<={1'b0,file_limit};state<=HEADER_COMMIT;
   end else if(state==HEADER_COMMIT)begin
    if(!header_ok)begin error<=1;state<=FAIL;end
    else begin riff_end<=riff_total[26:0];index<=0;state<=CHUNK;end
   end else if(state==CHECK)begin
    chunk_padded<=padded_size;chunk_available<=riff_end-offset;chunk_in_bounds<=offset<=riff_end;state<=CHUNK_VALIDATE;
   end else if(state==CHUNK_VALIDATE)begin
    // Commit the wide bounds comparison before selecting payload state and
    // updating the byte index. Three idle clocks are needed between bytes.
    chunk_ok<=chunk_in_bounds && size[31:27]==0 && chunk_padded<={1'b0,chunk_available};
    state<=CHUNK_DECIDE;
   end else if(state==CHUNK_DECIDE)begin
    if(!chunk_ok)begin error<=1;state<=FAIL;end
    else begin
     remaining<=size[26:0];odd<=size[0];index<=0;
     if(id==32'h20746d66)begin
      if(format_ok||size<16)begin error<=1;state<=FAIL;end else state<=FMT;
     end else if(id==32'h61746164)begin
      if(!format_ok||size==0||size[0]||(channels==2&&size[1]))begin error<=1;state<=FAIL;end
      else begin pcm_index<=0;state<=DATA;end
     end else if(size==0)state<=CHUNK;
     else state<=SKIP;
    end
   end else if(state==FMT_CHECK)begin
    fmt_ok<=format==1&&bits==16&&rate==48000&&
       ((channels==1&&align==2&&byte_rate==96000)||(channels==2&&align==4&&byte_rate==192000));state<=FMT_COMMIT;
   end else if(state==FMT_COMMIT)begin
    if(!fmt_ok)begin error<=1;state<=FAIL;end
    else begin format_ok<=1;index<=0;if(odd)state<=PAD;else state<=CHUNK;end
   end
  end
 end
endmodule
