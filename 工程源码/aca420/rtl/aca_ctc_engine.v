`timescale 1ns/1ps
// V5 BN-folded INT8 temporal CNN, three time scales, full CTC phrase competition.
// Shared MAC and shared Q6 log-add unit; all state is local to one utterance.
module aca_ctc_engine #(parameter MODEL_DIR="E:/anlo_project/liantiao/final_showcase_20261030/voice/model_ctc/",parameter integer NEXT_ONLY=1,MIN_MARGIN_Q6=0,FLOOR_Q6_X30=1024)(
 input wire clk,rst,feature_valid,input wire [3:0] feature_index,
 input wire signed [7:0] feature_data,input wire feature_active,frame_done,
 output reg result_valid,output reg [1:0] result_class,
 output reg event_valid,output reg [1:0] event_command,output reg fault,
 output wire window_ready,quiet_ready,utterance_active,processing,
 output reg rejected_pulse,output reg [7:0] reject_flags,
 output reg [15:0] debug_sequence,output reg [6:0] debug_voiced,debug_duration,
 output reg [287:0] debug_logits);
 (* ram_style="bram" *) reg signed [7:0] weights[0:28751];
 reg signed [31:0] biases[0:182];reg [7:0] shifts[0:182];
 (* ram_style="bram" *) reg signed [7:0] hist[0:2047];
 (* ram_style="bram" *) reg signed [7:0] buf_a[0:7167],buf_b[0:7167];
 reg [7:0] logadd_rom[0:1023],codes[0:220],lengths[0:12],commands[0:12];
 initial begin
  $readmemh({MODEL_DIR,"weights.mem"},weights);$readmemh({MODEL_DIR,"bias.mem"},biases);
  $readmemh({MODEL_DIR,"shift.mem"},shifts);$readmemh({MODEL_DIR,"logadd.mem"},logadd_rom);
  $readmemh({MODEL_DIR,"codes.mem"},codes);$readmemh({MODEL_DIR,"lengths.mem"},lengths);
  $readmemh({MODEL_DIR,"commands.mem"},commands);
 end
 reg [6:0] wr,filled,start_frame,span,voiced,total,clip_start,clip_len;
 reg active_frame,utterance;reg [2:0] quiet;reg [26:0] cooldown;
 reg [7:0] state,return_state;reg [1:0] pass,layer;
 reg [7:0] view_len,width,t;reg [5:0] ch,ic;reg [2:0] kernel;
 reg [13:0] init_addr;reg [12:0] read_addr;reg [14:0] waddr;
 reg signed [7:0] aq,bq,hq,wq;reg pad;
 reg signed [31:0] acc;reg [7:0] shift_q;
 reg signed [31:0] logits[0:38],lp[0:38];
 (* ram_style="bram" *) reg signed [31:0] dp[0:220];
 reg signed [31:0] dp_q;reg [7:0] dp_addr;
 reg signed [31:0] totals[0:12];
 reg [3:0] phrase;reg [4:0] pos;reg [7:0] di;
 reg signed [31:0] norm_score,phrase_score,best,second;reg [3:0] winner;
 reg signed [31:0] la,lb,lmax;reg [31:0] ld;reg [9:0] laddr;reg [7:0] lq;reg signed [31:0] lr;
 reg signed [31:0] div_num,div_result;reg [7:0] div_den;reg [5:0] div_bit;reg [39:0] div_rem,div_mag;reg div_negative;
 localparam signed [31:0] NEG=-32'sd1000000;
 wire [5:0] ins=layer==0?16:48;
 wire [5:0] outs=layer==3?39:48;
 wire [8:0] terms=layer==0?80:layer==3?48:240;
 wire [7:0] bindex=layer==0?ch:layer==1?48+ch:layer==2?96+ch:144+ch;
 wire [14:0] wbase=layer==0?0:layer==1?3840:layer==2?15360:26880;
 wire signed [10:0] source_frame=$signed({3'd0,t})+(layer==3?11'sd14:($signed({8'd0,kernel})-11'sd2)*(layer==0?11'sd1:layer==1?11'sd2:11'sd4));
 wire signed [15:0] product=(pad?8'sd0:(layer[0]?bq:aq))*wq;
 wire signed [31:0] mac=acc+{{16{product[15]}},product};
 wire signed [31:0] scaled=acc>>>shift_q;
 // Rational view coordinates: 4/5, 1, 5/4. Linear interpolation, round nearest.
 wire [7:0] local_frame=init_addr>>4;
 reg [9:0] phase;reg [7:0] source_index;reg [2:0] fraction;
 reg [2:0] interp_fraction;reg [6:0] interp_ring;reg signed [7:0] first_sample;
 reg [10:0] interp_total;reg [7:0] interp_rounded;
 wire [3:0] interp_den=pass==0?5:pass==1?1:4;
 wire signed [15:0] interp_value=$signed(first_sample)*$signed({1'b0,interp_den-interp_fraction})+$signed(hq)*$signed({1'b0,interp_fraction});
 assign window_ready=filled>=16;assign quiet_ready=!utterance;
 assign utterance_active=utterance;assign processing=state!=0;
 always @(posedge clk)begin
  dp_q<=dp[dp_addr];aq<=buf_a[read_addr];bq<=buf_b[read_addr];hq<=hist[{interp_ring,init_addr[3:0]}];wq<=weights[waddr];lq<=logadd_rom[laddr];
 end
 integer j;
 always @(posedge clk)begin
  if(rst)begin
   wr<=0;filled<=0;active_frame<=0;utterance<=0;quiet<=0;voiced<=0;total<=0;start_frame<=0;
   state<=0;fault<=0;cooldown<=0;result_valid<=0;event_valid<=0;result_class<=0;event_command<=0;
   rejected_pulse<=0;reject_flags<=0;debug_sequence<=0;debug_voiced<=0;debug_duration<=0;debug_logits<=0;
   dp_addr<=0;read_addr<=0;waddr<=0;laddr<=0;interp_ring<=0;init_addr<=0;
  end else begin
   result_valid<=0;event_valid<=0;rejected_pulse<=0;if(cooldown!=0)cooldown<=cooldown-1'b1;
   if(feature_valid && state==0)begin hist[{wr,feature_index}]<=feature_data;if(feature_active)active_frame<=1;end
   if(frame_done && state==0)begin
    wr<=wr+1'b1;if(filled<127)filled<=filled+1'b1;active_frame<=0;
    if(state==0)begin
     if(active_frame || (feature_valid && feature_active))begin
      if(!utterance)begin start_frame<=wr-7'd3;total<=1;voiced<=1;end
      else begin if(total<127)total<=total+1'b1;if(voiced<127)voiced<=voiced+1'b1;end
      utterance<=1;quiet<=0;
     end else if(utterance)begin
      if(total<127)total<=total+1'b1;
      if(quiet==5)begin
       utterance<=0;quiet<=0;debug_sequence<=debug_sequence+1'b1;debug_voiced<=voiced;debug_duration<=total+1'b1;debug_logits<=0;
       if(voiced>=6 && total<90 && filled>=16 && cooldown==0)begin
        clip_start<=start_frame;clip_len<=total+7'd4;pass<=0;state<=1;for(j=0;j<13;j=j+1)totals[j]<=0;
       end else begin rejected_pulse<=1;reject_flags<=8'h01;end
      end else quiet<=quiet+1'b1;
     end
    end
   end
   case(state)
    0:begin end
    1:begin view_len<=pass==0?(clip_len*5+2)/4:pass==1?clip_len:(clip_len*4+2)/5;init_addr<=0;state<=2;end
    2:begin width<=view_len+28;
     if(local_frame<14 || local_frame>=view_len+14)begin buf_a[init_addr]<=-8'sd32;state<=7;end
     else begin phase<=pass==0?(local_frame-14)*4:pass==1?local_frame-14:(local_frame-14)*5;state<=14;end
    end
    3:state<=4;
    4:begin first_sample<=hq;interp_ring<=clip_start+(source_index+1>=clip_len?clip_len-1:source_index+1);state<=5;end
    5:state<=6;
    6:begin interp_total<=interp_value+(interp_den>>1);state<=8;end
    8:begin interp_rounded<=pass==0?interp_total/11'd5:pass==1?interp_total:interp_total>>2;state<=9;end
    9:begin buf_a[init_addr]<=interp_rounded-8'd32;state<=7;end
    14:begin source_index<=pass==0?phase/10'd5:pass==1?phase:phase>>2;fraction<=pass==0?phase%10'd5:pass==1?0:phase[1:0];state<=15;end
    15:begin interp_ring<=clip_start+(source_index>=clip_len?clip_len-1:source_index);interp_fraction<=fraction;state<=3;end
    7:if(init_addr+1>=(view_len+28)*16)begin layer<=0;t<=0;ch<=0;state<=10;end else begin init_addr<=init_addr+1'b1;state<=2;end
    10:begin acc<=biases[bindex];shift_q<=shifts[bindex];ic<=0;kernel<=0;waddr<=wbase+ch*terms;state<=11;end
    11:begin pad<=source_frame<0 || source_frame>=width;read_addr<=source_frame*ins+ic;state<=12;end
    12:state<=13;
    13:begin
     acc<=mac;
     if((layer==3 || kernel==4) && ic==ins-1)begin
      state<=16;
     end else begin waddr<=waddr+1'b1;if(layer==3 || kernel==4)begin kernel<=0;ic<=ic+1'b1;end else kernel<=kernel+1'b1;state<=11;end
    end
    16:begin
      if(layer==3)begin logits[ch]<=scaled;end
      else if(layer[0])buf_a[t*48+ch]<=scaled<0?0:scaled>127?127:scaled[7:0];
      else buf_b[t*48+ch]<=scaled<0?0:scaled>127?127:scaled[7:0];
      if(ch==outs-1)begin ch<=0;
       if(layer==3)begin ch<=1;la<=logits[0];state<=20;end
       else if(t==width-1)begin layer<=layer+1'b1;t<=0;state<=10;end
       else begin t<=t+1'b1;state<=10;end
      end else begin ch<=ch+1'b1;state<=10;end
    end
    // Shared Q6 logsumexp of all character logits.
    20:begin lb<=logits[ch];return_state<=21;state<=80;end
    21:if(ch==38)begin norm_score<=lr;ch<=0;state<=22;end else begin la<=lr;ch<=ch+1'b1;state<=20;end
    22:begin lp[ch]<=logits[ch]-norm_score;if(ch==38)begin phrase<=0;pos<=lengths[0]-1;state<=23;end else ch<=ch+1'b1;end
    23:begin
     di<=phrase*17+pos;
     if(t==0)begin dp[phrase*17+pos]<=pos==0 || (pos==1 && lengths[phrase]>1)?lp[codes[phrase*17+pos]]:NEG;state<=28;end
     else begin dp_addr<=phrase*17+pos;state<=50;end
    end
    24:begin la<=lr;dp_addr<=di-2;state<=54;end
    50:state<=51;
    51:begin la<=dp_q;dp_addr<=di-1;state<=52;end
    52:state<=53;
    53:begin lb<=pos==0?NEG:dp_q;return_state<=24;state<=80;end
    54:state<=55;
    55:begin lb<=pos>=2 && codes[di]!=0 && codes[di]!=codes[di-2]?dp_q:NEG;return_state<=25;state<=80;end
    25:begin dp[di]<=lr<=NEG/2?NEG:lr+lp[codes[di]];state<=28;end
    28:if(pos==0)begin if(phrase==12)state<=29;else begin phrase<=phrase+1'b1;pos<=lengths[phrase+1]-1;state<=23;end end else begin pos<=pos-1'b1;state<=23;end
    29:begin if(t+1>=view_len)begin phrase<=0;state<=30;end else begin t<=t+1'b1;ch<=0;state<=10;end end
    30:begin dp_addr<=phrase*17+lengths[phrase]-1;state<=56;end
    56:state<=57;
    57:begin la<=dp_q;dp_addr<=phrase*17+lengths[phrase]-2;state<=58;end
    58:state<=59;
    59:begin lb<=lengths[phrase]==1?NEG:dp_q;return_state<=31;state<=80;end
    31:begin div_num<=lr*$signed({1'b0,clip_len});div_den<=view_len;state<=90;return_state<=32;end
    32:begin totals[phrase]<=totals[phrase]+div_result;if(phrase==12)begin if(pass==2)begin phrase<=0;best<=NEG;second<=NEG;winner<=12;state<=40;end else begin pass<=pass+1'b1;state<=1;end end else begin phrase<=phrase+1'b1;state<=30;end end
    40:begin if(totals[phrase]>best)begin second<=best;best<=totals[phrase];winner<=phrase;end else if(totals[phrase]>second)second<=totals[phrase];if(phrase==12)state<=41;else phrase<=phrase+1'b1;end
    41:begin
     result_valid<=1;debug_logits[95:0]<={second,best,best-second};
     // NEXT_ONLY is intentionally a binary command gate: the user only needs
     // "下一张". Ignore the competing "上一张" phrase and compare NEXT's
     // accumulated CTC score directly with the blank/background phrase.
     if(NEXT_ONLY)begin
      if(totals[2]>totals[12] && totals[2]*10>=-$signed({1'b0,clip_len})*FLOOR_Q6_X30)begin
       result_class<=2'd1;event_valid<=1;event_command<=2'd1;cooldown<=20000000;reject_flags<=0;
      end else begin result_class<=0;rejected_pulse<=1;reject_flags<=8'h20;end
     end else if(commands[winner]!=0 && best-second>=MIN_MARGIN_Q6 && best*10>=-$signed({1'b0,clip_len})*FLOOR_Q6_X30)begin
      result_class<=commands[winner][1:0];event_valid<=1;event_command<=commands[winner][1:0];cooldown<=20000000;reject_flags<=0;
     end else begin result_class<=0;rejected_pulse<=1;reject_flags<=8'h20;end
     state<=0;
    end
    80:begin lmax<=la>lb?la:lb;ld<=la>lb?la-lb:lb-la;laddr<=la>lb?(la-lb>1023?1023:la-lb):(lb-la>1023?1023:lb-la);state<=81;end
    81:state<=82;
    82:begin lr<=lmax<=NEG/2?NEG:lmax+(ld>1023?0:lq);state<=return_state;end
    // Restoring divider keeps variable division off the timing path.
    90:begin div_mag<=div_num<0?-div_num:div_num;div_negative<=div_num<0;div_bit<=31;div_rem<=0;div_result<=0;state<=91;end
    91:begin
     if((div_rem<<1)+div_mag[div_bit]>=div_den)begin div_rem<=((div_rem<<1)+div_mag[div_bit])-div_den;div_result[div_bit]<=1;end
     else div_rem<=(div_rem<<1)+div_mag[div_bit];
     if(div_bit==0)state<=92;else div_bit<=div_bit-1'b1;
    end
    92:begin if(div_negative)div_result<=-div_result;state<=93;end
    93:state<=return_state;
    default:state<=0;
   endcase
  end
 end
endmodule
