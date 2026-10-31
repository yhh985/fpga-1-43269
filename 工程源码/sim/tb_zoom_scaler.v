`timescale 1ns/1ps
module tb_zoom_scaler;
parameter DW=32,DH=24,IDENTITY_ONLY=0,FIT=1,QUICK=0,REVIEW=0;
reg [1:0] zoom=1;integer z,case_id;
reg clk=0,rst=1,req=0,valid=0,sink=0;
reg [15:0] w=1,h=1;reg [31:0] in_data=0;
wire ack,ready,oreq,ovalid,busy,done;wire [31:0] data;
integer cycle=0,sent=0,received=0,tests=0,checks=0,k,sx,sy,fx,fy,xx,yy,ch;
integer a,b,c,d,hh0,hh1,vv,expected_component;
integer fw,fh,lpad,bpad,vw,vh,xskip,yskip,aw,ah;
reg [23:0] expected;
reg held=0;reg [31:0] held_data;
reg source_accepted=0;
reg checking=0,allow_source=0,out_ack=1;
integer frame_number=0;
reg [15:0] randbits=16'hace1;
always #5 clk=~clk;
image_resizer_sd_quality #(.DST_W(DW),.DST_H(DH),.FIT_ASPECT(FIT)) dut(.clk(clk),.rst(rst),.src_w(w),.src_h(h),.zoom_level(zoom),
 .in_write_req(req),.in_write_req_ack(ack),.in_wr_en(valid),.in_data(in_data),.in_ready(ready),
 .out_write_req(oreq),.out_write_req_ack(out_ack),.out_ready(sink),.out_wr_en(ovalid),
 .out_data(data),.out_busy(busy),.out_done(done));
function [23:0] pixel;input integer x,y;reg [7:0] r,g,b;begin
 r=(x*17+y*31)&255;g=(x*3+y*13)&255;b=(x*11+y*7)&255;pixel={r,g,b};end endfunction
function integer component;input integer x,y,channel;reg [23:0] p;begin p=pixel(x,y);component=(p>>(channel*8))&255;end endfunction
always @(negedge clk)begin
 randbits={randbits[14:0],randbits[15]^randbits[13]^randbits[12]^randbits[10]};
 sink=!rst && cycle%59>5 && randbits[2:0]>1;
 if(rst || !allow_source)begin valid=0;in_data=0;end
 else if(!valid || source_accepted)begin
  valid=sent<w*h && randbits[4:3]!=0;
  if(valid)in_data={8'd0,pixel(sent%w,sent/w)};
 end
end
always @(posedge clk)begin
 if(rst)begin cycle=0;held=0;source_accepted=0;end
 else begin
  cycle=cycle+1;
  if(held && (!ovalid||data!==held_data))$fatal(1,"elastic output changed under backpressure");
  held=ovalid&&!sink;held_data=data;
  source_accepted=valid&&ready;
  if(source_accepted)sent=sent+1;
  if(ovalid&&sink)begin
   xx=received%DW;yy=received/DW;
   fw=DW;fh=DH;
   if(FIT)begin
    if(w*DH>=h*DW)begin fh=h*DW/w;if(fh<1)fh=1;end
    else begin fw=w*DH/h;if(fw<1)fw=1;end
   end
   case(z)
    0:begin fw=fw>1?fw/2:1;fh=fh>1?fh/2:1;end
    2:begin fw=fw+fw/2;fh=fh+fh/2;end
    3:begin fw=fw*2;fh=fh*2;end
   endcase
   vw=fw;vh=fh;aw=fw<DW?fw:DW;ah=fh<DH?fh:DH;
   lpad=(DW-aw)/2;bpad=(DH-ah)/2;
   xskip=fw>DW?(fw-DW)/2:0;yskip=fh>DH?(fh-DH)/2:0;
   sx=fw==1 ? (w-1)*128 : ((xx-lpad+xskip)*(w-1)*256)/(fw-1);
   sy=fh==1 ? (h-1)*128 : ((yy-bpad+yskip)*(h-1)*256)/(fh-1);
   fw=aw;fh=ah;
   if(xx<lpad || xx>=lpad+fw || yy<bpad || yy>=bpad+fh)begin sx=0;sy=0;end
   fx=sx%256;fy=sy%256;sx=sx/256;sy=sy/256;
   for(ch=0;ch<3;ch=ch+1)begin
    a=component(sx,sy,ch);b=component(sx<w-1?sx+1:sx,sy,ch);
    c=component(sx,sy<h-1?sy+1:sy,ch);d=component(sx<w-1?sx+1:sx,sy<h-1?sy+1:sy,ch);
    hh0=a*(256-fx)+b*fx;hh1=c*(256-fx)+d*fx;
    expected_component=(hh0*(256-fy)+hh1*fy+32768)/65536;
    expected[ch*8+:8]=expected_component;
   end
   if(xx<lpad || xx>=lpad+fw || yy<bpad || yy>=bpad+fh)expected=0;
   if(received>=DW*DH || data!=={expected,8'd0})$fatal(1,"bilinear %0dx%0d output=%0d xy=%0d,%0d got=%h want=%h fp=%0d,%0d",w,h,received,xx,yy,data,{expected,8'd0},dut.x_fp,dut.y_fp);
   received=received+1;checks=checks+1;
  end
  if(checking && done && (received!=DW*DH || sent!=w*h))$fatal(1,"completion before entire frame accepted %0d/%0d",sent,received);
 end
end
task frame;input integer ww,hh;begin
 @(posedge clk);#1;checking=0;allow_source=0;req=0;sent=0;received=0;w=ww;h=hh;
 if(!REVIEW || frame_number==0)begin rst=1;repeat(4)@(posedge clk);#1;rst=0;end
 req=1;out_ack=!REVIEW;
 if(REVIEW)begin
  wait(oreq);repeat(23)begin @(negedge clk);if(!oreq || ack || ready)$fatal(1,"frame advanced before destination ACK");end
  out_ack=1;
 end
 wait(ack);checking=1;allow_source=1;
 @(negedge clk);
 // Hold the input request past the ACK on alternate frames. Its eventual
 // release must not produce a duplicate frame. Change live zoom after ACK:
 // the in-flight frame must continue using the requested latched level.
 if(REVIEW)begin zoom=(z+2)%4;repeat(7)@(negedge clk);end
 req=0;wait(done);allow_source=0;repeat(3)@(negedge clk);checking=0;
 frame_number=frame_number+1;
 tests=tests+1;$display("VERIFIED visual zoom %0dx%0d -> %0dx%0d: %0d exact pixels",ww,hh,DW,DH,received);$fflush();
end endtask
initial begin
 if(REVIEW)begin
  for(case_id=0;case_id<16;case_id=case_id+1)begin
   z=(case_id*3)%4;zoom=z;
   case((case_id/4+case_id)%4)
    0:frame(DW,DH);1:frame(19,7);2:frame(1,17);3:frame(37,29);
   endcase
  end
 end else begin
 for(z=0;z<4;z=z+1)begin
  zoom=z;
  if(QUICK)begin frame(DW,DH);frame(7,19);end
  else begin
   frame(1,1);frame(1,7);frame(9,1);frame(7,5);frame(DW,DH);frame(33,25);
   frame(64,48);frame(1024,3);frame(3,1024);frame(1024,1024);
  end
 end
 end
 $display("PASS visual zoom scaler: %0d sizes, %0d pixels; bilinear independent oracle, exact endpoints, RGB888 identity, random source/sink stalls and final-pixel completion",tests,checks);$finish;
end
initial begin #2000000000;$fatal(1,"quality scaler timeout state=%0d sent=%0d received=%0d",dut.state,sent,received);end
endmodule
