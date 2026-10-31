`timescale 1ns/1ps
// Fixed 38-byte frame: A5 5A type seq payload[0..31] CRC16 little endian.
// CRC-CCITT (1021, init FFFF) covers type, seq, payload. No CPU required.
module link_packet #(parameter integer PRESCALE=54, parameter integer RX_TIMEOUT=500000)(
 input wire clk,rst,rx, output wire tx,
 input wire send, input wire [7:0] tx_type,tx_seq,
 input wire [255:0] tx_payload, output wire busy,
 output reg received, output reg [7:0] rx_type,rx_seq,
 output reg [255:0] rx_payload, output reg [15:0] crc_errors
);
 function [15:0] crc_step;
  input [15:0] crc; input [7:0] data; integer j; reg [15:0] c;
  begin c=crc ^ {data,8'b0};for(j=0;j<8;j=j+1)c=c[15]?(c<<1)^16'h1021:c<<1;crc_step=c;end
 endfunction
 reg [1:0] rx_sync;
 always @(posedge clk) if(rst) rx_sync<=3;else rx_sync<={rx_sync[0],rx};
 // Reject pulses shorter than one eighth of a UART bit. Symmetric stable
 // qualification delays both edges equally; CRC remains mandatory.
 reg rx_clean;
 reg [15:0] rx_stable;
 always @(posedge clk)begin
  if(rst)begin rx_clean<=1;rx_stable<=0;end
  else if(rx_sync[1]==rx_clean)rx_stable<=0;
  else if(rx_stable>=PRESCALE-1)begin rx_clean<=rx_sync[1];rx_stable<=0;end
  else rx_stable<=rx_stable+1'b1;
 end
 localparam [15:0] UART_PRESCALE=PRESCALE;
 wire [7:0] rdata; wire rv,frame_error;
 uart_rx u_rx(.clk(clk),.rst(rst),.m_axis_tdata(rdata),.m_axis_tvalid(rv),
 .m_axis_tready(1'b1),.rxd(rx_clean),.busy(),.overrun_error(),.frame_error(frame_error),.prescale(UART_PRESCALE));
 reg sending;reg [5:0] ti;reg [7:0] tt,ts;reg [255:0] tp;reg [15:0] tc;
 reg [7:0] tdata;wire tr;
 assign busy=sending;
 always @* case(ti)
  0:tdata=8'ha5;1:tdata=8'h5a;2:tdata=tt;3:tdata=ts;
  36:tdata=tc[7:0];37:tdata=tc[15:8];default:tdata=tp[(ti-4)*8+:8];
 endcase
 uart_tx u_tx(.clk(clk),.rst(rst),.s_axis_tdata(tdata),.s_axis_tvalid(sending),
 .s_axis_tready(tr),.txd(tx),.busy(),.prescale(UART_PRESCALE));
 always @(posedge clk) begin
  if(rst)begin sending<=0;ti<=0;tt<=0;ts<=0;tp<=0;tc<=16'hffff;end
  else if(!sending)begin
   if(send)begin sending<=1;ti<=0;tt<=tx_type;ts<=tx_seq;tp<=tx_payload;tc<=16'hffff;end
  end else if(tr)begin
   if(ti>=2 && ti<=35)tc<=crc_step(tc,tdata);
   if(ti==37)sending<=0;else ti<=ti+1'b1;
  end
 end
 reg [5:0] ri;reg [15:0] rc;reg [7:0] low_crc,rt,rs;reg [255:0] rp;
 reg [31:0] timeout;
 always @(posedge clk)begin
  if(rst)begin ri<=0;rc<=16'hffff;timeout<=0;received<=0;rx_type<=0;rx_seq<=0;rx_payload<=0;crc_errors<=0;rt<=0;rs<=0;rp<=0;low_crc<=0;end
  else begin
   received<=0;
   if(ri!=0)begin
    if(timeout>=RX_TIMEOUT-1 || frame_error)begin ri<=0;timeout<=0;end
    else timeout<=timeout+1'b1;
   end
   if(rv)begin
    timeout<=0;
    case(ri)
     0:if(rdata==8'ha5)ri<=1;
     1:if(rdata==8'h5a)begin ri<=2;rc<=16'hffff;end else ri<=rdata==8'ha5 ? 1:0;
     2:begin rt<=rdata;rc<=crc_step(rc,rdata);ri<=3;end
     3:begin rs<=rdata;rc<=crc_step(rc,rdata);ri<=4;end
     36:begin low_crc<=rdata;ri<=37;end
     37:begin
      ri<=0;
      if({rdata,low_crc}==rc)begin received<=1;rx_type<=rt;rx_seq<=rs;rx_payload<=rp;end
      else crc_errors<=crc_errors+1'b1;
     end
     default:begin rp[(ri-4)*8+:8]<=rdata;rc<=crc_step(rc,rdata);ri<=ri+1'b1;end
    endcase
   end
  end
 end
endmodule
