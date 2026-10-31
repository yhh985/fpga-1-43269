`timescale 1ns/1ps
// One shared INT8 MAC, synchronous ROM reads, 768 -> 48 -> 3 MLP.
// Model paths and thresholds are explicitly passed by the generated top config.
module aca_kws_engine #(
 parameter WEIGHTS_FILE="E:/anlo_project/liantiao/final_showcase_20261030/voice/experiments/robust_normalized/model/weights.mem",BIAS_FILE="E:/anlo_project/liantiao/final_showcase_20261030/voice/experiments/robust_normalized/model/bias.mem",
 parameter integer SHIFT=8,MIN_MARGIN=791,
 parameter signed [31:0] MIN_WINNER_SCORE=32'sh80000000,
 parameter integer RELAXED_MARGIN=650,RELAXED_TOTAL_MARGIN=3600,
 parameter integer COOLDOWN_CYCLES=75000000,ENDPOINT_MODE=1,
 parameter integer CONSENSUS_PASSES=3,ISOLATE_UTTERANCE=1,
 parameter integer PREQUIET_FRAMES=6,TRANSIENT_CREDIT=1,
 parameter integer NORMALIZE_UTTERANCE=1,MAX_UTTERANCE_FRAMES=96
)(input wire clk,rst,feature_valid,input wire [3:0] feature_index,
 input wire signed [7:0] feature_data,input wire frame_done,
 output reg result_valid,output reg [1:0] result_class,
 output reg signed [31:0] logit0,logit1,logit2,
 output reg event_valid,output reg [1:0] event_command,output reg fault,
 output wire window_ready,quiet_ready,utterance_active,processing,
 output reg rejected_pulse,
 output reg [7:0] reject_flags,
 output reg [15:0] debug_sequence,
 output reg [6:0] debug_voiced,debug_duration,
 output reg [287:0] debug_logits);
 (* ram_style="bram" *) reg signed [7:0] weights[0:37007];
 reg signed [31:0] biases[0:50];
 (* ram_style="bram" *) reg signed [7:0] history[0:2047];
 reg signed [7:0] hidden[0:47];
 initial begin $readmemh(WEIGHTS_FILE,weights);$readmemh(BIAS_FILE,biases);end
 reg [6:0] write_frame,filled;reg [1:0] stride;
 reg frame_active,utterance;reg [2:0] quiet_frames;
 reg [6:0] voiced_frames,utterance_frames;
 reg [2:0] state;reg layer;reg [5:0] neuron;reg [9:0] input_count;
 reg [10:0] oldest,read_addr;reg [15:0] weight_addr;
 reg signed [7:0] history_q,hidden_q,weight_q;
 reg [9:0] first_valid_input;
 // Three whole-utterance time scales; six trailing quiet frames are zero.
 reg [6:0] utterance_start,normalized_start,speech_frames;
 wire [5:0] pad_frames=pass_index==0?6'd4:pass_index==1?6'd2:6'd0;
 wire normalized_valid=input_count[9:4]>=pad_frames && input_count[9:4]<42;
 reg [47:0] native_valid;
 wire mapped_valid=NORMALIZE_UTTERANCE ? normalized_valid : native_valid[input_count[9:4]];
 wire signed [7:0] input_q=layer?hidden_q:!mapped_valid?8'sd0:history_q;
 // Precompute floor(j*length/target) by accumulation and repeated subtraction.
 // This removes division/multiplication from the 50 MHz history address path.
 reg [6:0] frame_map[0:47];
 reg [5:0] map_index;
 reg [6:0] map_offset;
 reg [7:0] map_phase;
 wire [5:0] target_frames=pass_index==0?6'd38:pass_index==1?6'd40:6'd42;
 wire [9:0] next_count=input_count+10'd1;
 wire [10:0] next_mapped_addr={frame_map[next_count[9:4]],next_count[3:0]};
 reg [1:0] pass_index,vote_class;
 // Historical fixed 48-frame windows, ending at adjacent endpoint positions.
 // Mask anything before this utterance, so old commands cannot replay in noise.
 localparam signed [8:0] NATIVE_PAD=42+CONSENSUS_PASSES-1;
 wire signed [8:0] native_offset=$signed({2'b0,speech_frames})+
   $signed({3'b0,map_index})+$signed({7'b0,pass_index})-NATIVE_PAD;
 reg votes_ok,utterance_allowed;
 reg votes_relaxed;
 reg [33:0] margin_sum;
 reg [3:0] quiet_run;
 assign window_ready=filled>=47;
 assign quiet_ready=quiet_run>=PREQUIET_FRAMES;
 assign utterance_active=utterance;
 assign processing=state!=0;
 reg [1:0] winner;reg signed [31:0] best,second;
 wire accepted_pass=winner!=0 && best-second>=MIN_MARGIN && best>=MIN_WINNER_SCORE;
 wire signed [31:0] pass_margin=best-second;
 // Keep three agreeing non-background directions. A weaker individual view
 // is allowed only when all margins meet the floor and their total is strong.
 wire relaxed_accept=ENDPOINT_MODE && CONSENSUS_PASSES==3 && RELAXED_MARGIN>0 &&
   votes_relaxed && winner!=0 && winner==vote_class && pass_margin>=RELAXED_MARGIN && best>=MIN_WINNER_SCORE &&
   (margin_sum+{2'd0,pass_margin})>=RELAXED_TOTAL_MARGIN;
 reg [7:0] pass_flags;
 wire [7:0] current_pass_flags={1'b0,(pass_index!=0 && winner!=vote_class),
   (best-second<MIN_MARGIN || best<MIN_WINNER_SCORE),(winner==0),4'b0000};
 // TD infers ERAM only with an unreset synchronous read register.
 always @(posedge clk)begin
  weight_q<=weights[weight_addr];
  history_q<=history[read_addr];
  hidden_q<=hidden[input_count];
 end
 reg signed [31:0] acc;
 wire signed [15:0] product=input_q*weight_q;
 wire signed [31:0] sum=acc+{{16{product[15]}},product};
 wire signed [31:0] scaled=sum>>>SHIFT;
 reg [26:0] cooldown;reg [3:0] rejects;reg armed;
 always @*begin
  if(logit1>logit0)begin best=logit1;second=logit0;winner=1;end
  else begin best=logit0;second=logit1;winner=0;end
  if(logit2>best)begin second=best;best=logit2;winner=2;end
  else if(logit2>second)second=logit2;
 end
 always @(posedge clk)begin
  if(rst)begin
   write_frame<=0;filled<=0;stride<=0;state<=0;layer<=0;neuron<=0;input_count<=0;
   oldest<=0;read_addr<=0;weight_addr<=0;acc<=0;
   result_valid<=0;result_class<=0;logit0<=0;logit1<=0;logit2<=0;
   event_valid<=0;event_command<=0;fault<=0;cooldown<=0;rejects<=0;armed<=1;
   frame_active<=0;utterance<=0;quiet_frames<=0;voiced_frames<=0;utterance_frames<=0;
   first_valid_input<=0;pass_index<=0;vote_class<=0;votes_ok<=1;votes_relaxed<=1;margin_sum<=0;
   quiet_run<=0;utterance_allowed<=0;
   utterance_start<=0;normalized_start<=0;speech_frames<=0;
   map_index<=0;map_offset<=0;map_phase<=0;native_valid<=0;
   rejected_pulse<=0;
   reject_flags<=0;debug_sequence<=0;debug_voiced<=0;debug_duration<=0;debug_logits<=0;pass_flags<=0;
  end else begin
   result_valid<=0;event_valid<=0;rejected_pulse<=0;
   if(cooldown!=0)cooldown<=cooldown-1'b1;
   if(feature_valid)begin
    history[{write_frame,feature_index}]<=feature_data;
    if(feature_data!=0)frame_active<=1;
   end
   if(frame_done)begin
    frame_active<=0;
    if(frame_active || (feature_valid && feature_data!=0))begin
     quiet_run<=0;
     if(!utterance)begin utterance_allowed<=quiet_run>=PREQUIET_FRAMES;utterance_start<=write_frame;end
     utterance<=1;quiet_frames<=0;
     if(voiced_frames<127)voiced_frames<=voiced_frames+1'b1;
     if(utterance_frames<127)utterance_frames<=utterance_frames+1'b1;
    end else begin
     if(quiet_run<15)quiet_run<=quiet_run+1'b1;
     if(utterance)begin
     if(utterance_frames<127)utterance_frames<=utterance_frames+1'b1;
     if(quiet_frames==5)begin
      debug_sequence<=debug_sequence+1'b1;
      debug_voiced<=voiced_frames;debug_duration<=utterance_frames+1'b1;debug_logits<=0;
      reject_flags<={4'd0,(filled<47),!utterance_allowed,(utterance_frames>=MAX_UTTERANCE_FRAMES),(voiced_frames<6)};
      if(voiced_frames<6 || utterance_frames>=MAX_UTTERANCE_FRAMES || !utterance_allowed || filled<47)
       rejected_pulse<=1;
      // An isolated transient too short to be speech must not revoke quiet
      // qualification already earned before it. Never grant credit to a
      // transient that itself began without enough quiet.
      if(TRANSIENT_CREDIT && voiced_frames<6 && utterance_allowed && quiet_run<PREQUIET_FRAMES)
       quiet_run<=PREQUIET_FRAMES;
      utterance<=0;quiet_frames<=0;voiced_frames<=0;utterance_frames<=0;
     end else quiet_frames<=quiet_frames+1'b1;
     end
    end
    write_frame<=write_frame+1'b1;
    if(filled<127)filled<=filled+1'b1;
    stride<=stride+1'b1;
    // Classify only after a whole utterance. Sliding mode is a verification hook.
    if(filled>=47 && ((!ENDPOINT_MODE && stride==3) ||
       (ENDPOINT_MODE && utterance && !frame_active && !(feature_valid && feature_data!=0) &&
        quiet_frames==5 && voiced_frames>=6 && utterance_frames<MAX_UTTERANCE_FRAMES && utterance_allowed)))begin
     if(state!=0)fault<=1;
     else begin
      // Capture complete speech (up to 90 frames), not the last 48 only.
      normalized_start<=utterance_start;speech_frames<=utterance_frames-7'd5;
      read_addr<={utterance_start,4'b0};
      map_index<=0;map_offset<=0;map_phase<=0;
      pass_index<=0;vote_class<=0;votes_ok<=1;votes_relaxed<=1;margin_sum<=0;
      pass_flags<=0;
      weight_addr<=0;input_count<=0;neuron<=0;layer<=0;state<=5;
     end
    end
   end
   case(state)
    0:begin end
    1:begin acc<=biases[layer?48+neuron:neuron];input_count<=0;state<=2;end
    2:state<=3;
    3:begin
     weight_addr<=weight_addr+1'b1;
     if((!layer && input_count==767) || (layer && input_count==47))begin
      if(!layer)begin
       hidden[neuron]<=scaled<0?0:scaled>127?127:scaled[7:0];
       if(neuron==47)begin layer<=1;neuron<=0;end else neuron<=neuron+1'b1;
       read_addr<={frame_map[0],4'b0};state<=1;
      end else begin
       case(neuron)0:logit0<=sum;1:logit1<=sum;2:logit2<=sum;endcase
       if(neuron==2)state<=4;else begin neuron<=neuron+1'b1;state<=1;end
      end
     end else begin
      acc<=sum;input_count<=input_count+1'b1;
      if(!layer)read_addr<=next_mapped_addr;
      state<=2;
     end
    end
    4:begin
     margin_sum<=margin_sum+{2'd0,pass_margin};
     case(pass_index)
      0:debug_logits[95:0]<={logit2,logit1,logit0};
      1:debug_logits[191:96]<={logit2,logit1,logit0};
      2:debug_logits[287:192]<={logit2,logit1,logit0};
     endcase
     pass_flags<=pass_flags|current_pass_flags;
     if(ENDPOINT_MODE && pass_index<CONSENSUS_PASSES-1)begin
      if(pass_index==0)vote_class<=winner;
      votes_ok<=votes_ok && accepted_pass && (pass_index==0 || winner==vote_class);
      votes_relaxed<=votes_relaxed && winner!=0 && pass_margin>=RELAXED_MARGIN && best>=MIN_WINNER_SCORE &&
        (pass_index==0 || winner==vote_class);
      pass_index<=pass_index+1'b1;
      read_addr<={normalized_start,4'b0};
      map_index<=0;map_offset<=0;map_phase<=0;
      weight_addr<=0;input_count<=0;neuron<=0;layer<=0;state<=5;
     end else begin
     result_valid<=1;state<=0;
     reject_flags<=pass_flags|current_pass_flags;
     if((accepted_pass && (!ENDPOINT_MODE || CONSENSUS_PASSES==1 || (votes_ok && winner==vote_class))) || relaxed_accept)begin
      if(relaxed_accept)reject_flags<=(pass_flags|current_pass_flags)&8'hdf;
      result_class<=winner;rejects<=0;
      if((armed || ENDPOINT_MODE) && cooldown==0)begin
       event_valid<=1;event_command<=winner==1?1:2;
       cooldown<=COOLDOWN_CYCLES;armed<=0;
      end else if(cooldown!=0)begin
       rejected_pulse<=1;reject_flags<=8'h80;
      end
     end else begin
      rejected_pulse<=1;
      result_class<=0;
      if(rejects<4)rejects<=rejects+1'b1;else armed<=1;
     end
     end
    end
    5:begin
     if(!NORMALIZE_UTTERANCE)begin
      frame_map[map_index]<=normalized_start+native_offset[6:0];
      native_valid[map_index]<=native_offset>=0 && native_offset<$signed({2'b0,speech_frames});
      if(map_index==47)begin read_addr<={frame_map[0],4'b0};state<=1;end
      else map_index<=map_index+1'b1;
     end else if(map_index<pad_frames || map_index>=42)begin
      frame_map[map_index]<=normalized_start;
      if(map_index==47)state<=1;else map_index<=map_index+1'b1;
     end else begin
      frame_map[map_index]<=normalized_start+map_offset;
      map_phase<=map_phase+{1'b0,speech_frames};
      map_index<=map_index+1'b1;state<=6;
     end
    end
    6:begin
     if(map_phase>={2'b0,target_frames})begin
      map_phase<=map_phase-{2'b0,target_frames};map_offset<=map_offset+1'b1;
     end else state<=5;
    end
    default:state<=0;
   endcase
  end
 end
endmodule
