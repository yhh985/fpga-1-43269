`timescale 1ns/1ps
// SPI byte transactions. A sector is quarantined until its CRC16 is valid.
module sd_card_cmd #(
    parameter integer CMD_TIMEOUT_BYTES = 64,
    parameter integer READ_TIMEOUT_BYTES = 200000,
    parameter integer WRITE_TIMEOUT_BYTES = 400000,
    parameter integer READ_RELEASE_CYCLES = 32,
    parameter integer RESOURCE_OPTIMIZED = 0
)(
    input sys_clk, input rst,
    input [15:0] spi_clk_div,
    input cmd_req, output cmd_req_ack, output reg cmd_req_error,
    input [47:0] cmd,
    input [7:0] cmd_r1, // retained for source compatibility; controller judges R1
    input [15:0] cmd_data_len,
    output reg [7:0] cmd_response_r1,
    output reg [31:0] cmd_response_data,
    input block_read_req,
    output reg block_read_valid, output reg [7:0] block_read_data,
    output block_read_req_ack,
    output reg block_read_error, output reg [3:0] block_read_error_code,
    input block_write_req, input [7:0] block_write_data,
    output block_write_data_rd, output block_write_req_ack,
    output reg block_write_error,
    output nCS_ctrl, output reg [15:0] clk_div,
    output reg spi_wr_req, input spi_wr_ack,
    output [7:0] spi_data_in, input [7:0] spi_data_out
);
localparam S_BOOT=0, S_IDLE=1, S_CMD_PRE=2, S_CMD_SEND=3,
           S_R1=4, S_EXTRA=5, S_CMD_ACK=6,
           S_TOKEN=7, S_READ=8, S_CRC_HI=9, S_CRC_LO=10,
           S_RELEASE=11, S_READ_ACK=12,
           S_WRITE_TOKEN=13, S_WRITE_GET=14, S_WRITE_DATA=15,
           S_WRITE_CRC_HI=16, S_WRITE_CRC_LO=17,
           S_WRITE_RESPONSE=18, S_WRITE_BUSY=19, S_WRITE_ACK=20;
reg [4:0] state;
reg cs_reg;
reg [7:0] send_data;
reg [47:0] command_latched;
reg [15:0] extra_length;
reg [9:0] byte_count;
// Registered phase enables keep terminal-count decoding off the counter CE.
reg spi_count_phase, release_count_phase;
localparam WAIT_MAX_A = CMD_TIMEOUT_BYTES > READ_TIMEOUT_BYTES ? CMD_TIMEOUT_BYTES : READ_TIMEOUT_BYTES;
localparam WAIT_MAX = WAIT_MAX_A > WRITE_TIMEOUT_BYTES ? WAIT_MAX_A : WRITE_TIMEOUT_BYTES;
localparam WAIT_BITS = RESOURCE_OPTIMIZED ? (WAIT_MAX < 2 ? 1 : $clog2(WAIT_MAX)) : 32;
localparam RELEASE_BITS = RESOURCE_OPTIMIZED ? (READ_RELEASE_CYCLES < 2 ? 1 : $clog2(READ_RELEASE_CYCLES)) : 32;
reg [WAIT_BITS-1:0] wait_count;
reg command_timeout,read_timeout,write_timeout;
// The count changes only on byte ACKs. The next SPI byte takes many clocks,
// so threshold flags settle before the next ACK uses them.
always @(posedge sys_clk or posedge rst)begin
 if(rst)begin command_timeout<=0;read_timeout<=0;write_timeout<=0;end
 else begin
  command_timeout<=wait_count>=CMD_TIMEOUT_BYTES-1;
  read_timeout<=wait_count>=READ_TIMEOUT_BYTES-1;
  write_timeout<=wait_count>=WRITE_TIMEOUT_BYTES-1;
 end
end
reg [15:0] crc16;
reg [7:0] received_crc_hi;
reg [RELEASE_BITS-1:0] release_count;
wire [7:0] sector_byte;
generate if (RESOURCE_OPTIMIZED) begin : g_sector_bram
    // CRC completion prefetches byte zero. Each release prefetches the next
    // byte, including at one cycle/byte. RAM contents need no reset: a sector
    // is exposed only after all 512 bytes and both CRC bytes have arrived.
    (* ram_style="bram" *) reg [7:0] sector_data [0:511];
    reg [7:0] prefetched;
    wire [8:0] read_address = state == S_CRC_LO ? 9'd0 :
        (state == S_RELEASE && release_count == 0) ? byte_count[8:0]+9'd1 : byte_count[8:0];
    always @(posedge sys_clk) begin
        if (!rst && state == S_READ && spi_wr_ack)
            sector_data[byte_count[8:0]] <= spi_data_out;
        prefetched <= sector_data[read_address];
    end
    assign sector_byte = prefetched;
end else begin : g_sector_legacy
    reg [7:0] sector_data [0:511];
    always @(posedge sys_clk) begin
        if (!rst && state == S_READ && spi_wr_ack)
            sector_data[byte_count[8:0]] <= spi_data_out;
    end
    assign sector_byte = sector_data[byte_count[8:0]];
end endgenerate
assign nCS_ctrl = cs_reg;
assign spi_data_in = send_data;
assign cmd_req_ack = (state == S_CMD_ACK);
assign block_read_req_ack = (state == S_READ_ACK);
assign block_write_req_ack = (state == S_WRITE_ACK);
assign block_write_data_rd = (state == S_WRITE_GET);

function [15:0] crc16_byte;
    input [15:0] previous;
    input [7:0] value;
    reg [15:0] result;
    integer bit_index;
    begin
        result = previous;
        for (bit_index=7; bit_index>=0; bit_index=bit_index-1)
            if (result[15] ^ value[bit_index])
                result = {result[14:0],1'b0} ^ 16'h1021;
            else result = {result[14:0],1'b0};
        crc16_byte = result;
    end
endfunction

always @(posedge sys_clk or posedge rst) begin
    if (rst) begin
        state <= S_BOOT; cs_reg <= 1'b1; clk_div <= 16'd248;
        spi_wr_req <= 1'b0; send_data <= 8'hff;
        command_latched <= 48'd0; extra_length <= 16'd0;
        byte_count <= 10'd0; wait_count <= 32'd0;
        spi_count_phase <= 1'b1; release_count_phase <= 1'b0;
        crc16 <= 16'd0; received_crc_hi <= 8'd0; release_count <= 32'd0;
        cmd_req_error <= 1'b0; cmd_response_r1 <= 8'hff;
        cmd_response_data <= 32'd0;
        block_read_valid <= 1'b0; block_read_data <= 8'd0;
        block_read_error <= 1'b0; block_read_error_code <= 4'd0;
        block_write_error <= 1'b0;
    end else begin
        block_read_valid <= 1'b0;
        // The final byte also increments; the next transaction clears its count.
        if ((spi_count_phase && spi_wr_ack) ||
            (release_count_phase && release_count == 0))
            byte_count <= byte_count + 10'd1;
        case (state)
            S_BOOT: begin
                clk_div <= spi_clk_div; cs_reg <= 1'b1;
                if (spi_wr_ack) begin
                    spi_wr_req <= 1'b0;
                    if (byte_count == 10'd10) begin
                        spi_count_phase <= 1'b0; state <= S_IDLE;
                    end
                end else begin spi_wr_req <= 1'b1; send_data <= 8'hff; end
            end
            S_IDLE: begin
                spi_wr_req <= 1'b0;
                spi_count_phase <= 1'b0; release_count_phase <= 1'b0;
                clk_div <= spi_clk_div;
                byte_count <= 10'd0; wait_count <= 32'd0;
                if (cmd_req) begin
                    command_latched <= cmd; extra_length <= cmd_data_len;
                    cmd_req_error <= 1'b0; cmd_response_r1 <= 8'hff;
                    cmd_response_data <= 32'd0; state <= S_CMD_PRE;
                end else if (block_read_req) begin
                    block_read_error <= 1'b0; block_read_error_code <= 4'd0;
                    crc16 <= 16'd0; state <= S_TOKEN;
                end else if (block_write_req) begin
                    block_write_error <= 1'b0; crc16 <= 16'd0;
                    state <= S_WRITE_TOKEN;
                end
            end
            S_CMD_PRE: begin
                cs_reg <= 1'b1;
                if (spi_wr_ack) begin
                    spi_wr_req <= 1'b0; byte_count <= 10'd0;
                    spi_count_phase <= 1'b1;
                    state <= S_CMD_SEND;
                end else begin spi_wr_req <= 1'b1; send_data <= 8'hff; end
            end
            S_CMD_SEND: begin
                cs_reg <= 1'b0;
                // MISO is not a response while the six command bytes are sent.
                if (spi_wr_ack) begin
                    spi_wr_req <= 1'b0;
                    if (byte_count == 10'd5) begin
                        spi_count_phase <= 1'b0;
                        wait_count <= 32'd0; state <= S_R1;
                    end
                end else begin
                    spi_wr_req <= 1'b1;
                    case (byte_count)
                        0: send_data <= command_latched[47:40] | 8'h40;
                        1: send_data <= command_latched[39:32];
                        2: send_data <= command_latched[31:24];
                        3: send_data <= command_latched[23:16];
                        4: send_data <= command_latched[15:8];
                        default: send_data <= command_latched[7:0];
                    endcase
                end
            end
            S_R1: begin
                if (spi_wr_ack) begin
                    spi_wr_req <= 1'b0;
                    if (!spi_data_out[7]) begin
                        cmd_response_r1 <= spi_data_out;
                        byte_count <= 10'd0;
                        // Illegal CMD8 has only R1, not the four R7 bytes.
                        if (extra_length != 0 && spi_data_out[6:1] == 0) begin
                            spi_count_phase <= 1'b1;
                            state <= S_EXTRA;
                        end else state <= S_CMD_ACK;
                    end else if (command_timeout) begin
                        cmd_req_error <= 1'b1; state <= S_CMD_ACK;
                    end else wait_count <= wait_count + 32'd1;
                end else begin spi_wr_req <= 1'b1; send_data <= 8'hff; end
            end
            S_EXTRA: begin
                if (spi_wr_ack) begin
                    spi_wr_req <= 1'b0;
                    cmd_response_data <= {cmd_response_data[23:0],spi_data_out};
                    if (byte_count == extra_length-1) begin
                        spi_count_phase <= 1'b0; state <= S_CMD_ACK;
                    end
                end else begin spi_wr_req <= 1'b1; send_data <= 8'hff; end
            end
            S_CMD_ACK: state <= S_IDLE;
            S_TOKEN: begin
                if (spi_wr_ack) begin
                    spi_wr_req <= 1'b0;
                    if (spi_data_out == 8'hfe) begin
                        spi_count_phase <= 1'b1;
                        byte_count <= 10'd0; state <= S_READ;
                    end else if (spi_data_out != 8'hff) begin
                        block_read_error <= 1'b1; block_read_error_code <= 4'd7;
                        state <= S_READ_ACK; cs_reg <= 1'b1;
                    end else if (read_timeout) begin
                        block_read_error <= 1'b1; block_read_error_code <= 4'd6;
                        state <= S_READ_ACK; cs_reg <= 1'b1;
                    end else wait_count <= wait_count + 32'd1;
                end else begin spi_wr_req <= 1'b1; send_data <= 8'hff; end
            end
            S_READ: begin
                if (spi_wr_ack) begin
                    spi_wr_req <= 1'b0;
                    crc16 <= crc16_byte(crc16,spi_data_out);
                    if (byte_count == 10'd511) begin
                        spi_count_phase <= 1'b0; state <= S_CRC_HI;
                    end
                end else begin spi_wr_req <= 1'b1; send_data <= 8'hff; end
            end
            S_CRC_HI: begin
                if (spi_wr_ack) begin
                    spi_wr_req <= 1'b0; received_crc_hi <= spi_data_out;
                    state <= S_CRC_LO;
                end else begin spi_wr_req <= 1'b1; send_data <= 8'hff; end
            end
            S_CRC_LO: begin
                if (spi_wr_ack) begin
                    spi_wr_req <= 1'b0; cs_reg <= 1'b1;
                    if ({received_crc_hi,spi_data_out} != crc16) begin
                        block_read_error <= 1'b1; block_read_error_code <= 4'd8;
                        state <= S_READ_ACK;
                    end else begin
                        byte_count <= 10'd0; release_count <= 32'd0;
                        release_count_phase <= 1'b1;
                        state <= S_RELEASE;
                    end
                end else begin spi_wr_req <= 1'b1; send_data <= 8'hff; end
            end
            S_RELEASE: begin
                if (release_count == 0) begin
                    block_read_data <= sector_byte;
                    block_read_valid <= 1'b1;
                    release_count <= READ_RELEASE_CYCLES-1;
                    if (byte_count == 10'd511) begin
                        release_count_phase <= 1'b0; state <= S_READ_ACK;
                    end else begin
                        byte_count <= byte_count + 10'd1;
                    end
                end else begin
                    block_read_valid <= 1'b0;
                    release_count <= release_count - 32'd1;
                end
            end
            S_READ_ACK: state <= S_IDLE;
            S_WRITE_TOKEN: begin
                if (spi_wr_ack) begin
                    spi_wr_req <= 1'b0; byte_count <= 10'd0;
                    state <= S_WRITE_GET;
                end else begin spi_wr_req <= 1'b1; send_data <= 8'hfe; end
            end
            S_WRITE_GET: begin
                spi_count_phase <= 1'b1; state <= S_WRITE_DATA;
            end
            S_WRITE_DATA: begin
                if (spi_wr_ack) begin
                    spi_count_phase <= 1'b0;
                    spi_wr_req <= 1'b0; crc16 <= crc16_byte(crc16,send_data);
                    if (byte_count == 10'd511) state <= S_WRITE_CRC_HI;
                    else state <= S_WRITE_GET;
                end else begin spi_wr_req <= 1'b1; send_data <= block_write_data; end
            end
            S_WRITE_CRC_HI: begin
                if (spi_wr_ack) begin spi_wr_req <= 1'b0; state <= S_WRITE_CRC_LO; end
                else begin spi_wr_req <= 1'b1; send_data <= crc16[15:8]; end
            end
            S_WRITE_CRC_LO: begin
                if (spi_wr_ack) begin
                    spi_wr_req <= 1'b0; wait_count <= 32'd0; state <= S_WRITE_RESPONSE;
                end else begin spi_wr_req <= 1'b1; send_data <= crc16[7:0]; end
            end
            S_WRITE_RESPONSE: begin
                if (spi_wr_ack) begin
                    spi_wr_req <= 1'b0;
                    if (spi_data_out[4:0] == 5'b00101) begin
                        wait_count <= 32'd0; state <= S_WRITE_BUSY;
                    end else if (spi_data_out != 8'hff || command_timeout) begin
                        block_write_error <= 1'b1; cs_reg <= 1'b1; state <= S_WRITE_ACK;
                    end else wait_count <= wait_count + 32'd1;
                end else begin spi_wr_req <= 1'b1; send_data <= 8'hff; end
            end
            S_WRITE_BUSY: begin
                if (spi_wr_ack) begin
                    spi_wr_req <= 1'b0;
                    if (spi_data_out == 8'hff) begin cs_reg <= 1'b1; state <= S_WRITE_ACK; end
                    else if (write_timeout) begin
                        block_write_error <= 1'b1; cs_reg <= 1'b1; state <= S_WRITE_ACK;
                    end else wait_count <= wait_count + 32'd1;
                end else begin spi_wr_req <= 1'b1; send_data <= 8'hff; end
            end
            S_WRITE_ACK: state <= S_IDLE;
            default: begin
                spi_count_phase <= 1'b1; release_count_phase <= 1'b0;
                state <= S_BOOT;
            end
        endcase
    end
end
endmodule
