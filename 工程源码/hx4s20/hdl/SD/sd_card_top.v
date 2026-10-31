
module sd_card_top
#(
	parameter  SPI_LOW_SPEED_DIV = 248,         // SD card low speed mode frequency division parameter,spi clk speed = clk speed /((SPI_LOW_SPEED_DIV + 2) * 2 )
	parameter  SPI_HIGH_SPEED_DIV = 6,          // 100 MHz / (2 * (6 + 2)) = 6.25 MHz; conservative SD-compatible rate
    parameter integer POWER_UP_CYCLES = 1000000,
    parameter integer INIT_RETRY_CYCLES = 1000000,
    parameter integer RECOVERY_DELAY_CYCLES = 50000000,
    parameter integer CMD0_MAX_ATTEMPTS = 32,
    parameter integer ACMD41_MAX_ATTEMPTS = 200,
    parameter integer CMD_TIMEOUT_BYTES = 64,
    parameter integer READ_TIMEOUT_BYTES = 200000,
    parameter integer WRITE_TIMEOUT_BYTES = 400000,
    parameter integer READ_RELEASE_CYCLES = 32,
    parameter integer READ_MAX_RETRIES = 0,
    parameter integer READ_RETRY_CYCLES = 10000,
    parameter integer RESOURCE_OPTIMIZED = 0
)
(
	input            clk,
	input            rst,
	output           SD_nCS,                    //SD card chip select (SPI mode)
	output           SD_DCLK,                   //SD card clock
	output           SD_MOSI,                   //SD card controller data output
	input            SD_MISO,                   //SD card controller data input
	output           sd_init_done,              //SD card initialization is complete
	output           sd_error_event,            // command timeout/bad response, clk-domain event
    output [3:0]     sd_error_code,
    output [5:0]     sd_last_cmd,
    output [7:0]     sd_last_r1,
	input            sd_sec_read,               //SD card sector read
	input[31:0]      sd_sec_read_addr,          //SD card sector read address
	output[7:0]      sd_sec_read_data,          //SD card sector read data
	output           sd_sec_read_data_valid,    //SD card sector read data valid
	output           sd_sec_read_end,           //SD card sector read end
	input            sd_sec_write,              //SD card sector write
	input[31:0]      sd_sec_write_addr,         //SD card sector write address
	input[7:0]       sd_sec_write_data,         //SD card sector write data
	output           sd_sec_write_data_req,     //SD card sector write data next clock is valid
	output           sd_sec_write_end           //SD card sector write end
);
wire[15:0]           spi_clk_div;               //SPI module clock division parameter
wire                 cmd_req;                   //SD card command request
wire                 cmd_req_ack;               //SD card command request response
wire                 cmd_req_error;             //SD card command request error
wire                 protocol_reset;
wire                 engine_reset = rst | protocol_reset;
wire [7:0]           cmd_response_r1;
wire [31:0]          cmd_response_data;
wire                 block_read_error;
wire [3:0]           block_read_error_code;
wire                 block_write_error;
wire[47:0]           cmd;                       //SD card command
wire[7:0]            cmd_r1;                    //SD card expect response
wire[15:0]           cmd_data_len;              //SD card command read data length
wire                 block_read_req;            //SD card sector data read request
wire                 block_read_valid;          //SD card sector data read data valid
wire[7:0]            block_read_data;           //SD card sector data read data
wire                 block_read_req_ack;        //SD card sector data read response
wire                 block_write_req;           //SD card sector data write request
wire[7:0]            block_write_data;          //SD card sector data write data next clock is valid
wire                 block_write_data_rd;       //SD card sector data write data
wire                 block_write_req_ack;       //SD card sector data write response

