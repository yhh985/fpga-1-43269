`timescale 1ns/1ps
// Register sequence adapted from CoreCourse ACA420 ch33_ES8388_Loop_Back.
// See SOURCES.md. Slave address 0x10 is fixed by ACA420's grounded CE pin.
// FPGA provides MCLK/BCLK/LRCK: 16-bit I2S, 32-bit slots, MCLK/Fs=256.
module aca_es8388_init #(
    parameter integer STARTUP_CYCLES = 500000,
    parameter integer SETTLE_CYCLES = 25000000,
    parameter integer WATCHDOG_CYCLES = 5000000,
    parameter integer MAX_RETRIES = 3
)(
    input wire clk, input wire rst_n,
    output wire scl, inout wire sda,
    output reg done, output reg error,
    output reg [5:0] reg_index
);
    localparam START=0, ISSUE=1, WAIT_ACK=2, NEXT=3, SETTLE=4, FINISH=5, FAILED=6;
    reg [2:0] state;
    reg [31:0] timer;
    reg [3:0] retries;
    reg request;
    reg engine_rst_n;
    wire complete, nack;
    wire [15:0] entry;

    function [15:0] register_entry;
        input [5:0] index;
        begin
            case(index)
                0: register_entry=16'h0080;
                1: register_entry=16'h0016;
                2: register_entry=16'h0158;
                3: register_entry=16'h0150;
                4: register_entry=16'h02f3;
                5: register_entry=16'h02f0;
                6: register_entry=16'h2b80;
                7: register_entry=16'h0036;
                8: register_entry=16'h0800;
                9: register_entry=16'h0309;
               10: register_entry=16'h0400;
               11: register_entry=16'h0d02;
               12: register_entry=16'h1802;
               13: register_entry=16'h0500;
               14: register_entry=16'h06c3;
               15: register_entry=16'h0a00;
               16: register_entry=16'h0b02;
               17: register_entry=16'h0c0c;
               18: register_entry=16'h1718;
               19: register_entry=16'h1000;
               20: register_entry=16'h1100;
               21: register_entry=16'h1a00;
               22: register_entry=16'h1b00;
               23: register_entry=16'h0900; // External MAX4466 preamp: codec PGA 0 dB.
               24: register_entry=16'h1211; // ALC disabled: preserve acoustic transients.
               25: register_entry=16'h13c0;
               26: register_entry=16'h1432;
               27: register_entry=16'h1506;
               28: register_entry=16'h16c3;
               29: register_entry=16'h27b8;
               30: register_entry=16'h2ab8;
               31: register_entry=16'h0200; // Wait 500 ms after analog power-up.
               32: register_entry=16'h2e1e;
               33: register_entry=16'h2f1e;
               34: register_entry=16'h301e;
               35: register_entry=16'h311e;
               36: register_entry=16'h0436;
               37: register_entry=16'h2600;
               38: register_entry=16'h0309;
               39: register_entry=16'h2e1e;
               40: register_entry=16'h2f1e;
               41: register_entry=16'h301e;
               42: register_entry=16'h311e;
               default: register_entry=16'h0000;
            endcase
        end
    endfunction
    assign entry=register_entry(reg_index);
    aca_i2c_control #(.SCL_CLOCK(100000)) u_bus (
        .Clk(clk), .Rst_n(engine_rst_n & rst_n),
        .wrreg_req(request), .rdreg_req(1'b0),
        .addr({8'd0,entry[15:8]}), .addr_mode(1'b0),
        .wrdata(entry[7:0]), .rddata(), .device_id(8'h20),
        .RW_Done(complete), .ack(nack), .dly_cnt_max(32'd0),
        .i2c_sclk(scl), .i2c_sdat(sda)
    );
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=START; timer<=0; retries<=0; request<=0;
            engine_rst_n<=0; done<=0; error<=0; reg_index<=0;
        end else begin
            request<=0;
            case(state)
                START: begin
                    engine_rst_n<=1;
                    if(timer>=STARTUP_CYCLES-1) begin timer<=0; state<=ISSUE; end
                    else timer<=timer+1'b1;
                end
                ISSUE: begin request<=1; timer<=0; state<=WAIT_ACK; end
                WAIT_ACK: begin
                    if(complete) begin
                        timer<=0;
                        if(nack) begin
                            if(retries>=MAX_RETRIES) begin error<=1; state<=FAILED; end
                            else begin retries<=retries+1'b1; state<=ISSUE; end
                        end else begin retries<=0; state<=NEXT; end
                    end else if(timer>=WATCHDOG_CYCLES-1) begin
                        // A hung transaction is not reported as a successful init.
                        engine_rst_n<=0; error<=1; state<=FAILED;
                    end else timer<=timer+1'b1;
                end
                NEXT: begin
                    if(reg_index==42) state<=FINISH;
                    else if(reg_index==31) begin timer<=0; state<=SETTLE; end
                    else begin reg_index<=reg_index+1'b1; state<=ISSUE; end
                end
                SETTLE: begin
                    if(timer>=SETTLE_CYCLES-1) begin
                        timer<=0; reg_index<=reg_index+1'b1; state<=ISSUE;
                    end else timer<=timer+1'b1;
                end
                FINISH: done<=1;
                FAILED: done<=0;
                default: begin error<=1; state<=FAILED; end
            endcase
        end
    end
endmodule
