`timescale 1ns/1ps
module tb_uart_antiglitch;
 reg clk=0,rst=1,send=0,spike=0;
 always #10 clk=~clk;
 wire tx,busy,received;wire [7:0] rt,rs;wire [255:0] rp;wire [15:0] errors;
 link_packet tx_packet(.clk(clk),.rst(rst),.rx(1'b1),.tx(tx),.send(send),
  .tx_type(8'd2),.tx_seq(8'd19),.tx_payload(256'h123456789abcdef),.busy(busy),
  .received(),.rx_type(),.rx_seq(),.rx_payload(),.crc_errors());
 link_packet rx_packet(.clk(clk),.rst(rst),.rx(tx^spike),.tx(),.send(1'b0),
  .tx_type(8'd0),.tx_seq(8'd0),.tx_payload(256'd0),.busy(),
  .received(received),.rx_type(rt),.rx_seq(rs),.rx_payload(rp),.crc_errors(errors));
 integer accepted=0,pulses=0,width;
 always @(posedge clk)if(received)begin
  if(rt!==2 || rs!==19 || rp!==256'h123456789abcdef)$fatal(1,"changed command accepted");
  accepted=accepted+1;
 end
 initial begin
  wait(!rst);
  forever begin
   repeat(1003)@(negedge clk);
   width=1+(pulses%20);spike=1;
   repeat(width)@(negedge clk);
   spike=0;pulses=pulses+1;
  end
 end
 integer i;
 initial begin
  repeat(10)@(negedge clk);rst=0;
  // Includes idle-line spikes and pulses at changing phases within payloads.
  repeat(3000)@(negedge clk);
  for(i=0;i<3;i=i+1)begin
   @(negedge clk);send=1;@(negedge clk);send=0;
   // Packet admission finishes before the last UART byte leaves the pin.
   wait(!busy);repeat(6000)@(negedge clk);
  end
  if(accepted!=3 || errors!=0 || pulses<400)$fatal(1,"UART spike recovery %0d %0d %0d",accepted,errors,pulses);
  $display("PASS UART antiglitch: %0d pulses of 20..400ns, 3 CRC-valid unchanged command frames",pulses);
  $finish;
 end
 initial begin #20000000;$fatal(1,"UART antiglitch timeout");end
endmodule
