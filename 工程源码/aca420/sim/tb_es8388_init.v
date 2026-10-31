`timescale 1ns/1ps
module tb_es8388_init;
    reg clk=0,rst_n=0;
    always #10 clk=~clk;
    wire scl,done,error;
    tri1 sda;
    reg slave_low=0;
    assign sda=slave_low ? 1'b0:1'bz;
    wire [5:0] index;
    aca_es8388_init #(.STARTUP_CYCLES(50),.SETTLE_CYCLES(2000),.WATCHDOG_CYCLES(40000)) dut (
        .clk(clk),.rst_n(rst_n),.scl(scl),.sda(sda),.done(done),.error(error),.reg_index(index));
    reg transaction=0,ack_phase=0;
    integer bits=0,byte_index=0,transactions=0,nack_mode=0,nacks=0;
    reg [7:0] incoming=0,reg_address=0,reg_value=0;
    reg [15:0] golden[0:42];
    integer expected=0;
    time power_stop=0;
    reg nack_this=0;
    always @(negedge sda) if(rst_n && scl) begin
        transaction=1; bits=0; byte_index=0; ack_phase=0; incoming=0;
    end
    always @(posedge scl) if(rst_n && transaction) begin
        if(ack_phase) begin
            ack_phase=0;bits=0;byte_index=byte_index+1;
        end else begin
            incoming={incoming[6:0],sda}; bits=bits+1;
            if(bits==8) begin
                if(byte_index==0 && incoming!=8'h20) $fatal(1,"ACA420 codec address %h",incoming);
                if(byte_index==1) reg_address=incoming;
                if(byte_index==2) reg_value=incoming;
            end
        end
    end
    always @(negedge scl) if(rst_n && transaction) begin
        if(bits==8 && !ack_phase) begin
            nack_this=(nack_mode==2) || (nack_mode==1 && byte_index==2 && expected==5 && nacks==0);
            if(nack_this) nacks=nacks+1;
            slave_low=!nack_this;ack_phase=1;
        end else slave_low=0;
    end
    always @(posedge sda) if(rst_n && scl && transaction) begin
        transaction=0;slave_low=0;
        if(byte_index!=3) $fatal(1,"transaction contained %0d bytes",byte_index);
        transactions=transactions+1;
        if(nack_mode!=2 && !nack_this) begin
            if({reg_address,reg_value}!==golden[expected])
                $fatal(1,"register %0d got %h/%h expected %h",expected,reg_address,reg_value,golden[expected]);
            if(expected==31) power_stop=$time;
            if(expected==32 && $time-power_stop<40000) $fatal(1,"power settle delay absent");
            expected=expected+1;
        end
    end
    task restart;
        input integer mode;
        begin
            @(negedge clk);rst_n=0;slave_low=0;transaction=0;
            #200;transactions=0;expected=0;nacks=0;nack_mode=mode;
            rst_n=1;
        end
    endtask
    initial begin
        golden[0]=16'h0080;golden[1]=16'h0016;golden[2]=16'h0158;
        golden[3]=16'h0150;golden[4]=16'h02f3;golden[5]=16'h02f0;
        golden[6]=16'h2b80;golden[7]=16'h0036;golden[8]=16'h0800;
        golden[9]=16'h0309;golden[10]=16'h0400;golden[11]=16'h0d02;
        golden[12]=16'h1802;golden[13]=16'h0500;golden[14]=16'h06c3;
        golden[15]=16'h0a00;golden[16]=16'h0b02;golden[17]=16'h0c0c;
        golden[18]=16'h1718;golden[19]=16'h1000;golden[20]=16'h1100;
        golden[21]=16'h1a00;golden[22]=16'h1b00;golden[23]=16'h0900;
        golden[24]=16'h1211;golden[25]=16'h13c0;golden[26]=16'h1432;
        golden[27]=16'h1506;golden[28]=16'h16c3;golden[29]=16'h27b8;
        golden[30]=16'h2ab8;golden[31]=16'h0200;golden[32]=16'h2e1e;
        golden[33]=16'h2f1e;golden[34]=16'h301e;golden[35]=16'h311e;
        golden[36]=16'h0436;golden[37]=16'h2600;golden[38]=16'h0309;
        golden[39]=16'h2e1e;golden[40]=16'h2f1e;golden[41]=16'h301e;golden[42]=16'h311e;
        #1;rst_n=0;#100;rst_n=1;
        wait(done || error);#100;
        if(error || expected!=43 || transactions!=43) $fatal(1,"normal init incomplete %0d/%0d",expected,transactions);
        restart(1);wait(done || error);#100;
        if(error || expected!=43 || transactions!=44) $fatal(1,"data NACK retry failed %0d/%0d",expected,transactions);
        restart(2);wait(done || error);#100;
        if(!error || done || transactions!=4) $fatal(1,"permanent NACK was not bounded %0d",transactions);
        $display("PASS ES8388: 43 register transactions, post-power delay, data-byte NACK retry, bounded failure/restart");
        $finish;
    end
    initial begin #50000000;$fatal(1,"ES8388 timeout");end
endmodule
