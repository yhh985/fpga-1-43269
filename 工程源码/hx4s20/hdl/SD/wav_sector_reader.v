`timescale 1ns/1ps
// Reserve room for the worst mono sector (256 stereo FIFO words) BEFORE
// issuing a sector. In-flight CRC-checked bytes cannot be backpressured.
// On mode exit keep the transaction until end, discard it, then restart at
// the header. Completed PCM loops by reparsing headers without clearing FIFO.
module wav_sector_reader #(parameter AB=12)(
 input clk,rst,mounted,found,enabled,input [31:0] file_bytes,
 input [AB:0] fifo_used,input fifo_full,
 output reg read_req,output [31:0] read_addr,
 input [7:0] read_data,input read_valid,read_end,
 output pcm_valid,output [31:0] pcm_frame,
 output stream_ok,output reg error,output [3:0] state_code
);
 localparam IDLE=0,READ=1,GAP=2,RESTART=3;
 reg [1:0] state;
 reg [16:0] sector;
 reg [1:0] reset_count;
 reg canceled,parser_reset;
 reg room;
 always @(posedge clk or posedge rst)if(rst)room<=0;else room<=fifo_used<=((1<<AB)-256);
 wire p_error,p_done,p_format,p_ready;
 wire session=mounted&&found&&enabled;
 assign stream_ok=session&&!error&&!canceled;
 assign read_addr={1'b1,14'd0,sector};
 assign state_code=!found?4'd1:error?4'd5:!enabled?4'd0:4'd2;
 wire parser_valid=read_valid&&state==READ&&stream_ok;
 wire [26:0] sector_end=({10'd0,sector}+27'd1)<<9;
 wav_pcm_parser u_parser(.clk(clk),.rst(rst||parser_reset||!session||canceled),
  .file_size(file_bytes),.byte_valid(parser_valid),.byte_data(read_data),.byte_ready(p_ready),
  .pcm_valid(pcm_valid),.pcm_frame(pcm_frame),.format_ok(p_format),.done(p_done),.error(p_error));
 always @(posedge clk or posedge rst)begin
  if(rst)begin state<=IDLE;sector<=0;read_req<=0;canceled<=0;error<=0;parser_reset<=1;reset_count<=0;end
  else if(!mounted)begin state<=IDLE;sector<=0;read_req<=0;canceled<=0;error<=0;parser_reset<=1;reset_count<=0;end
  else begin
   if(!enabled)error<=0;
   else if(p_error||(pcm_valid&&fifo_full))error<=1;
   case(state)
    IDLE:begin
     read_req<=0;
     if(!session)begin sector<=0;parser_reset<=1;canceled<=0;end
     else if(!error&&room)begin parser_reset<=0;read_req<=1;state<=READ;end
    end
    READ:begin
     if(!session)canceled<=1;
     if(read_end)begin
      read_req<=0;state<=GAP;
      if(!p_done&&sector_end>=file_bytes&&!canceled&&session)error<=1;
     end
    end
    GAP:begin
     // Owner deassertion reaches the filesystem WAIT_RELEASE before reuse.
     if(canceled||!session||p_done)begin sector<=0;parser_reset<=1;reset_count<=0;state<=RESTART;end
     else begin sector<=sector+1'b1;state<=IDLE;end
    end
    RESTART:begin
     if(reset_count==3)begin canceled<=0;parser_reset<=0;state<=IDLE;end
     else reset_count<=reset_count+1'b1;
    end
   endcase
  end
 end
endmodule
