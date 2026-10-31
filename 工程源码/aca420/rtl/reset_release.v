`timescale 1ns/1ps
// Reset must come from an asynchronous hardware condition, such as PLL loss
// of lock. The optional startup hold and the three-clock release are generated
// entirely in I_clk; a POR register from another clock domain must not drive it.
module reset_release #(
    parameter integer HOLD_CYCLES = 0
)(
    input wire I_clk,
    input wire I_async_rst,
    output wire O_rst
);
(* async_reg = "true", syn_preserve = 1 *) reg [2:0] release_pipe;
generate
    if (HOLD_CYCLES == 0) begin : g_no_hold
        always @(posedge I_clk or posedge I_async_rst) begin
            if(I_async_rst) release_pipe<=3'b111;
            else release_pipe<={release_pipe[1:0],1'b0};
        end
    end else begin : g_startup_hold
        localparam integer COUNT_BITS = $clog2(HOLD_CYCLES + 1);
        reg [COUNT_BITS-1:0] hold_count;
        always @(posedge I_clk or posedge I_async_rst) begin
            if(I_async_rst) begin
                hold_count <= {COUNT_BITS{1'b0}};
                release_pipe <= 3'b111;
            end else if(hold_count < HOLD_CYCLES) begin
                hold_count <= hold_count + 1'b1;
                release_pipe <= 3'b111;
            end else begin
                release_pipe <= {release_pipe[1:0],1'b0};
            end
        end
    end
endgenerate
assign O_rst=release_pipe[2];
endmodule
