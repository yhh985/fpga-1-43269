`timescale 1ns/1ps
module tb_packet;
 reg clk=0,rst=1,rx=1;always #5 clk=~clk;
 wire tx,busy,received;wire [7:0] rt,rs;wire [255:0] rp;wire [15:0] errors;
 link_packet #(.PRESCALE(2),.RX_TIMEOUT(1000)) dut(.clk(clk),.rst(rst),.rx(rx),.tx(tx),.send(1'b0),.tx_type(8'b0),.tx_seq(8'b0),.tx_payload(256'b0),.busy(busy),.received(received),.rx_type(rt),.rx_seq(rs),.rx_payload(rp),.crc_errors(errors));
 reg [7:0] bytes[0:37];integer i,j,count=0;
 always @(posedge clk)begin #1;if(received)count=count+1;end
 task put;input [7:0] v;begin rx=0;repeat(16)@(negedge clk);for(j=0;j<8;j=j+1)begin rx=v[j];repeat(16)@(negedge clk);end rx=1;repeat(16)@(negedge clk);end endtask
 initial begin
 bytes[0]=8'ha5;
bytes[1]=8'h5a;
bytes[2]=8'h02;
bytes[3]=8'h09;
bytes[4]=8'h02;
bytes[5]=8'h00;
bytes[6]=8'h00;
bytes[7]=8'h00;
bytes[8]=8'h00;
bytes[9]=8'h00;
bytes[10]=8'h00;
bytes[11]=8'h00;
bytes[12]=8'h00;
bytes[13]=8'h00;
bytes[14]=8'h00;
bytes[15]=8'h00;
bytes[16]=8'h00;
bytes[17]=8'h00;
bytes[18]=8'h00;
bytes[19]=8'h00;
bytes[20]=8'h00;
bytes[21]=8'h00;
bytes[22]=8'h00;
bytes[23]=8'h00;
bytes[24]=8'h00;
bytes[25]=8'h00;
bytes[26]=8'h00;
bytes[27]=8'h00;
bytes[28]=8'h00;
bytes[29]=8'h00;
bytes[30]=8'h00;
bytes[31]=8'h00;
bytes[32]=8'h00;
bytes[33]=8'h00;
bytes[34]=8'h00;
bytes[35]=8'h00;
bytes[36]=8'he7;
bytes[37]=8'h90;
 repeat(10)@(negedge clk);rst=0;
 for(i=0;i<38;i=i+1)put(i==4?8'd3:bytes[i]);repeat(30)@(negedge clk);
 if(count!=0 || errors!=1)$fatal(1,"CRC accepted corrupt command");
 put(8'ha5);put(8'h5a);put(8'd2);repeat(1200)@(negedge clk);
 for(i=0;i<38;i=i+1)put(bytes[i]);repeat(30)@(negedge clk);
 if(count!=1 || rt!=2 || rs!=9 || rp!=2)$fatal(1,"recovery/valid packet");
 $display("PASS packet: independent Python CRC vector, corrupt command rejected, partial frame timeout, resynchronization");$finish;
 end
endmodule
