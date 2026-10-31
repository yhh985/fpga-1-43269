`timescale 1ns/1ps
// Bundled-data mailbox: source holds ALL bits until destination frame commit.
// Only request/ack toggles cross synchronizers. No per-bit bus synchronizer.
module link_snapshot_cdc(
 input wire source_clk,dest_clk,rst,input wire source_valid,
 input wire [256:0] source_data,input wire frame_start,
 output reg [256:0] dest_data
);
 reg [256:0] hold_data;
 reg request,ack;
 (* async_reg="true", syn_preserve=1 *) reg [1:0] ack_sync,request_sync;
 always @(posedge source_clk or posedge rst)begin
  if(rst)begin hold_data<=0;request<=0;ack_sync<=0;end
  else begin
   ack_sync<={ack_sync[0],ack};
   if(source_valid && ack_sync[1]==request)begin hold_data<=source_data;request<=~request;end
  end
 end
 always @(posedge dest_clk or posedge rst)begin
  if(rst)begin request_sync<=0;ack<=0;dest_data<=0;end
  else begin
   request_sync<={request_sync[0],request};
   if(frame_start && request_sync[1]!=ack)begin
    dest_data<=hold_data;ack<=request_sync[1];
   end
  end
 end
endmodule
