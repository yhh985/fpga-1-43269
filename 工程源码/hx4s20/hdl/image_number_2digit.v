`timescale 1ns/1ps
// Only the committed source image number is shown; no frame displays 00.
module image_number_2digit #(
    parameter integer INDEX_BITS=7
)(
    input clk, rst,
    input [INDEX_BITS-1:0] image_index,
    input display_valid,
    output [6:0] seg_tens, seg_ones
);
(* async_reg="true" *) reg [INDEX_BITS-1:0] index_sync0,index_sync1;
(* async_reg="true" *) reg [1:0] valid_sync;
reg [6:0] number;
reg [7:0] digits;
`include "decimal_two_digits.vh"
always @(posedge clk or posedge rst) begin
    if(rst)begin index_sync0<=0;index_sync1<=0;valid_sync<=0;number<=0;digits<=0;end
    else begin
        index_sync0<=image_index;index_sync1<=index_sync0;
        valid_sync<={valid_sync[0],display_valid};
        number<=valid_sync[1] ? index_sync1+1'b1 : 7'd0;
        digits<=decimal_two_digits(number);
    end
end
seg_decoder u_tens(.bin_data(digits[7:4]),.seg_data(seg_tens));
seg_decoder u_ones(.bin_data(digits[3:0]),.seg_data(seg_ones));
endmodule
