`timescale 1ns/1ps
module aca_uart_tx #(
    parameter integer CLOCK_HZ=50000000,
    parameter integer BAUD=115200
)(
    input wire clk, input wire rst_n, input wire send,
    input wire [7:0] data,
    output wire tx, output reg busy
);
    localparam DIVISOR=(CLOCK_HZ+BAUD/2)/BAUD;
    localparam COUNT_BITS=DIVISOR<2 ? 1:$clog2(DIVISOR);
    reg [COUNT_BITS-1:0] timer;
    reg [3:0] bit_index;
    reg [9:0] shift;
    assign tx=busy ? shift[0]:1'b1;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin busy<=0; timer<=0; bit_index<=0; shift<=10'h3ff; end
        else if(!busy) begin
            if(send) begin
                shift<={1'b1,data,1'b0}; busy<=1; timer<=0; bit_index<=0;
            end
        end else if(timer==DIVISOR-1) begin
            timer<=0;
            if(bit_index==9) busy<=0;
            else begin shift<={1'b1,shift[9:1]}; bit_index<=bit_index+1'b1; end
        end else timer<=timer+1'b1;
    end
endmodule

// Voice-only debug stream: 74 bytes at 115200, <7 ms per 32 ms feature frame.
// Snapshot after frame_done, so feature 15 and engine endpoint registers have
// committed. CRC16-CCITT covers bytes 0..71, then low/high CRC at 72/73.
module aca_feature_report #(parameter integer CLOCK_HZ=50000000,BAUD=115200)(
 input wire clk,rst_n,feature_valid,frame_done,
 input wire [3:0] feature_index,input wire signed [7:0] feature_data,
 input wire [7:0] flags,reject_flags,engine_state,
 input wire [15:0] debug_sequence,peak,noise,sample_count,
 input wire [6:0] debug_voiced,debug_duration,input wire [287:0] debug_logits,
 output wire tx);
 reg [7:0] features[0:15],packet[0:73];
 reg [15:0] frame_sequence,crc;
 reg [6:0] index;reg [2:0] bit_count,state;
 reg pending,overrun,send;wire busy;
 aca_uart_tx #(.CLOCK_HZ(CLOCK_HZ),.BAUD(BAUD)) u_tx(.clk(clk),.rst_n(rst_n),
  .send(send),.data(packet[index]),.tx(tx),.busy(busy));
 integer i;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   frame_sequence<=0;crc<=16'hffff;index<=0;bit_count<=0;state<=0;pending<=0;overrun<=0;send<=0;
   for(i=0;i<16;i=i+1)features[i]<=0;
   for(i=0;i<74;i=i+1)packet[i]<=0;
  end else begin
   send<=0;
   if(feature_valid)features[feature_index]<=feature_data;
   if(frame_done)begin
    frame_sequence<=frame_sequence+1'b1;
    if(state==0 && !pending)pending<=1;else overrun<=1;
   end
   case(state)
    0:if(pending)begin
     pending<=0;index<=0;crc<=16'hffff;state<=1;
     packet[0]<=8'ha5;packet[1]<=8'h5a;packet[2]<=8'h52;
     packet[3]<=frame_sequence[7:0];packet[4]<=frame_sequence[15:8];
     packet[5]<=flags;packet[6]<=reject_flags;packet[7]<={1'b0,debug_voiced};
     packet[8]<={1'b0,debug_duration};packet[9]<=debug_sequence[7:0];packet[10]<=debug_sequence[15:8];
     packet[11]<=engine_state;
     for(i=0;i<16;i=i+1)packet[12+i]<=features[i];
     for(i=0;i<36;i=i+1)packet[28+i]<=debug_logits[i*8+:8];
     packet[64]<=peak[7:0];packet[65]<=peak[15:8];packet[66]<=noise[7:0];packet[67]<=noise[15:8];
     packet[68]<=sample_count[7:0];packet[69]<=sample_count[15:8];packet[70]<=8'h23;
     packet[71]<={7'd0,overrun};
    end
    1:begin crc<=crc^{packet[index],8'd0};bit_count<=0;state<=2;end
    2:begin
     crc<=crc[15]?(crc<<1)^16'h1021:crc<<1;
     if(bit_count==7)begin
      if(index==71)state<=3;else begin index<=index+1'b1;state<=1;end
     end else bit_count<=bit_count+1'b1;
    end
    3:begin packet[72]<=crc[7:0];packet[73]<=crc[15:8];index<=0;state<=4;end
    4:if(!busy)begin send<=1;state<=5;end
    5:if(busy)state<=6;
    6:if(!busy)begin if(index==73)state<=0;else begin index<=index+1'b1;state<=4;end end
    default:state<=0;
   endcase
  end
 end
endmodule

// 596-byte voice-only packets at 460800 baud: exact 8 kHz frontend input
// plus the original features/logits. Double-buffered synchronous PCM RAM.
// Bytes 0..71 retain the feature report layout (opcode 55), 72..73 count,
// 74..585 signed PCM16 LE, 586..593 command trace, 594..595 CRC16 over all preceding bytes.
module aca_pcm_feature_report #(parameter integer CLOCK_HZ=50000000,BAUD=460800)(
 input wire clk,rst_n,pcm_valid,input wire signed [15:0] pcm,
 input wire feature_valid,frame_done,
 input wire [3:0] feature_index,input wire signed [7:0] feature_data,
 input wire [7:0] flags,reject_flags,engine_state,
 input wire [15:0] debug_sequence,peak,noise,sample_count,
 input wire [6:0] debug_voiced,debug_duration,input wire [287:0] debug_logits,
 input wire [63:0] command_trace,
 output wire tx);
 reg [7:0] features[0:15],header[0:73],trace_snapshot[0:7];
 (* ram_style="bram" *) reg signed [15:0] pcm_memory[0:511];
 reg write_bank,read_bank;
 reg [7:0] write_index;
 reg [8:0] pcm_count,snapshot_count;
 reg [15:0] frame_sequence,crc,packet_crc;
 reg [9:0] index;
 reg [2:0] bit_count;
 reg [3:0] state;
 reg pending,overrun,pcm_mismatch,send;wire busy;
 wire [9:0] pcm_offset=index-10'd74;
 reg signed [15:0] pcm_q;
 always @(posedge clk)pcm_q<=pcm_memory[{read_bank,pcm_offset[8:1]}];
 wire [7:0] byte_value=index<74?header[index]:index<586?
   (index[0]?pcm_q[15:8]:pcm_q[7:0]):index<594?trace_snapshot[index-586]:index==594?packet_crc[7:0]:packet_crc[15:8];
 aca_uart_tx #(.CLOCK_HZ(CLOCK_HZ),.BAUD(BAUD)) u_tx(.clk(clk),.rst_n(rst_n),
  .send(send),.data(byte_value),.tx(tx),.busy(busy));
 integer i;
 // No reset on PCM RAM or its read register, allowing true block RAM.
 always @(posedge clk)if(rst_n && pcm_valid && pcm_count<256)
   pcm_memory[{write_bank,write_index}]<=pcm;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   write_bank<=0;read_bank<=1;write_index<=0;pcm_count<=0;snapshot_count<=0;
   frame_sequence<=0;crc<=16'hffff;packet_crc<=0;index<=0;bit_count<=0;state<=0;
   pending<=0;overrun<=0;pcm_mismatch<=0;send<=0;
   for(i=0;i<16;i=i+1)features[i]<=0;
   for(i=0;i<74;i=i+1)header[i]<=0;
   for(i=0;i<8;i=i+1)trace_snapshot[i]<=0;
  end else begin
   send<=0;
   if(feature_valid)features[feature_index]<=feature_data;
   if(pcm_valid)begin
    if(pcm_count<256)begin write_index<=write_index+1'b1;pcm_count<=pcm_count+1'b1;end
    else pcm_mismatch<=1;
   end
   if(frame_done)begin
    frame_sequence<=frame_sequence+1'b1;
    write_index<=0;pcm_count<=0;
    if(state==0 && !pending)begin
     read_bank<=write_bank;write_bank<=~write_bank;
     snapshot_count<=pcm_count+((pcm_valid && pcm_count<256)?9'd1:9'd0);
     pending<=1;
    end else overrun<=1;
    if(pcm_count+((pcm_valid && pcm_count<256)?9'd1:9'd0)!=256)pcm_mismatch<=1;
   end
   case(state)
    0:if(pending)begin
     pending<=0;index<=0;crc<=16'hffff;state<=1;
     header[0]<=8'ha5;header[1]<=8'h5a;header[2]<=8'h55;
     header[3]<=frame_sequence[7:0];header[4]<=frame_sequence[15:8];
     header[5]<=flags;header[6]<=reject_flags;header[7]<={1'b0,debug_voiced};
     header[8]<={1'b0,debug_duration};header[9]<=debug_sequence[7:0];header[10]<=debug_sequence[15:8];
     header[11]<=engine_state;
     for(i=0;i<16;i=i+1)header[12+i]<=features[i];
     for(i=0;i<36;i=i+1)header[28+i]<=debug_logits[i*8+:8];
     header[64]<=peak[7:0];header[65]<=peak[15:8];header[66]<=noise[7:0];header[67]<=noise[15:8];
     header[68]<=sample_count[7:0];header[69]<=sample_count[15:8];header[70]<=8'h25;
     header[71]<={6'd0,pcm_mismatch,overrun};
     for(i=0;i<8;i=i+1)trace_snapshot[i]<=command_trace[i*8+:8];
     header[72]<=snapshot_count[7:0];header[73]<={7'd0,snapshot_count[8]};
    end
    1:state<=2; // Synchronous PCM read settles after changing index.
    2:begin crc<=crc^{byte_value,8'd0};bit_count<=0;state<=3;end
    3:begin
     crc<=crc[15]?(crc<<1)^16'h1021:crc<<1;
     if(bit_count==7)begin
      if(index==593)state<=4;else begin index<=index+1'b1;state<=1;end
     end else bit_count<=bit_count+1'b1;
    end
    4:begin packet_crc<=crc;index<=0;state<=5;end
    5:if(!busy)begin send<=1;state<=6;end
    6:if(busy)state<=7;
    7:if(!busy)begin if(index==595)state<=0;else begin index<=index+1'b1;state<=5;end end
    default:state<=0;
   endcase
  end
 end
endmodule

module aca_uart_report #(
    parameter integer CLOCK_HZ=50000000,
    parameter integer BAUD=115200,
    parameter integer PERIOD_CYCLES=5000000
)(
    input wire clk, input wire rst_n, input wire event_pending,
    input wire [7:0] flags,
    input wire [15:0] clap_count, peak, noise, threshold, sample_count,
    output wire tx
);
    reg [31:0] timer;
    reg due;
    reg [7:0] sequence_id;
    reg [7:0] packet[0:15];
    reg [3:0] index;
    reg [2:0] state;
    reg send;
    wire busy;
    wire [7:0] check=8'ha5^8'h5a^8'h01^sequence_id^flags^
        clap_count[7:0]^clap_count[15:8]^peak[7:0]^peak[15:8]^
        noise[7:0]^noise[15:8]^threshold[7:0]^threshold[15:8]^
        sample_count[7:0]^sample_count[15:8];
    aca_uart_tx #(.CLOCK_HZ(CLOCK_HZ),.BAUD(BAUD)) u_tx (
        .clk(clk),.rst_n(rst_n),.send(send),.data(packet[index]),.tx(tx),.busy(busy)
    );
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            timer<=0; due<=0; sequence_id<=0; index<=0; state<=0; send<=0;
            for(i=0;i<16;i=i+1) packet[i]<=0;
        end else begin
            send<=0;
            if(timer>=PERIOD_CYCLES-1) begin timer<=0; due<=1; end
            else timer<=timer+1'b1;
            if(event_pending) due<=1;
            case(state)
                0: if(due) begin
                    due<=event_pending; index<=0; sequence_id<=sequence_id+1'b1;
                    packet[0]<=8'ha5; packet[1]<=8'h5a; packet[2]<=1;
                    packet[3]<=sequence_id; packet[4]<=flags;
                    packet[5]<=clap_count[7:0]; packet[6]<=clap_count[15:8];
                    packet[7]<=peak[7:0]; packet[8]<=peak[15:8];
                    packet[9]<=noise[7:0]; packet[10]<=noise[15:8];
                    packet[11]<=threshold[7:0]; packet[12]<=threshold[15:8];
                    packet[13]<=sample_count[7:0]; packet[14]<=sample_count[15:8];
                    packet[15]<=check; state<=1;
                end
                1: if(!busy) begin send<=1; state<=2; end
                2: if(busy) state<=3;
                3: if(!busy) begin
                    if(index==15) state<=0;
                    else begin index<=index+1'b1; state<=1; end
                end
                default: state<=0;
            endcase
        end
    end
endmodule
