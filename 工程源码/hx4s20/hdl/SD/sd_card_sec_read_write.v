`timescale 1ns/1ps
module sd_card_sec_read_write #(
    parameter SPI_LOW_SPEED_DIV = 248,
    parameter SPI_HIGH_SPEED_DIV = 6,
    parameter integer POWER_UP_CYCLES = 1000000,
    parameter integer INIT_RETRY_CYCLES = 1000000,
    parameter integer RECOVERY_DELAY_CYCLES = 50000000,
    parameter integer CMD0_MAX_ATTEMPTS = 32,
    parameter integer ACMD41_MAX_ATTEMPTS = 200,
    parameter integer READ_MAX_RETRIES = 0,
    parameter integer READ_RETRY_CYCLES = 10000
)(
    input clk, input rst, (* max_fanout=32 *) output reg sd_init_done,
    input sd_sec_read, input [31:0] sd_sec_read_addr,
    output [7:0] sd_sec_read_data, output sd_sec_read_data_valid,
    output sd_sec_read_end,
    input sd_sec_write, input [31:0] sd_sec_write_addr,
    input [7:0] sd_sec_write_data, output sd_sec_write_data_req,
    output sd_sec_write_end,
    output reg [15:0] spi_clk_div,
    output reg cmd_req, input cmd_req_ack, input cmd_req_error,
    output reg [47:0] cmd, output reg [7:0] cmd_r1,
    output reg [15:0] cmd_data_len,
    input [7:0] cmd_response_r1, input [31:0] cmd_response_data,
    output reg block_read_req, input block_read_valid,
    input [7:0] block_read_data, input block_read_req_ack,
    input block_read_error, input [3:0] block_read_error_code,
    output reg block_write_req, output [7:0] block_write_data,
    input block_write_data_rd, input block_write_req_ack,
    input block_write_error,
    output reg protocol_reset,
    output reg sd_error_event,
    output reg [3:0] sd_error_code,
    output reg [5:0] sd_last_cmd,
    output reg [7:0] sd_last_r1
);
localparam S_POWER=0, S_COMMAND=1, S_INIT_WAIT=2, S_READY=3,
           S_READ=4, S_READ_END=5, S_WRITE=6, S_WRITE_END=7,
           S_RECOVER=8, S_CMD0_WAIT=9, S_READ_RETRY_WAIT=10,
           S_COMMAND_CHECK=11, S_READ_WAIT_RELEASE=12;
localparam C_CMD0=0, C_CMD8=1, C_CMD55=2, C_ACMD41=3,
           C_CMD58=4, C_CMD16=5, C_CMD17=6, C_CMD24=7;
reg [3:0] state;
reg [2:0] command_step;
localparam TIMER_MAX_A=POWER_UP_CYCLES>INIT_RETRY_CYCLES ? POWER_UP_CYCLES:INIT_RETRY_CYCLES;
localparam TIMER_MAX_B=RECOVERY_DELAY_CYCLES>READ_RETRY_CYCLES ? RECOVERY_DELAY_CYCLES:READ_RETRY_CYCLES;
localparam TIMER_MAX=TIMER_MAX_A>TIMER_MAX_B ? TIMER_MAX_A:TIMER_MAX_B;
localparam TIMER_BITS=TIMER_MAX<2 ? 1:$clog2(TIMER_MAX);
// Every timed state exits before reaching TIMER_MAX. Size this counter from
// its parameters instead of keeping unreachable upper bits in the carry.
reg [TIMER_BITS-1:0] timer;
localparam INIT_ATTEMPT_BITS=ACMD41_MAX_ATTEMPTS<2 ? 1:$clog2(ACMD41_MAX_ATTEMPTS);
localparam CMD0_ATTEMPT_BITS=CMD0_MAX_ATTEMPTS<2 ? 1:$clog2(CMD0_MAX_ATTEMPTS);
reg [INIT_ATTEMPT_BITS-1:0] init_attempts;
reg [CMD0_ATTEMPT_BITS-1:0] cmd0_attempts;
reg card_v2, block_addressed;
reg response_error,response_idle,response_zero,response_legacy;
reg response_echo_ok,response_ocr_ok,response_ccs;
// Decode the complete response at ACK, then dispatch on the registered flags.
// This also deasserts cmd_req before the transport returns to its IDLE state,
// so the extra check clock cannot cause a duplicate command transaction.
always @(posedge clk or posedge rst)begin
    if(rst)begin
        response_error<=0;response_idle<=0;response_zero<=0;response_legacy<=0;
        response_echo_ok<=0;response_ocr_ok<=0;response_ccs<=0;
    end else if(cmd_req_ack)begin
        response_error<=cmd_req_error;
        response_idle<=cmd_response_r1==8'h01;
        response_zero<=cmd_response_r1==8'h00;
        response_legacy<=cmd_response_r1==8'h05;
        response_echo_ok<=cmd_response_data==32'h000001aa;
        response_ocr_ok<=cmd_response_data[31] && (|cmd_response_data[23:15]);
        response_ccs<=cmd_response_data[30];
    end
end
localparam RETRY_BITS=READ_MAX_RETRIES<1 ? 1 : $clog2(READ_MAX_RETRIES+1);
reg [RETRY_BITS-1:0] read_retries;
// R1 bit 3 is the command CRC error bit. CMD0/CMD8 carry valid CRCs and
// must be checked; masking it here allowed a bad SPI phase to pass as valid.
assign sd_sec_read_data = block_read_data;
assign sd_sec_read_data_valid = sd_init_done && (state == S_READ) && block_read_valid;
assign sd_sec_read_end = (state == S_READ_END);
assign sd_sec_write_data_req = sd_init_done && (state == S_WRITE) && block_write_data_rd;
assign block_write_data = sd_sec_write_data;
assign sd_sec_write_end = (state == S_WRITE_END);

task issue_command;
    input [5:0] number;
    input [31:0] argument;
    input [7:0] crc;
    input [15:0] response_bytes;
    input [2:0] next_step;
    begin
        cmd <= {2'b00,number,argument,crc}; cmd_data_len <= response_bytes;
        cmd_r1 <= 8'd0; cmd_req <= 1'b1;
        protocol_reset <= 1'b0;
        command_step <= next_step; state <= S_COMMAND;
    end
endtask
task fail_transaction;
    input [3:0] error_code;
    begin
        sd_error_code <= error_code;
        sd_last_cmd <= cmd[45:40]; sd_last_r1 <= cmd_response_r1;
        sd_error_event <= 1'b1; sd_init_done <= 1'b0;
        protocol_reset <= 1'b1;
        cmd_req <= 1'b0; block_read_req <= 1'b0; block_write_req <= 1'b0;
        spi_clk_div <= SPI_LOW_SPEED_DIV;
        timer <= 32'd0; state <= S_RECOVER;
    end
endtask
task initialized;
    begin
        sd_init_done <= 1'b1; sd_error_code <= 4'd0;
        sd_last_cmd <= cmd[45:40]; sd_last_r1 <= cmd_response_r1;
        spi_clk_div <= SPI_HIGH_SPEED_DIV; state <= S_READY;
    end
endtask

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state <= S_POWER; command_step <= C_CMD0; timer <= 32'd0;
        protocol_reset <= 1'b1;
        init_attempts <= 16'd0; cmd0_attempts <= 16'd0;
        card_v2 <= 1'b0; block_addressed <= 1'b0;
        read_retries <= 0;
        sd_init_done <= 1'b0; spi_clk_div <= SPI_LOW_SPEED_DIV;
        cmd_req <= 1'b0; cmd <= 48'd0; cmd_r1 <= 8'd0; cmd_data_len <= 16'd0;
        block_read_req <= 1'b0; block_write_req <= 1'b0;
        sd_error_event <= 1'b0; sd_error_code <= 4'd0;
        sd_last_cmd <= 6'd0; sd_last_r1 <= 8'hff;
    end else begin
        sd_error_event <= 1'b0;
        case (state)
            S_POWER: begin
                if (timer >= POWER_UP_CYCLES-1) begin
                    timer <= 32'd0; issue_command(0,32'd0,8'h95,0,C_CMD0);
                end else timer <= timer + 32'd1;
            end
            S_COMMAND: if (cmd_req_ack) begin
                cmd_req <= 1'b0;
                state <= S_COMMAND_CHECK;
            end
            S_COMMAND_CHECK: begin
                if (sd_error_code == 0) begin
                    sd_last_cmd <= cmd[45:40]; sd_last_r1 <= cmd_response_r1;
                end
                if (command_step == C_CMD0 && (response_error || !response_idle)) begin
                    if (cmd0_attempts >= CMD0_MAX_ATTEMPTS-1)
                        fail_transaction(response_error ? 4'd1 : 4'd2);
                    else begin
                        cmd0_attempts <= cmd0_attempts + 16'd1;
                        timer <= 32'd0; state <= S_CMD0_WAIT;
                    end
                end else if (response_error) fail_transaction(4'd1);
                else case (command_step)
                    C_CMD0: issue_command(8,32'h000001aa,8'h87,4,C_CMD8);
                    C_CMD8: begin
                        // CMD8 is R7: reject an invalid voltage/check-pattern echo.
                        if (response_legacy) begin
                            card_v2 <= 1'b0; issue_command(55,32'd0,8'hff,0,C_CMD55);
                        end else if (!response_idle && !response_zero)
                            fail_transaction(4'd2);
                        else if (!response_echo_ok)
                            fail_transaction(4'd3);
                        else begin
                            card_v2 <= 1'b1; issue_command(55,32'd0,8'hff,0,C_CMD55);
                        end
                    end
                    C_CMD55: begin
                        if (!response_idle && !response_zero)
                            fail_transaction(4'd2);
                        else issue_command(41,card_v2 ? 32'h40000000 : 32'd0,8'hff,0,C_ACMD41);
                    end
                    C_ACMD41: begin
                        if (response_zero) begin
                            // OCR is required to distinguish SDHC (block) from
                            // SDSC (byte) addressing and to verify 3.3 V power-up.
                            issue_command(58,32'd0,8'hff,4,C_CMD58);
                        end
                        else if (!response_idle) fail_transaction(4'd2);
                        else if (init_attempts >= ACMD41_MAX_ATTEMPTS-1) fail_transaction(4'd4);
                        else begin
                            init_attempts <= init_attempts + 16'd1;
                            timer <= 32'd0; state <= S_INIT_WAIT;
                        end
                    end
                    C_CMD58: begin
                        if (!response_zero) fail_transaction(4'd2);
                        else if (!response_ocr_ok)
                            fail_transaction(4'd5);
                        else begin
                            block_addressed <= card_v2 && response_ccs;
                            if (card_v2 && response_ccs) initialized;
                            else issue_command(16,32'd512,8'hff,0,C_CMD16);
                        end
                    end
                    C_CMD16: begin
                        if (!response_zero) fail_transaction(4'd2);
                        else initialized;
                    end
                    C_CMD17: begin
                        if (!response_zero) fail_transaction(4'd2);
                        else begin block_read_req <= 1'b1; state <= S_READ; end
                    end
                    C_CMD24: begin
                        if (!response_zero) fail_transaction(4'd2);
                        else begin block_write_req <= 1'b1; state <= S_WRITE; end
                    end
                    default: fail_transaction(4'd2);
                endcase
            end
            S_INIT_WAIT: begin
                if (timer >= INIT_RETRY_CYCLES-1) begin
                    timer <= 32'd0; issue_command(55,32'd0,8'hff,0,C_CMD55);
                end else timer <= timer + 32'd1;
            end
            S_CMD0_WAIT: begin
                if (timer >= INIT_RETRY_CYCLES-1) begin
                    timer <= 32'd0; issue_command(0,32'd0,8'h95,0,C_CMD0);
                end else timer <= timer + 32'd1;
            end
            S_READY: begin
                // Keep the selected divider; never force the old 25 MHz value.
                spi_clk_div <= SPI_HIGH_SPEED_DIV;
                if (sd_sec_write || sd_sec_read) begin
                    read_retries <= 0;
                    if (!block_addressed && ((sd_sec_write ? sd_sec_write_addr : sd_sec_read_addr) > 32'h007fffff)) begin
                        // SDSC uses a 32-bit byte address. Do not silently wrap.
                        fail_transaction(4'd9);
                        sd_last_cmd <= sd_sec_write ? 6'd24 : 6'd17;
                    end else if (sd_sec_write)
                        issue_command(24,block_addressed ? sd_sec_write_addr : (sd_sec_write_addr << 9),8'hff,0,C_CMD24);
                    else issue_command(17,block_addressed ? sd_sec_read_addr : (sd_sec_read_addr << 9),8'hff,0,C_CMD17);
                end
            end
            S_READ: if (block_read_req_ack) begin
                block_read_req <= 1'b0;
                // CRC-checked receive RAM quarantines the failed sector:
                // no failed bytes have reached the BMP parser. Retry the
                // SAME latched CMD17 address, with a bounded delay/count.
                if (block_read_error && read_retries<READ_MAX_RETRIES &&
                    (block_read_error_code==6 || block_read_error_code==8))begin
                    read_retries<=read_retries+1'b1;timer<=0;state<=S_READ_RETRY_WAIT;
                end else if (block_read_error) fail_transaction(block_read_error_code);
                else begin sd_error_code <= 4'd0; state <= S_READ_END; end
            end
            // END is a one-clock completion pulse. The consumer may register
            // it before lowering sd_sec_read, so returning directly to READY
            // would launch the same CMD17 again with the previous address.
            // Re-arm only after this request has actually been released.
            S_READ_END: state <= S_READ_WAIT_RELEASE;
            S_READ_WAIT_RELEASE: if (!sd_sec_read) state <= S_READY;
            S_READ_RETRY_WAIT:begin
                if(timer>=READ_RETRY_CYCLES-1)begin
                    timer<=0;issue_command(17,cmd[39:8],8'hff,0,C_CMD17);
                end else timer<=timer+1'b1;
            end
            S_WRITE: if (block_write_req_ack) begin
                block_write_req <= 1'b0;
                if (block_write_error) fail_transaction(4'ha);
                else begin sd_error_code <= 4'd0; state <= S_WRITE_END; end
            end
            S_WRITE_END: state <= S_READY;
            S_RECOVER: begin
                if (timer >= RECOVERY_DELAY_CYCLES-1) begin
                    timer <= 32'd0; init_attempts <= 16'd0; cmd0_attempts <= 16'd0;
                    card_v2 <= 1'b0; block_addressed <= 1'b0;
                    issue_command(0,32'd0,8'h95,0,C_CMD0);
                end else timer <= timer + 32'd1;
            end
            default: fail_transaction(4'd2);
        endcase
    end
end
endmodule
