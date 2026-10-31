`timescale 1ns/1ps
// HX endpoint: ACK all supported frames; execute a repeated event only once.
module link_host #(parameter integer PRESCALE=54,parameter integer LINK_TIMEOUT=50000000)(
 input wire clk,rst,rx,output wire tx,input wire voice_allow,
 output reg online,output reg command_valid,output reg [1:0] command,
 output reg music_valid,output reg [7:0] music_command,
 output reg status_valid,output reg [255:0] status,
 output wire [15:0] crc_errors
);
 wire received,busy;wire [7:0] rt,rs;wire [255:0] rp;
 reg send;reg [7:0] ack_seq;reg [255:0] ack_payload;reg ack_pending;
 reg session_active;reg last_valid;reg [7:0] last_seq;reg [31:0] age;
 link_packet #(.PRESCALE(PRESCALE)) u_packet(.clk(clk),.rst(rst),.rx(rx),.tx(tx),
 .send(send),.tx_type(8'd4),.tx_seq(ack_seq),.tx_payload(ack_payload),.busy(busy),
 .received(received),.rx_type(rt),.rx_seq(rs),.rx_payload(rp),.crc_errors(crc_errors));
 always @(posedge clk)begin
  if(rst)begin session_active<=0;online<=0;age<=0;music_valid<=0;music_command<=0;command_valid<=0;command<=0;status_valid<=0;status<=0;last_valid<=0;last_seq<=0;ack_seq<=0;ack_payload<=0;ack_pending<=0;send<=0;end
  else begin
   music_valid<=0;music_command<=0;command_valid<=0;status_valid<=0;send<=0;
   if(age<LINK_TIMEOUT)age<=age+1'b1;else begin online<=0;session_active<=0;last_valid<=0;end
   if(!busy && !send && ack_pending)begin send<=1;ack_pending<=0;end
   if(received && (rt==1 || rt==2 || rt==3))begin
    ack_seq<=rs;ack_pending<=1;
    if(rt==3)begin
     session_active<=1;online<=1;age<=0;last_valid<=0;status<=0;
     ack_payload<=256'd3;
    end else if(!session_active || age>=LINK_TIMEOUT)begin
     // A restarted host requests a fresh HELLO before executing any event.
     // byte1=1 distinguishes this resync request from a normal HELLO ACK.
     ack_payload<=256'h0103;
    end else begin
     online<=1;age<=0;ack_payload<={232'b0,8'ha5,7'b0,voice_allow,rt};
     if(rt==1)begin status<=rp;status_valid<=1;end
     if(rt==2 && rp[7:0]>=1 && rp[7:0]<=6)begin
      if(!last_valid || last_seq!=rs)begin
       if(rp[7:0]<=3)begin command_valid<=1;command<=rp[1:0];end
       else begin music_valid<=1;music_command<=rp[7:0];end
      end
      last_valid<=1;last_seq<=rs;
     end
    end
   end
  end
 end
endmodule
