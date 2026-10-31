`timescale 1ns/1ps
// Read-only virtual card: delivers actual 24-bit bottom-up BMP sectors.
// Indexed photo samples save on-chip ROM; interpolation happens BEFORE the
// BMP byte interface. bmp_read, image_resizer and SDRAM are unchanged.
module user_bmp_card(
    input clk, input rst, output reg init_done,
    input read_req, input [31:0] read_addr,
    output reg [7:0] read_data, output reg read_valid, output reg read_end
);
localparam IDLE=0, POSITION=1, SUB_HEADER=2, ROW=3, COL=4, COLOR=5,
           FETCH=6, IDX_WAIT=7, PAL_ADDR=8, PAL_WAIT=9, SAMPLE=10,
           H0=11, H1=12, V=13, PREP=14, SEND=15, END_SECTOR=16, WAIT_REQ=17,
           H0_MUL=18,H0_ADD=19,H1_MUL=20,H1_ADD=21,V_MUL=22,V_ADD=23;
reg [4:0] state;
// 128x96 photos encoded as 64x48 2x2 tile indices. 128 RGB tile
// vectors/image preserve four independent colours per tile. Dense addressing
// saves BRAM versus the previous padded 64x48 scalar palette ROM.
reg [6:0] indices[0:24575];
reg [23:0] palettes[0:4095];
initial begin
`ifdef __ICARUS__
    $readmemh("hdl/user_bmp_indices.mem",indices);
    $readmemh("hdl/user_bmp_palettes.mem",palettes);
`else
    $readmemh("user_bmp_indices.mem",indices);
    $readmemh("user_bmp_palettes.mem",palettes);
`endif
end
reg [14:0] index_addr;
reg [11:0] palette_addr;
reg [6:0] index_out;
reg [23:0] palette_out;
// Single synchronous ROM ports, no reset on memory outputs (native BRAM).
always @(posedge clk) begin
    index_out<=indices[index_addr];
    palette_out<=palettes[palette_addr];
end
reg [2:0] image, address_image;
reg [13:0] address_base, sector_offset;
reg mapped;
reg [21:0] file_position, row_remainder;
reg [11:0] col_remainder, stride;
reg [9:0] x,y;
reg [15:0] width,height;
reg [31:0] pixel_bytes,file_size;
reg [8:0] byte_index;
reg [1:0] component,corner,channel;
reg [6:0] sx,sy;
reg [3:0] fx,fy;
reg [23:0] samples[0:3];
reg [23:0] rgb;
reg [7:0] prepared_byte;
reg [11:0] horizontal0,horizontal1;
reg signed [8:0] h_delta;
reg signed [13:0] h_product;
reg [7:0] h_left;
reg signed [12:0] v_delta;
reg signed [17:0] v_product;
reg [11:0] v_upper;
wire signed [13:0] h_sum=$signed({2'b0,h_left,4'b0})+h_product;
wire signed [17:0] v_sum=$signed({2'b0,v_upper,4'b0})+v_product;
reg [7:0] a,b,c,d;
reg [6:0] fetch_x,fetch_y;
always @(*) begin
    if(read_addr<3201) begin address_image=0;address_base=2048;end
    else if(read_addr<4354) begin address_image=1;address_base=3201;end
    else if(read_addr<5507) begin address_image=2;address_base=4354;end
    else if(read_addr<6660) begin address_image=3;address_base=5507;end
    else if(read_addr<7813) begin address_image=4;address_base=6660;end
    else if(read_addr<8966) begin address_image=5;address_base=7813;end
    else if(read_addr<9255) begin address_image=6;address_base=8966;end
    else begin address_image=7;address_base=9255;end
    fetch_x=(corner[0] && sx<127) ? sx+1'b1 : sx;
    fetch_y=(corner[1] && sy<95) ? sy+1'b1 : sy;
    case(channel)
        0: begin a=samples[0][7:0];b=samples[1][7:0];c=samples[2][7:0];d=samples[3][7:0];end
        1: begin a=samples[0][15:8];b=samples[1][15:8];c=samples[2][15:8];d=samples[3][15:8];end
        default: begin a=samples[0][23:16];b=samples[1][23:16];c=samples[2][23:16];d=samples[3][23:16];end
    endcase
end
function [7:0] header_byte;
    input [5:0] position;
    begin
        case(position)
            0:header_byte=8'h42;1:header_byte=8'h4d;
            2:header_byte=file_size[7:0];3:header_byte=file_size[15:8];
            4:header_byte=file_size[23:16];5:header_byte=file_size[31:24];
            10:header_byte=54;14:header_byte=40;
            18:header_byte=width[7:0];19:header_byte=width[15:8];
            22:header_byte=height[7:0];23:header_byte=height[15:8];
            26:header_byte=1;28:header_byte=24;
            34:header_byte=pixel_bytes[7:0];35:header_byte=pixel_bytes[15:8];
            36:header_byte=pixel_bytes[23:16];37:header_byte=pixel_bytes[31:24];
            default:header_byte=0;
        endcase
    end
