`timescale 1ns/1ps
module tb_track_overlay;
reg clk=0,rst=1,de=1,enabled=1,online=1,music=1;
reg [2:0] track=0;reg [3:0] count=3;reg [9:0] px,py;
wire [23:0] out;reg [34:0] digits[0:8],expected_digit;reg [23:0] expected;
mic_overlay dut(.clk(clk),.rst(rst),.vs(1'b0),.de(de),.enable(enabled),.online(online),
 .music_mode(music),.music_track(track),.music_tracks(count),.fx_requested(1'b0),.fx_return_ok(1'b0),
 .status(256'd0),.rgb(24'h123456),.out_rgb(out));
always #5 clk=~clk;
integer total,index,col,row,which,n=0;
initial begin
 digits[0]=35'b01110_10001_10011_10101_11001_10001_01110;
 digits[1]=35'b00100_01100_00100_00100_00100_00100_01110;
 digits[2]=35'b01110_10001_00001_00010_00100_01000_11111;
 digits[3]=35'b11110_00001_00001_01110_00001_00001_11110;
 digits[4]=35'b00010_00110_01010_10010_11111_00010_00010;
 digits[5]=35'b11111_10000_10000_11110_00001_00001_11110;
 digits[6]=35'b01110_10000_10000_11110_10001_10001_01110;
 digits[7]=35'b11111_00001_00010_00100_01000_01000_01000;
 digits[8]=35'b01110_10001_10001_01110_10001_10001_01110;
 repeat(3)@(negedge clk);rst=0;force dut.x=px;force dut.y=py;
 for(total=0;total<=8;total=total+1)begin
  count=total;
  for(index=0;index<(total==0?1:total);index=index+1)begin
   track=index;
   for(which=0;which<2;which=which+1)begin
    expected_digit=digits[which?total:(total==0?0:index+1)];
    for(row=0;row<14;row=row+1)for(col=0;col<12;col=col+1)begin
     px=(which?112:88)+col;py=390+row;#1;expected=24'h102028;
     if(col/2<5 && expected_digit[34-(row/2)*5-col/2])expected=total<2?24'hf0b020:24'h20d0c0;
     if(out!==expected)$fatal(1,"track display %0d/%0d glyph%0d row%0d col%0d",index+1,total,which,row,col);
     n=n+1;
    end
   end
  end
 end
 enabled=0;#1;if(out!==24'h123456)$fatal(1,"OSD bypass");
 enabled=1;music=0;#1;if(out!==24'h123456)$fatal(1,"track outside music mode");
 music=1;online=0;#1;if(out!==24'h123456)$fatal(1,"offline track display");
 $display("PASS track OSD: %0d exact number pixels, 0..8 files/all indices, single-file warning, hidden outside music/online/enabled",n);$finish;
end
endmodule