wire                 nCS_ctrl;                  //SPI module chip select control
wire                 spi_wr_req;                //SPI module data sending request
wire                 spi_wr_ack;                //SPI module data request response
wire[7:0]            spi_data_in;               //SPI module send data
wire[7:0]            spi_data_out;              //SPI module data returned
wire[15:0]           clk_div;
sd_card_sec_read_write
#(
	.SPI_LOW_SPEED_DIV(SPI_LOW_SPEED_DIV),
	.SPI_HIGH_SPEED_DIV(SPI_HIGH_SPEED_DIV),
    .POWER_UP_CYCLES(POWER_UP_CYCLES),
    .INIT_RETRY_CYCLES(INIT_RETRY_CYCLES),
    .RECOVERY_DELAY_CYCLES(RECOVERY_DELAY_CYCLES),
    .CMD0_MAX_ATTEMPTS(CMD0_MAX_ATTEMPTS),
    .ACMD41_MAX_ATTEMPTS(ACMD41_MAX_ATTEMPTS),
    .READ_MAX_RETRIES(READ_MAX_RETRIES),
    .READ_RETRY_CYCLES(READ_RETRY_CYCLES)
)
sd_card_sec_read_write_m0(
	.clk                            (clk                    ),
	.rst                            (rst                    ),
	.sd_init_done                   (sd_init_done           ),
	.sd_sec_read                    (sd_sec_read            ),
	.sd_sec_read_addr               (sd_sec_read_addr       ),
	.sd_sec_read_data               (sd_sec_read_data       ),
	.sd_sec_read_data_valid         (sd_sec_read_data_valid ),
	.sd_sec_read_end                (sd_sec_read_end        ),
	.sd_sec_write                   (sd_sec_write           ),
	.sd_sec_write_addr              (sd_sec_write_addr      ),
	.sd_sec_write_data              (sd_sec_write_data      ),
	.sd_sec_write_data_req          (sd_sec_write_data_req  ),
	.sd_sec_write_end               (sd_sec_write_end       ),
	.spi_clk_div                    (spi_clk_div            ),
	.cmd_req                        (cmd_req                ),
	.cmd_req_ack                    (cmd_req_ack            ),
	.cmd_req_error                  (cmd_req_error          ),
    .cmd_response_r1                (cmd_response_r1        ),
    .cmd_response_data              (cmd_response_data      ),
    .protocol_reset                 (protocol_reset         ),
    .sd_error_event                 (sd_error_event         ),
    .sd_error_code                  (sd_error_code          ),
    .sd_last_cmd                    (sd_last_cmd            ),
    .sd_last_r1                     (sd_last_r1             ),
	.cmd                            (cmd                    ),
	.cmd_r1                         (cmd_r1                 ),
	.cmd_data_len                   (cmd_data_len           ),
	.block_read_req                 (block_read_req         ),
	.block_read_valid               (block_read_valid       ),
	.block_read_data                (block_read_data        ),
	.block_read_req_ack             (block_read_req_ack     ),
    .block_read_error               (block_read_error       ),
    .block_read_error_code          (block_read_error_code  ),
	.block_write_req                (block_write_req        ),
	.block_write_data               (block_write_data       ),
	.block_write_data_rd            (block_write_data_rd    ),
	.block_write_req_ack            (block_write_req_ack    ),
    .block_write_error              (block_write_error      )
);

sd_card_cmd #(
    .CMD_TIMEOUT_BYTES(CMD_TIMEOUT_BYTES),
    .READ_TIMEOUT_BYTES(READ_TIMEOUT_BYTES),
    .WRITE_TIMEOUT_BYTES(WRITE_TIMEOUT_BYTES),
    .READ_RELEASE_CYCLES(READ_RELEASE_CYCLES),
    .RESOURCE_OPTIMIZED(RESOURCE_OPTIMIZED)
) sd_card_cmd_m0(
	.sys_clk                        (clk                    ),
	.rst                            (engine_reset           ),
	.spi_clk_div                    (spi_clk_div            ),
	.cmd_req                        (cmd_req                ),
	.cmd_req_ack                    (cmd_req_ack            ),
	.cmd_req_error                  (cmd_req_error          ),
	.cmd                            (cmd                    ),
	.cmd_r1                         (cmd_r1                 ),
	.cmd_data_len                   (cmd_data_len           ),
    .cmd_response_r1                (cmd_response_r1        ),
    .cmd_response_data              (cmd_response_data      ),
	.block_read_req                 (block_read_req         ),
	.block_read_req_ack             (block_read_req_ack     ),
	.block_read_data                (block_read_data        ),
	.block_read_valid               (block_read_valid       ),
    .block_read_error               (block_read_error       ),
    .block_read_error_code          (block_read_error_code  ),
	.block_write_req                (block_write_req        ),
	.block_write_data               (block_write_data       ),
	.block_write_data_rd            (block_write_data_rd    ),
	.block_write_req_ack            (block_write_req_ack    ),
    .block_write_error              (block_write_error      ),
	.nCS_ctrl                       (nCS_ctrl               ),
	.clk_div                        (clk_div                ),
	.spi_wr_req                     (spi_wr_req             ),
	.spi_wr_ack                     (spi_wr_ack             ),
	.spi_data_in                    (spi_data_in            ),
	.spi_data_out                   (spi_data_out           )

);

spi_master spi_master_m0(
	.sys_clk                        (clk                    ),
	.rst                            (engine_reset           ),
	.nCS                            (SD_nCS                 ),
	.DCLK                           (SD_DCLK                ),
	.MOSI                           (SD_MOSI                ),
	.MISO                           (SD_MISO                ),
	.clk_div                        (clk_div                ),
	// SD cards use SPI mode 0 (CPOL=0, CPHA=0). Mode 3 can appear to
	// work with some cards but shifts command/response bits on others.
	.CPOL                           (1'b0                   ),
	.CPHA                           (1'b0                   ),
	.nCS_ctrl                       (nCS_ctrl               ),
	.wr_req                         (spi_wr_req             ),
	.wr_ack                         (spi_wr_ack             ),
	.data_in                        (spi_data_in            ),
	.data_out                       (spi_data_out           )
);
endmodule
