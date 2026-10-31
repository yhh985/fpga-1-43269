`timescale 1ns/1ps
// One complete virtual sector at a time, including any FAT lookup. Priority
// is reconsidered only after completion and a release gap. High-water audio
// yields to pictures; low-water audio wins the next transaction.
module sd_media_arbiter(
 input clk,rst,mounted,
 input image_req,input [31:0] image_addr,
 output [7:0] image_data,output image_valid,image_end,
 input audio_req,input [31:0] audio_addr,input audio_urgent,
 output [7:0] audio_data,output audio_valid,audio_end,
 output reg fs_req,output reg [31:0] fs_addr,
 input [7:0] fs_data,input fs_valid,fs_end
);
 reg [1:0] state;
 reg owner;
 assign image_data=fs_data;assign audio_data=fs_data;
 assign image_valid=state==1&&!owner&&fs_valid;
 assign image_end=state==1&&!owner&&fs_end;
 assign audio_valid=state==1&&owner&&fs_valid;
 assign audio_end=state==1&&owner&&fs_end;
 always @(posedge clk or posedge rst)begin
  if(rst)begin state<=0;owner<=0;fs_req<=0;fs_addr<=0;end
  else if(!mounted)begin state<=0;fs_req<=0;end
  else case(state)
   0:if(audio_req&&(audio_urgent||!image_req))begin owner<=1;fs_req<=1;fs_addr<=audio_addr;state<=1;end
     else if(image_req)begin owner<=0;fs_req<=1;fs_addr<=image_addr;state<=1;end
   1:if(fs_end)begin fs_req<=0;state<=2;end
   2:state<=3;
   3:state<=0;
  endcase
 end
endmodule
