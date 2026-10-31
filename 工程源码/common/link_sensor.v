`timescale 1ns/1ps
// ACA endpoint: establish a session, send 20 Hz snapshots, ACK/retry events.
// One outstanding + one queued event. Queue overflow is visible; never replay
// an old event after a link timeout. Templates remain intact across link loss.
module link_sensor #(parameter integer PRESCALE=54,parameter integer PERIOD=2500000,
 parameter integer RETRY=5000000,parameter integer LINK_TIMEOUT=50000000)(
 input wire clk,rst,rx,output wire tx,input wire [255:0] status,
 input wire event_valid,input wire [7:0] event_command,
 output reg online,output reg event_failed,output reg queue_overflow,
 output wire [15:0] crc_errors,output reg host_voice_enable,
 output reg event_delivered,output reg [7:0] delivered_command
);
 wire busy,received;wire [7:0] rt,rs;wire [255:0] rp;
 reg send;reg [7:0] tt,ts;reg [255:0] tp;
 reg ready_session,waiting,queued;reg [7:0] queued_cmd;reg [7:0] seq,pending_seq,pending_cmd;
 reg [2:0] attempts;reg [31:0] period_timer,retry_timer,age;
 link_packet #(.PRESCALE(PRESCALE)) u_packet(.clk(clk),.rst(rst),.rx(rx),.tx(tx),
 .send(send),.tx_type(tt),.tx_seq(ts),.tx_payload(tp),.busy(busy),
 .received(received),.rx_type(rt),.rx_seq(rs),.rx_payload(rp),.crc_errors(crc_errors));
 always @(posedge clk)begin
  if(rst || age>=LINK_TIMEOUT)host_voice_enable<=0;
  else if(received && rt==4 && rp[15:0]==16'h0103)host_voice_enable<=0;
  else if(received && rt==4 && ready_session &&
          ((rp[7:0]==1 && rs==0) || (rp[7:0]==2 && waiting && rs==pending_seq)))
   host_voice_enable<=rp[23:16]==8'ha5 && rp[8];
  if(rst)begin send<=0;tt<=0;ts<=0;tp<=0;ready_session<=0;online<=0;waiting<=0;queued<=0;queued_cmd<=0;seq<=0;pending_seq<=0;pending_cmd<=0;attempts<=0;period_timer<=PERIOD;retry_timer<=RETRY;age<=0;event_failed<=0;queue_overflow<=0;event_delivered<=0;delivered_command<=0;end
  else begin
   send<=0;event_delivered<=0;
   if(period_timer<PERIOD)period_timer<=period_timer+1'b1;
   if(retry_timer<RETRY)retry_timer<=retry_timer+1'b1;
   if(age<LINK_TIMEOUT)age<=age+1'b1;
   else begin online<=0;ready_session<=0;waiting<=0;queued<=0;end
   if(event_valid && ready_session && age<LINK_TIMEOUT)begin
    if(queued)queue_overflow<=1;else begin queued<=1;queued_cmd<=event_command;end
   end
   if(received && rt==4)begin
    if(rp[15:0]==16'h0103)begin
     // Host reboot: discard old commands, establish a new session.
     online<=0;ready_session<=0;waiting<=0;queued<=0;age<=0;retry_timer<=RETRY;
    end else if((rp[7:0]==3 && !ready_session && rs==0) ||
                (rp[7:0]==1 && ready_session && rs==0) ||
                (rp[7:0]==2 && ready_session && waiting && rs==pending_seq))begin
     online<=1;age<=0;
     if(rp[7:0]==3)ready_session<=1;
     if(rp[7:0]==2)begin
      waiting<=0;retry_timer<=RETRY;event_failed<=0;
      event_delivered<=1;delivered_command<=pending_cmd;
     end
    end
   end
   if(!busy && !send && !(received && rt==4 && rp[15:0]==16'h0103) &&
      (!ready_session || age<LINK_TIMEOUT))begin
    if(!ready_session && retry_timer>=RETRY)begin
     tt<=3;ts<=0;tp<=0;send<=1;retry_timer<=0;
    end else if(ready_session && waiting && retry_timer>=RETRY)begin
     if(attempts==5)begin waiting<=0;event_failed<=1;end
     else begin tt<=2;ts<=pending_seq;tp<={248'b0,pending_cmd};send<=1;retry_timer<=0;attempts<=attempts+1'b1;end
    end else if(ready_session && !waiting && queued)begin
     waiting<=1;queued<=0;pending_seq<=seq;pending_cmd<=queued_cmd;seq<=seq+1'b1;
     tt<=2;ts<=seq;tp<={248'b0,queued_cmd};send<=1;retry_timer<=0;attempts<=1;
    end else if(ready_session && period_timer>=PERIOD)begin
     tt<=1;ts<=0;tp<=status;send<=1;period_timer<=0;
    end
   end
  end
 end
endmodule
