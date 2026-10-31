`timescale 1ns/1ps
module tb_uart_report;
    reg clk=0,rst_n=0,event_pending=0;
    always #10 clk=~clk;
    wire tx;
    reg [7:0] flags=8'h49;
    reg [15:0] count=16'h1234,peak=16'h7fff,noise=16'h000a,threshold=16'h0999,samples=16'h5678;
    aca_uart_report #(.CLOCK_HZ(50000000),.BAUD(1000000),.PERIOD_CYCLES(20000)) dut (
        .clk(clk),.rst_n(rst_n),.event_pending(event_pending),.flags(flags),
        .clap_count(count),.peak(peak),.noise(noise),.threshold(threshold),.sample_count(samples),.tx(tx));
    reg [7:0] received[0:15];
    reg [7:0] byte_value,checksum;
    integer i,j,packets=0;
    task read_byte;
        output [7:0] b;
        integer n;
        begin
            @(negedge tx); #500;
            if(tx!==0) $fatal(1,"UART start");
            for(n=0;n<8;n=n+1) begin #1000;b[n]=tx;end
            #1000;if(tx!==1) $fatal(1,"UART stop");
        end
    endtask
    initial begin
        #1;rst_n=0;#100;rst_n=1;
        for(j=0;j<3;j=j+1) begin
            for(i=0;i<16;i=i+1) begin read_byte(byte_value);received[i]=byte_value;end
            checksum=0;
            for(i=0;i<15;i=i+1) checksum=checksum^received[i];
            if(received[0]!=8'ha5 || received[1]!=8'h5a || received[2]!=1 ||
               received[3]!=j || received[15]!=checksum) $fatal(1,"UART packet framing/checksum");
            if(j==0 && {received[6],received[5]}!=16'h1234) $fatal(1,"UART little endian");
            if(j==2 && {received[6],received[5]}!=16'h1235) $fatal(1,"event during busy lost");
            packets=packets+1;
        end
        $display("PASS UART: 48 serial bytes, headers, sequence, little endian, checksum, pending event");$finish;
    end
    initial begin
        wait(dut.state==3);#1000;
        @(negedge clk);count=16'h1235;event_pending=1;
        @(negedge clk);event_pending=0;
    end
    initial begin #4000000;$fatal(1,"UART timeout");end
endmodule
