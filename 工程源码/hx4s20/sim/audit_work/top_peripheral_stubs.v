// TEST ONLY: external storage/PLL/encrypted HDMI peripherals, not a hardware model.
`include "global_def.v"
module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter integer BUILTIN_DEMO      = 0,
    parameter integer USER_BMP_TEST     = 0,
    parameter integer MAIN_SD_FEATURES  = 0, 
    parameter integer FIT_ASPECT = 0,
    parameter integer PREFETCH_NEXT = 0,
    parameter integer SPI_HIGH_SPEED_DIV = 6,
    parameter integer READ_RELEASE_CYCLES = MAIN_SD_FEATURES ? 4 : 32,
    parameter integer AUTO_INTERVAL_SECONDS = 10,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter integer SCAN_TARGET_COUNT = 8,
    parameter integer IMAGE_INDEX_BITS = (SCAN_TARGET_COUNT>1 ? $clog2(SCAN_TARGET_COUNT) : 1),
    parameter integer IMAGE_COUNT_BITS = $clog2(SCAN_TARGET_COUNT+1)
)(
    input [1:0] zoom_level,output wire [1:0] display_zoom,
    input audio_clk, music_pop,
    input music_next_toggle,music_prev_toggle,
    output [31:0] music_data,output music_valid,music_empty,
    output [12:0] music_used,output music_ok,music_error,music_found,
    output [2:0] music_track,output [3:0] music_tracks,
    input                       clk,
    input                       rst,
    input                       key_next,
    input                       audio_play_enable,
    input                       background_music_enable,
    input                       playback_pause,
    input                       auto_play_enable, 
    input                       test_mode,        
    input                       audio_next_toggle, 
    input voice_next_toggle,voice_prev_toggle,
    output [3:0]                state_code,
    output [3:0]                status_code,  
    output [3:0]                sd_error_code,
    output [5:0]                sd_last_cmd,
    output [7:0]                sd_last_r1,
    output wire                  sd_error,    
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output [15:0]               src_w,        
    output [15:0]               src_h,        
    output wire [15:0]           display_src_w,
    output wire [15:0]           display_src_h,
    output wire                  display_valid,

    input                       write_finish_toggle,
    input                       read_buffer_toggle, 
    input [1:0]                 read_buffer_index,  
    output wire [1:0]            write_buf_idx,
    output wire [1:0]            disp_buf_idx,
    output [IMAGE_INDEX_BITS-1:0] current_pic_idx, 
    output [3:0]                debug_state,
    output [3:0]                debug_rd_cnt,
    output [7:0]                debug_byte0,
    output [7:0]                debug_byte1,
    output                      debug_data_valid,

    output                      write_req,
    input                       write_req_ack,
    input                       write_data_ready, 
    output                      write_en,
    output [31:0]               write_data,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO
);
assign display_zoom = '0;
assign music_data = '0;
assign music_valid = '0;
assign music_used = '0;
assign music_ok = '0;
assign music_track = '0;
assign music_tracks = '0;
assign state_code = '0;
assign status_code = '0;
assign sd_error_code = '0;
assign sd_last_cmd = '0;
assign sd_last_r1 = '0;
assign sd_error = '0;
assign src_w = '0;
assign src_h = '0;
assign display_src_w = '0;
assign display_src_h = '0;
assign display_valid = '0;
assign write_buf_idx = '0;
assign disp_buf_idx = '0;
assign current_pic_idx = '0;
assign debug_state = '0;
assign debug_rd_cnt = '0;
assign debug_byte0 = '0;
assign debug_byte1 = '0;
assign debug_data_valid = '0;
assign write_req = '0;
assign write_en = '0;
assign write_data = '0;
assign SD_nCS = '0;
assign SD_DCLK = '0;
assign SD_MOSI = '0;
endmodule
module frame_read_write
#
(
	parameter MEM_DATA_BITS          = 32,
	parameter READ_DATA_BITS         = 32,
	parameter WRITE_DATA_BITS        = 32,
	parameter ADDR_BITS              = 21,
	parameter BURST_BITS             = 9,
	
	
	
	parameter BURST_SIZE             = 128,
	parameter WRITE_V_FLIP           = 1,      
	parameter FRAME_WIDTH            = 640,
	parameter FRAME_HEIGHT           = 480
) 
(
	input                            rst,                  
	input                            write_rst,             
	input                            mem_clk,                    
	input							 Sdr_init_done,
	input							 Sdr_init_ref_vld,
    input							 Sdr_busy,
	
    
	output							 App_rd_en,
	output[ADDR_BITS - 1:0]			 App_rd_addr,
	input							 Sdr_rd_en,					 
	input[MEM_DATA_BITS - 1:0]		 Sdr_rd_dout,
	
	input                            read_clk,                   
	input                            read_req,                   
	output                           read_req_ack,               
	output                           read_buffer_toggle,         
	output [1:0]                     read_buffer_index,
	output                           read_finish,                
	input[ADDR_BITS - 1:0]           read_addr_0,                
	input[ADDR_BITS - 1:0]           read_addr_1,                
	input[ADDR_BITS - 1:0]           read_addr_2,                
	input[ADDR_BITS - 1:0]           read_addr_3,                
	input[1:0]                       read_addr_index,            
	input[ADDR_BITS - 1:0]           read_len,                   
	input                            read_en,                    
	output[READ_DATA_BITS  - 1:0]    read_data,                  
	
	output							 App_wr_en,
	output[ADDR_BITS - 1:0]			 App_wr_addr,
	output[MEM_DATA_BITS - 1:0]	 App_wr_din,
	output[3:0]						 App_wr_dm,
	
	
	input                            write_clk,                  
	input                            write_req,                  
	output                           write_req_ack,              
	output                           write_finish,               
	input[ADDR_BITS - 1:0]           write_addr_0,               
	input[ADDR_BITS - 1:0]           write_addr_1,               
	input[ADDR_BITS - 1:0]           write_addr_2,               
	input[ADDR_BITS - 1:0]           write_addr_3,               
	input[1:0]                       write_addr_index,           
	input[ADDR_BITS - 1:0]           write_len,                  
	output                           write_data_ready,           
	input                            write_en,                   
	input[WRITE_DATA_BITS - 1:0]     write_data                 

);
assign App_rd_en = '0;
assign App_rd_addr = '0;
assign read_req_ack = '0;
assign read_buffer_toggle = '0;
assign read_buffer_index = '0;
assign read_finish = '0;
assign read_data = '0;
assign App_wr_en = '0;
assign App_wr_addr = '0;
assign App_wr_din = '0;
assign App_wr_dm = '0;
assign write_req_ack = '0;
assign write_finish = '0;
assign write_data_ready = '0;
endmodule
module sdram(
    
    input   					Clk,
    input						Clk_sft,
    input						Rst,
    
    output 						Sdr_init_done,
    output						Sdr_init_ref_vld,
    output						Sdr_busy,
    
    input						App_wr_en,
	input [`ADDR_WIDTH-1:0]		App_wr_addr,  	
	input [`DM_WIDTH-1:0]		App_wr_dm,
	input [`DATA_WIDTH-1:0]		App_wr_din,	
    
    input 						App_rd_en,
	input [`ADDR_WIDTH-1:0]		App_rd_addr,
	output 						Sdr_rd_en,
	output [`DATA_WIDTH-1:0]	Sdr_rd_dout	
    
    
    
);
assign Sdr_init_done = '0;
assign Sdr_init_ref_vld = '0;
assign Sdr_busy = '0;
assign Sdr_rd_en = '0;
assign Sdr_rd_dout = '0;
endmodule
module video_timing_data
#(
	parameter DATA_WIDTH = 16                       
)
(
	input                       video_clk,          
	input                       rst,
	output wire                  read_req,           
	input                       read_req_ack,       
	
	
	output                      hs,                 
	output                      vs,                 
	output                      de                  
	
);
assign read_req = '0;
assign hs = '0;
assign vs = '0;
assign de = '0;
endmodule
module video_delay
#(
	parameter DATA_WIDTH = 24                       
)
(
	input                       video_clk,          
	input                       rst,
	output                      read_en,            
	input[DATA_WIDTH - 1:0]     read_data,          
	input                      hs,                 
	input                      vs,                 
	input                      de,                 

	output                      hs_r,                 
	output                      vs_r,                 
	output                      de_r,                 
	output[DATA_WIDTH - 1:0]    vout_data           

);
assign read_en = '0;
assign hs_r = '0;
assign vs_r = '0;
assign de_r = '0;
assign vout_data = '0;
endmodule
module hdmi_1_4b_transmitter_core_wrapper#(
    parameter DEVICE            = "EG", 

    parameter HTOTAL            = 2200,
    parameter HSA               = 44,
    parameter HFP               = 88,
    parameter HBP               = 148,
    parameter HACTIVE           = 1920,
    parameter VTOTAL            = 1125,
    parameter VSA               = 5,
    parameter VFP               = 4,
    parameter VBP               = 36,
    parameter VACTIVE           = 1080,

    parameter VIDEO_TPG         = "Enable",
    parameter VIDEO_FORMAT      = "RGB",
    parameter VIDEO_VIC         = 16,

    parameter AUDIO_SAMPLE_RATE = "48K",

    parameter IIC_SCL_DIV       = 125
)(
    input wire       I_pixel_clk,
    input wire       I_rst,

    
    input wire       I_edid_read_trig,
    output wire      O_edid_read_valid,
    output wire[7:0] O_edid_read_data,

    
    input wire       I_axis_s_user,
    input wire       I_axis_s_valid,
    input wire       I_axis_s_last,
    input wire[23:0] I_axis_s_data,
    output wire      O_axis_s_ready,

    
    input wire       I_audio_valid,     
    input wire[23:0] I_audio_left_data, 
    input wire[23:0] I_audio_right_data,

    
    input wire       I_acr_valid,
    input wire[19:0] I_acr_cts,
    input wire[19:0] I_acr_n,

    
    output wire      O_video_locked,

    
    output wire      O_ddc_scl,
    inout wire       IO_ddc_sda,

    
    output wire[9:0] O_ch0_tmds_data,
    output wire[9:0] O_ch1_tmds_data,
    output wire[9:0] O_ch2_tmds_data,
    output wire[9:0] O_clk_tmds_data
);
assign O_edid_read_valid = '0;
assign O_edid_read_data = '0;
assign O_axis_s_ready = 1'b1;
assign O_video_locked = '0;
assign O_ddc_scl = '0;
assign O_ch0_tmds_data = '0;
assign O_ch1_tmds_data = '0;
assign O_ch2_tmds_data = '0;
assign O_clk_tmds_data = '0;
endmodule
module hdmi_phy_wrapper#(
    parameter DEVICE = "EG"
    )(
    input wire      I_pixel_clk,
    input wire      I_serial_clk,
    input wire      I_rst,

    input wire[9:0] I_tmds_channel_0,
    input wire[9:0] I_tmds_channel_1,
    input wire[9:0] I_tmds_channel_2,
    input wire[9:0] I_tmds_channel_clk,
    
    output wire     O_tmds_ch0_p,
    output wire     O_tmds_ch1_p,
    output wire     O_tmds_ch2_p,
    output wire     O_tmds_clk_p
);
assign O_tmds_ch0_p = '0;
assign O_tmds_ch1_p = '0;
assign O_tmds_ch2_p = '0;
assign O_tmds_clk_p = '0;
endmodule
module sys_pll (
  refclk,
  reset,
  clk0_out,
  clk1_out,
  clk2_out,
  extlock
);

  input refclk;
  input reset;
  output clk0_out;
assign clk0_out = 1'b0;
  output clk1_out;
assign clk1_out = 1'b0;
  output clk2_out;
assign clk2_out = 1'b0;
  output extlock;
assign extlock = 1'b1;
endmodule
module video_pll (
  refclk,
  reset,
  clk0_out,
  clk1_out,
  extlock
);

  input refclk;
  input reset;
  output clk0_out;
assign clk0_out = 1'b0;
  output clk1_out;
assign clk1_out = 1'b0;
  output extlock;
assign extlock = 1'b1;
endmodule
module PLL_HDMI_AUDIO (
  refclk,
  reset,
  extlock,
  clk0_out,
  clk1_out,
  clk2_out 
);

  input refclk;
  input reset;
  output extlock;
assign extlock = 1'b1;
  output clk0_out;
assign clk0_out = 1'b0;
  output clk1_out;
assign clk1_out = 1'b0;
  output clk2_out;
assign clk2_out = 1'b0;
endmodule

