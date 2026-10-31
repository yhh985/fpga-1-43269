`timescale 1ns/1ps
// Synthesized read-only BMP source. It replaces validated SD sectors in the
// demo build; BMP parsing, scaling, FIFO backpressure and frame ownership stay real.
module demo_bmp_card #(
    parameter integer BYTE_PERIOD = 4
)(
    input clk, input rst,
    output reg init_done,
    input read_req, input [31:0] read_addr,
    output reg [7:0] read_data,
    output reg read_valid, output reg read_end
);
localparam S_IDLE=0, S_POSITION=1, S_SUB_HEADER=2, S_ROW=3, S_COL=4,
           S_COLOR=5, S_PREP=6, S_SEND=7, S_END=8, S_WAIT=9;
reg [3:0] state;
reg [2:0] image;
reg mapped;
// The largest fixture occupies 2813 sectors (<2^12) and 1440054 bytes (<2^21).
// Address decode, sector subtraction and byte-offset subtraction have separate
// registers; avoid a 32-bit compare/subtract chain on the 100 MHz path.
reg [13:0] sector_offset;
reg [20:0] file_position, row_remainder;
reg [11:0] col_remainder;
reg [9:0] x, y;
reg [1:0] component;
reg [8:0] byte_index;
reg [15:0] gap;
reg [15:0] width, height;
reg [11:0] stride;
reg [31:0] pixel_bytes, file_size;
reg [9:0] right_corner, bottom_corner;
reg [23:0] rgb;
reg [23:0] rgb_latched;
reg [7:0] prepared_byte;
always @(*) begin
    case(image)
        0: rgb=24'hff0000;
        1: rgb=24'h00ff00;
        2: rgb=24'h0000ff;
        3: case(x[9:7])
            0: rgb=24'hffffff;
            1: rgb=24'hffff00;
            2: rgb=24'h00ffff;
            3: rgb=24'h00ff00;
            default: rgb=24'hff00ff;
        endcase
        4: rgb={x[7:0],y[7:0],x[7:0]^y[7:0]};
        5: rgb=(x[5]^y[5]) ? 24'hffffff : 24'h202020;
        6: rgb=(x<160) ? ((y<120) ? 24'hff0000 : 24'h0000ff) :
                                        ((y<120) ? 24'h00ff00 : 24'hffff00);
        default: begin
            rgb={x[7:0],y[7:0],x[7:0]^y[7:0]};
            if(x[5:0]==0 || y[5:0]==0) rgb=24'hffffff;
        end
    endcase
    // Asymmetric corners expose row inversion and incorrect resize boundaries.
    if(x<16 && y<16) rgb=24'hff0000;
    else if(x>=right_corner && y<16) rgb=24'h00ff00;
    else if(x<16 && y>=bottom_corner) rgb=24'h0000ff;
    else if(x>=right_corner && y>=bottom_corner) rgb=24'hffff00;
end

function [7:0] header_byte;
    input [5:0] position;
    begin
        case(position)
            0: header_byte=8'h42;
            1: header_byte=8'h4d;
            2: header_byte=file_size[7:0];
            3: header_byte=file_size[15:8];
            4: header_byte=file_size[23:16];
            5: header_byte=file_size[31:24];
            10: header_byte=54;
            14: header_byte=40;
            18: header_byte=width[7:0];
            19: header_byte=width[15:8];
            22: header_byte=height[7:0];
            23: header_byte=height[15:8];
            26: header_byte=1;
            28: header_byte=24;
            34: header_byte=pixel_bytes[7:0];
            35: header_byte=pixel_bytes[15:8];
            36: header_byte=pixel_bytes[23:16];
            37: header_byte=pixel_bytes[31:24];
            default: header_byte=0;
        endcase
    end
endfunction
reg [2:0] address_image;
reg [13:0] address_base;
always @(*) begin
    if(read_addr<3849) begin address_image=0;address_base=2048;end
    else if(read_addr<5650) begin address_image=1;address_base=3849;end
    else if(read_addr<7451) begin address_image=2;address_base=5650;end
    else if(read_addr<9252) begin address_image=3;address_base=7451;end
    else if(read_addr<11053) begin address_image=4;address_base=9252;end
    else if(read_addr<12854) begin address_image=5;address_base=11053;end
    else if(read_addr<13305) begin address_image=6;address_base=12854;end
    else begin address_image=7;address_base=13305;end
end
always @(posedge clk or posedge rst) begin
    if(rst) begin
        init_done<=0;read_valid<=0;read_end<=0;read_data<=0;
        state<=S_IDLE;image<=0;mapped<=0;sector_offset<=0;
        file_position<=0;row_remainder<=0;col_remainder<=0;
        x<=0;y<=0;component<=0;byte_index<=0;gap<=0;
        width<=640;height<=480;stride<=1920;pixel_bytes<=921600;file_size<=921654;
        right_corner<=624;bottom_corner<=464;rgb_latched<=0;prepared_byte<=0;
    end else begin
        init_done<=1;read_valid<=0;read_end<=0;
        case(state)
            S_IDLE: if(init_done && read_req) begin
                image<=address_image;
                mapped<=read_addr>=2048 && read_addr<16118;
                sector_offset<=read_addr[13:0]-address_base;
                x<=0;component<=0;byte_index<=0;gap<=0;
                state<=S_POSITION;
            end
            S_POSITION: begin
                file_position<=mapped ? {sector_offset[11:0],9'd0} : 21'd0;
                if(image==6) begin
                    width<=320;height<=240;stride<=960;pixel_bytes<=230400;file_size<=230454;
                    right_corner<=304;bottom_corner<=224;y<=239;
                end else if(image==7) begin
                    width<=800;height<=600;stride<=2400;pixel_bytes<=1440000;file_size<=1440054;
                    right_corner<=784;bottom_corner<=584;y<=599;
                end else begin
                    width<=640;height<=480;stride<=1920;pixel_bytes<=921600;file_size<=921654;
                    right_corner<=624;bottom_corner<=464;y<=479;
                end
                state<=S_SUB_HEADER;
            end
            S_SUB_HEADER: begin
                row_remainder<=(file_position>=54) ? file_position-21'd54 : 21'd0;
                state<=S_ROW;
            end
            // Subtract iteratively once per sector instead of synthesizing
            // variable division into the 100 MHz byte/pixel path.
            S_ROW: if(row_remainder>=stride && y!=0) begin
                row_remainder<=row_remainder-stride;y<=y-1'b1;
            end else begin col_remainder<=row_remainder[11:0];state<=S_COL;end
            S_COL: if(col_remainder>=3 && x<width-1) begin
                col_remainder<=col_remainder-12'd3;x<=x+1'b1;
            end else begin component<=col_remainder[1:0];state<=S_COLOR;end
            // Separate pixel pattern logic from the BGR/header byte mux.
            // Two preparation clocks fit within the default four-clock cadence.
            S_COLOR: begin
                rgb_latched<=rgb;state<=S_PREP;
                if(gap!=0) gap<=gap-1'b1;
            end
            S_PREP: begin
                if(!mapped || file_position>=file_size) prepared_byte<=0;
                else if(file_position<54) prepared_byte<=header_byte(file_position[5:0]);
                else case(component)
                    0: prepared_byte<=rgb_latched[7:0];
                    1: prepared_byte<=rgb_latched[15:8];
                    default: prepared_byte<=rgb_latched[23:16];
                endcase
                state<=S_SEND;
                if(gap!=0) gap<=gap-1'b1;
            end
            S_SEND: if(gap==0) begin
                read_valid<=1;read_data<=prepared_byte;gap<=BYTE_PERIOD-1;
                if(mapped && file_position>=54 && file_position<file_size) begin
                    if(component==2) begin
                        component<=0;
                        if(x==width-1) begin x<=0;y<=y-1'b1;end
                        else x<=x+1'b1;
                    end else component<=component+1'b1;
                end
                file_position<=file_position+1'b1;
                if(byte_index==511) state<=S_END;
                else begin byte_index<=byte_index+1'b1;state<=S_COLOR;end
            end else gap<=gap-1'b1;
            S_END: begin read_end<=1;state<=S_WAIT;end
            S_WAIT: if(!read_req) state<=S_IDLE;
            default: state<=S_IDLE;
        endcase
    end
end
endmodule
