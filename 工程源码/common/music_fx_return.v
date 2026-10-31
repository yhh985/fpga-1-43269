`timescale 1ns/1ps
// 50MHz oversampled slave for the existing 64-bit/channel I2S convention.
// Only external music is processed. Independent microphone/codec path is absent.
// One frame delay; no additional clock domain or sample-rate conversion.
module music_fx_return #(parameter CHECKSUM=0)(
 input clk,rst,input serial_bclk,serial_lrck,serial_data,
 input [1:0] mode,output wire serial_return,output wire [3:0] input_state
);
 generate if(CHECKSUM)begin:g_checked
  music_checked_fx u_checked(.clk(clk),.rst(rst),.bclk(serial_bclk),.lrck(serial_lrck),
   .din(serial_data),.mode(mode),.dout(serial_return),.input_state(input_state));
 end else begin:g_legacy
 reg legacy_return;
 assign serial_return=legacy_return;
 assign input_state=4'd0;
 (* async_reg="true" *) reg [2:0] bs;
 (* async_reg="true" *) reg [1:0] ls,ds;
 reg channel;
 reg [6:0] rx_count,tx_count;
 reg [15:0] rx_shift,tx_shift;
 reg signed [15:0] left_result,right_result,left_history,right_history;
 reg [1:0] previous_mode;
 reg [15:0] watchdog;
 wire rise=bs[1]&&!bs[2],fall=!bs[1]&&bs[2];
 wire signed [15:0] sample_value={rx_shift[14:0],ds[1]};
 wire signed [16:0] sample_ext={sample_value[15],sample_value};
 wire signed [16:0] history_ext=channel ? {right_history[15],right_history} : {left_history[15],left_history};
 wire signed [16:0] lowpass=(sample_ext>>>1)+(history_ext>>>1);
 function [15:0] effect;
  input signed [15:0] value;
  input signed [16:0] filtered;
  input [1:0] selection;
  begin case(selection)
   1:effect=value>>>1;
   2:effect=filtered[15:0];
   3:if(value>8191)effect=16'h7fff;else if(value< -8192)effect=16'h8000;else effect=value<<<2;
   default:effect=value;
  endcase end
 endfunction
 always @(posedge clk or posedge rst)begin
  if(rst)begin bs<=0;ls<=0;ds<=0;channel<=0;rx_count<=127;tx_count<=127;
   rx_shift<=0;tx_shift<=0;legacy_return<=0;left_result<=0;right_result<=0;
   left_history<=0;right_history<=0;previous_mode<=0;watchdog<=0;
  end else begin
   bs<={bs[1:0],serial_bclk};ls<={ls[0],serial_lrck};ds<={ds[0],serial_data};
   previous_mode<=mode;
   if(rise||fall)watchdog<=0;else if(watchdog!=65535)watchdog<=watchdog+1'b1;
   if(watchdog==65535||previous_mode!=mode)begin
    left_result<=0;right_result<=0;left_history<=0;right_history<=0;
    legacy_return<=0;tx_shift<=0;
   end
   if(fall)begin
    if(ls[1]!=channel)begin
     channel<=ls[1];rx_count<=127;tx_count<=0;legacy_return<=0;
     tx_shift<=ls[1] ? right_result : left_result;
    end else begin
     if(tx_count<16)begin legacy_return<=tx_shift[15];tx_shift<={tx_shift[14:0],1'b0};tx_count<=tx_count+1'b1;end
     else legacy_return<=0;
    end
   end
   if(rise && ls[1]==channel && rx_count==127)rx_count<=0;
   else if(rise && ls[1]==channel && rx_count<16)begin
    rx_shift<={rx_shift[14:0],ds[1]};rx_count<=rx_count+1'b1;
    if(rx_count==15)begin
     if(channel)begin right_result<=effect(sample_value,lowpass,mode);right_history<=lowpass[15:0];end
     else begin left_result<=effect(sample_value,lowpass,mode);left_history<=lowpass[15:0];end
    end
   end
  end
 end
 end endgenerate
endmodule

// Recent link diagnostics, refreshed every ~10ms at 50MHz / ~20ms at 25MHz.
// Inputs are already synchronized. Activity is separate from CRC validity:
// noise may toggle DATA but cannot be called a successful audio link.
module music_link_monitor #(parameter WINDOW_BITS=19)(
 input clk,rst,bclk_sample,lrck_sample,data_sample,sample_valid,channel,good,
 output reg [3:0] state);
 reg [WINDOW_BITS-1:0] window;
 reg [2:0] previous;
 reg [3:0] seen;
 reg left_good;
 wire [2:0] current={bclk_sample,lrck_sample,data_sample};
 wire [3:0] events={current^previous,sample_valid && channel && good && left_good};
 always @(posedge clk or posedge rst)begin
  if(rst)begin window<=0;previous<=0;seen<=0;state<=0;left_good<=0;end
  else begin
   previous<=current;window<=window+1'b1;
   if(sample_valid)left_good<=!channel && good;
   if(&window)begin state<=seen|events;seen<=0;end
   else seen<=seen|events;
  end
 end
endmodule

// Protected board link: each 32-bit slot carries PCM16, CRC15/CAN and one pad.
// The I2S dummy bit is not payload. Both directions validate before DSP/output.
// This is a private inter-FPGA transport, not codec-compatible I2S PCM padding.
module music_checked_rx(
 input clk,rst,bclk,lrck,din,
 output reg sample_valid,output reg sample_channel,
 output reg signed [15:0] sample,output reg sample_good,output wire [3:0] link_state
);
 // Equal-depth synchronizers and majority filters preserve relative timing.
 // Do not filter only BCLK: that would move sampling into changing DATA.
 (* async_reg="true" *) reg [2:0] bs,ls,ds;
 reg b_previous;
 wire b_clean=(bs[2]&bs[1])|(bs[2]&bs[0])|(bs[1]&bs[0]);
 wire l_clean=(ls[2]&ls[1])|(ls[2]&ls[0])|(ls[1]&ls[0]);
 wire d_clean=(ds[2]&ds[1])|(ds[2]&ds[0])|(ds[1]&ds[0]);
 reg channel;reg [5:0] count;reg [30:0] shift;
 wire rise=b_clean&&!b_previous;
 wire [30:0] completed={shift[29:0],d_clean};
 music_link_monitor monitor(.clk(clk),.rst(rst),.bclk_sample(bs[2]),
  .lrck_sample(l_clean),.data_sample(d_clean),.sample_valid(sample_valid),
  .channel(sample_channel),.good(sample_good),.state(link_state));
 function [14:0] crc15;
  input [15:0] pcm;input ch;reg [14:0] c;integer k;
  begin c=15'h7fff ^ ch;
   for(k=15;k>=0;k=k-1)c={c[13:0],1'b0} ^ ((c[14]^pcm[k])?15'h4599:15'd0);
   crc15=c;
  end
 endfunction
 always @(posedge clk or posedge rst)begin
  if(rst)begin bs<=0;ls<=0;ds<=0;b_previous<=0;channel<=0;count<=63;shift<=0;
   sample_valid<=0;sample_channel<=0;sample<=0;sample_good<=0;end
  else begin
   bs<={bs[1:0],bclk};ls<={ls[1:0],lrck};ds<={ds[1:0],din};b_previous<=b_clean;sample_valid<=0;
   // LRCK and BCLK cross separate pins/synchronizers. Detect a channel
   // change on ANY system clock, including when LRCK arrives just after
   // the detected falling BCLK. Waiting another full bit loses the MSB.
   if(l_clean!=channel)begin channel<=l_clean;count<=63;end
   else if(rise)begin
    if(count==63)count<=0;
    else if(count<31)begin
     shift<=completed;count<=count+1'b1;
     if(count==30)begin
      sample<=completed[30:15];sample_channel<=channel;sample_valid<=1;
      sample_good<=completed[14:0]==crc15(completed[30:15],channel);
     end
    end
   end
  end
 end
endmodule

module music_checked_fx(input clk,rst,bclk,lrck,din,input [1:0] mode,output reg dout,
 output wire [3:0] input_state);
 wire sv,ch,good;wire signed [15:0] pcm;
 music_checked_rx rx(.clk(clk),.rst(rst),.bclk(bclk),.lrck(lrck),.din(din),
  .sample_valid(sv),.sample_channel(ch),.sample(pcm),.sample_good(good),.link_state(input_state));
 (* async_reg="true" *) reg [2:0] bs;
 (* async_reg="true" *) reg [2:0] ls;
 reg b_previous;
 wire b_clean=(bs[2]&bs[1])|(bs[2]&bs[0])|(bs[1]&bs[0]);
 wire l_clean=(ls[2]&ls[1])|(ls[2]&ls[0])|(ls[1]&ls[0]);
 reg channel;reg [5:0] count;reg [31:0] tx,wl,wr;
 reg signed [19:0] hl,hr;
 reg [1:0] previous_mode;reg [13:0] phase;
 reg [1:0] frame_mode;
 reg frame_tremolo;
 reg signed [19:0] filtered;
 reg signed [15:0] effected,limited;
 wire signed [15:0] echo;
 music_echo_delay u_echo(.clk(clk),.rst(rst),.sample_valid(sv),
  .channel(ch),.sample(pcm),.good(good),.echo(echo));
 wire fall=!b_clean&&b_previous;
 function [31:0] pack;
  input [15:0] value;input c;input valid;reg [14:0] crc;integer k;
  begin crc=15'h7fff ^ c;
   for(k=15;k>=0;k=k-1)crc={crc[13:0],1'b0} ^ ((crc[14]^value[k])?15'h4599:15'd0);
   pack={value,valid?crc:~crc,1'b0};
  end
 endfunction
 always @(posedge clk or posedge rst)begin
  if(rst)begin bs<=0;ls<=0;b_previous<=0;channel<=0;count<=63;tx<=0;wl<=0;wr<=0;dout<=0;
   hl<=0;hr<=0;previous_mode<=0;phase<=0;frame_mode<=0;frame_tremolo<=1;filtered<=0;effected<=0;limited<=0;end
  else begin
   bs<={bs[1:0],bclk};ls<={ls[1:0],lrck};b_previous<=b_clean;previous_mode<=mode;
   if(previous_mode!=mode)begin hl<=0;hr<=0;end
   if(sv)begin
    if(!ch)begin frame_mode<=mode;frame_tremolo<=phase<4800;phase<=phase==9599?0:phase+1'b1;end
    // Q4 state avoids the DC rounding loss of a 16-bit accumulator.
    filtered=(ch?hr:hl)+((($signed(pcm)*20'sd16)-(ch?hr:hl))>>>3);
    if(good)begin if(ch)hr<=filtered;else hl<=filtered;end
    case(ch?frame_mode:mode)
     // Average dry stereo with an 85ms mono echo; sum cannot clip.
     1:effected=($signed(pcm)>>>1)+($signed(echo)>>>1);
     2:effected=filtered>>>4;
     3:effected=(ch?frame_tremolo:phase<4800)?pcm:(pcm>>>2);
     default:effected=pcm;
    endcase
    // -12 dB commissioning headroom in every processed mode. Never saturate.
    limited=effected>>>2;
    if(ch)wr<=pack(limited,1'b1,good);else wl<=pack(limited,1'b0,good);
   end
   // Load during the dummy bit as soon as synchronized LRCK changes.
   // The next falling edge starts payload even with inter-wire skew.
   if(l_clean!=channel)begin
    channel<=l_clean;count<=b_clean?63:0;dout<=0;tx<=l_clean?wr:wl;
   end
   else if(fall)begin
    // If LRCK was observed before boundary BCLK, reserve that first
    // falling edge for the dummy bit rather than transmitting MSB early.
    if(count==63)begin dout<=0;count<=0;end
    else if(count<32)begin dout<=tx[31];tx<={tx[30:0],1'b0};count<=count+1'b1;end
    else dout<=0;
   end
  end
 end
endmodule

// 4096 stereo frames / 48kHz = 85.3ms. Mono wet signal costs 8 RAM9Ks.
// Synchronous read, no array reset: invalid/warm-up history is excluded by fill.
module music_echo_delay #(parameter ADDRESS_BITS=12)(
 input clk,rst,sample_valid,channel,good,input signed [15:0] sample,
 output wire signed [15:0] echo);
 localparam DEPTH=1<<ADDRESS_BITS;
 reg signed [15:0] memory[0:DEPTH-1];
 reg [ADDRESS_BITS-1:0] pointer;
 reg [ADDRESS_BITS:0] fill;
 reg signed [15:0] readback,left;
 reg signed [15:0] wet_hold;
 reg left_good;
 // Left is consumed on the same sample_valid edge as the DSP; right uses
 // that exact held wet sample. Do not delay only the left channel by a frame.
 assign echo=channel ? wet_hold : (good && fill==DEPTH ? readback : 16'sd0);
 wire signed [16:0] mono_sum={left[15],left}+{sample[15],sample};
 always @(posedge clk)begin
  readback<=memory[pointer];
  if(sample_valid && channel && good && left_good)
   memory[pointer]<=mono_sum>>>1;
 end
 always @(posedge clk or posedge rst)begin
  if(rst)begin pointer<=0;fill<=0;left<=0;left_good<=0;wet_hold<=0;end
  else if(sample_valid)begin
   if(!channel)begin
    left<=sample;left_good<=good;
    wet_hold<=good && fill==DEPTH ? readback : 16'sd0;
   end else begin
    if(good && left_good)begin
     pointer<=pointer+1'b1;
     if(fill<DEPTH)fill<=fill+1'b1;
    end else begin pointer<=0;fill<=0;wet_hold<=0;end
    left_good<=0;
   end
  end
 end
endmodule

// Stereo collector for HDMI's PCM domain. No unvalidated word reaches output.
module music_checked_stereo(input clk,rst,bclk,lrck,din,
 output reg [23:0] left,right,output reg present,output reg [15:0] errors,
 output wire [3:0] link_state);
 wire sv,ch,good;wire signed [15:0] pcm;
 music_checked_rx rx(.clk(clk),.rst(rst),.bclk(bclk),.lrck(lrck),.din(din),
  .sample_valid(sv),.sample_channel(ch),.sample(pcm),.sample_good(good),.link_state(link_state));
 reg [15:0] pending;reg left_good;reg [3:0] run;
 reg missed;
 reg [19:0] watchdog;
 always @(posedge clk or posedge rst)begin
  if(rst)begin left<=0;right<=0;present<=0;errors<=0;pending<=0;left_good<=0;run<=0;watchdog<=0;missed<=0;end
  else begin
   if(sv)watchdog<=0;else if(watchdog!=20'hfffff)watchdog<=watchdog+1'b1;
   if(watchdog==20'hfffff)begin present<=0;left<=0;right<=0;run<=0;missed<=0;end
   if(sv)begin
    if(!ch)begin pending<=pcm;left_good<=good;end
    else begin
     if(left_good && good)begin
      missed<=0;
      if(run<8)run<=run+1'b1;
      if(run>=7)begin present<=1;left<={pending,8'd0};right<={pcm,8'd0};end
     end else begin
      // Conceal just one lost stereo pair with the last CRC-valid pair.
      // A second consecutive failure still mutes and requires 8 good pairs.
      missed<=1;
      if(!present || missed)begin run<=0;present<=0;left<=0;right<=0;end
      if(errors!=16'hffff)errors<=errors+1'b1;
     end
     left_good<=0;
    end
   end
  end
 end
endmodule

module music_return_guard #(parameter integer IDLE_CYCLES=1228800)(
 input clk,rst,lrck,return_data,requested,
 output reg present,output reg route
);
 localparam BITS=$clog2(IDLE_CYCLES+1);
 (* async_reg="true" *) reg [2:0] data_sync;
 reg [BITS-1:0] age;
 reg lrck_d;
 always @(posedge clk or posedge rst)begin
  if(rst)begin data_sync<=0;age<=IDLE_CYCLES;present<=0;route<=0;lrck_d<=0;end
  else begin
   data_sync<={data_sync[1:0],return_data};lrck_d<=lrck;
   if(data_sync[2]!=data_sync[1])begin age<=0;present<=1;end
   else if(age<IDLE_CYCLES)age<=age+1'b1;
   else present<=0;
   if(lrck_d && !lrck)route<=requested && present;
  end
 end
endmodule

