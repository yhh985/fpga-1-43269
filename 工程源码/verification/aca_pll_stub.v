`timescale 1ns/1ps
// Behavioral PLL model only: board PLL programming is checked by TD build.
module aca_audio_pll(input refclk,reset,output reg extlock=0,
    output clk0_out,clk1_out,output reg clk2_out=0);
    always #40.666667 clk2_out=~clk2_out;
    assign clk0_out=refclk; assign clk1_out=1'b0;
    integer lock_count=0;
    always @(posedge refclk or posedge reset) begin
        if(reset) begin extlock<=0;lock_count<=0;end
        else if(lock_count==20) extlock<=1;
        else lock_count<=lock_count+1;
    end
endmodule