endfunction
integer j;
always @(posedge clk or posedge rst) begin
    if(rst) begin
        init_done<=0;read_valid<=0;read_end<=0;read_data<=0;state<=IDLE;
        image<=0;mapped<=0;sector_offset<=0;file_position<=0;row_remainder<=0;
        col_remainder<=0;x<=0;y<=0;byte_index<=0;component<=0;corner<=0;channel<=0;
        sx<=0;sy<=0;fx<=0;fy<=0;rgb<=0;prepared_byte<=0;index_addr<=0;palette_addr<=0;
        horizontal0<=0;horizontal1<=0;
        h_delta<=0;h_product<=0;h_left<=0;v_delta<=0;v_product<=0;v_upper<=0;
        width<=512;height<=384;stride<=1536;pixel_bytes<=589824;file_size<=589878;
        for(j=0;j<4;j=j+1)samples[j]<=0;
    end else begin
        init_done<=1;read_valid<=0;read_end<=0;
        case(state)
            IDLE: if(init_done && read_req) begin
                image<=address_image;mapped<=read_addr>=2048 && read_addr<13864;
                sector_offset<=read_addr[13:0]-address_base;
                x<=0;component<=0;byte_index<=0;state<=POSITION;
            end
            POSITION: begin
                file_position<=mapped ? {sector_offset[12:0],9'd0} : 22'd0;
                if(image==6) begin
                    width<=256;height<=192;stride<=768;pixel_bytes<=147456;file_size<=147510;y<=191;
                end else if(image==7) begin
                    width<=1024;height<=768;stride<=3072;pixel_bytes<=2359296;file_size<=2359350;y<=767;
                end else begin
                    width<=512;height<=384;stride<=1536;pixel_bytes<=589824;file_size<=589878;y<=383;
                end
                state<=SUB_HEADER;
            end
            SUB_HEADER: begin row_remainder<=file_position>=54 ? file_position-22'd54 : 22'd0;state<=ROW;end
            ROW: if(row_remainder>=stride && y!=0) begin row_remainder<=row_remainder-stride;y<=y-1'b1;end
                 else begin col_remainder<=row_remainder[11:0];state<=COL;end
            COL: if(col_remainder>=3 && x<width-1) begin col_remainder<=col_remainder-12'd3;x<=x+1'b1;end
                 else begin component<=col_remainder[1:0];state<=COLOR;end
            COLOR: begin
                corner<=0;channel<=0;
                if(image==6) begin sx<=x[7:1];sy<=y[7:1];fx<={x[0],3'b0};fy<={y[0],3'b0};end
                else if(image==7) begin sx<=x[9:3];sy<=y[9:3];fx<={x[2:0],1'b0};fy<={y[2:0],1'b0};end
                else begin sx<=x[8:2];sy<=y[8:2];fx<={x[1:0],2'b0};fy<={y[1:0],2'b0};end
                state<=(!mapped || file_position<54 || file_position>=file_size) ? PREP : FETCH;
            end
            FETCH: begin
                index_addr<=({image,11'd0}+{image,10'd0})+{fetch_y[6:1],6'd0}+fetch_x[6:1];
                state<=IDX_WAIT;
            end
            IDX_WAIT: state<=PAL_ADDR;
            PAL_ADDR: begin palette_addr<={image,index_out,fetch_y[0],fetch_x[0]};state<=PAL_WAIT;end
            PAL_WAIT: state<=SAMPLE;
            SAMPLE: begin
                samples[corner]<=palette_out;
                if(corner==3)state<=H0;
                else begin corner<=corner+1'b1;state<=FETCH;end
            end
            // Split subtract, multiply and accumulate into independent clocks
            // so the 100 MHz path never spans an adder and a DSP multiplier.
            H0: begin h_left<=a;h_delta<=$signed({1'b0,b})-$signed({1'b0,a});state<=H0_MUL;end
            H0_MUL: begin h_product<=h_delta*$signed({1'b0,fx});state<=H0_ADD;end
            H0_ADD: begin horizontal0<=h_sum[11:0];state<=H1;end
            H1: begin h_left<=c;h_delta<=$signed({1'b0,d})-$signed({1'b0,c});state<=H1_MUL;end
            H1_MUL: begin h_product<=h_delta*$signed({1'b0,fx});state<=H1_ADD;end
            H1_ADD: begin horizontal1<=h_sum[11:0];state<=V;end
            V: begin
                v_upper<=horizontal0;
                v_delta<=$signed({1'b0,horizontal1})-$signed({1'b0,horizontal0});
                state<=V_MUL;
            end
            V_MUL: begin v_product<=v_delta*$signed({1'b0,fy});state<=V_ADD;end
            V_ADD: begin
                case(channel)
                    0:rgb[7:0]<=v_sum[15:8];
                    1:rgb[15:8]<=v_sum[15:8];
                    2:rgb[23:16]<=v_sum[15:8];
                endcase
                if(channel==2)state<=PREP;
                else begin channel<=channel+1'b1;state<=H0;end
            end
            PREP: begin
                if(!mapped || file_position>=file_size)prepared_byte<=0;
                else if(file_position<54)prepared_byte<=header_byte(file_position[5:0]);
                else case(component)
                    0:prepared_byte<=rgb[7:0];1:prepared_byte<=rgb[15:8];2:prepared_byte<=rgb[23:16];
                endcase
                state<=SEND;
            end
            SEND: begin
                read_valid<=1;read_data<=prepared_byte;file_position<=file_position+1'b1;
                if(mapped && file_position>=54 && file_position<file_size) begin
                    if(component==2) begin
                        component<=0;
                        if(x==width-1)begin x<=0;y<=y-1'b1;end else x<=x+1'b1;
                    end else component<=component+1'b1;
                end
                if(byte_index==511)state<=END_SECTOR;
                else begin
                    byte_index<=byte_index+1'b1;
                    state<=(file_position>=54 && file_position<file_size-1 && component!=2) ? PREP : COLOR;
                end
            end
            END_SECTOR: begin read_end<=1;state<=WAIT_REQ;end
            WAIT_REQ: if(!read_req)state<=IDLE;
            default:state<=IDLE;
        endcase
    end
end
endmodule
