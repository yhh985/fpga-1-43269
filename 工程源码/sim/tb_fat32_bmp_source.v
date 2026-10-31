`timescale 1ns/1ps
module tb_fat32_bmp_source;
reg clk=0,rst=1,card_ready=0,request=0;
reg [31:0] address=0;
wire mounted,error,valid,done,nreq;wire [3:0] files;wire [7:0] data;wire [31:0] naddr;
reg nvalid=0,nend=0;reg [7:0] ndata=0;
reg [31:0] lbas[0:31];reg [7:0] sectors[0:16383];reg [7:0] expected[0:4095];
integer active=0,hold_req=0,byte_index=0,slot=0,cases=0,i,j,k,n,rc,f,ticks,checks=0,reads=0;
string names[0:3],base,filename;
always #5 clk=~clk;
fat32_bmp_source dut(.clk(clk),.rst(rst),.native_init_done(card_ready),.init_done(mounted),.fs_error(error),
 .file_count(files),.read_req(request),.read_addr(address),.read_data(data),.read_valid(valid),.read_end(done),
 .native_req(nreq),.native_addr(naddr),.native_data(ndata),.native_valid(nvalid),.native_end(nend));
// CRC-verified native sector interface model; real SPI is verified separately.
always @(negedge clk)begin
 nvalid=0;nend=0;
 if(rst||!card_ready)begin active=0;hold_req=0;end
 else if(active)begin
  if(byte_index<512)begin ndata=sectors[slot*512+byte_index];nvalid=1;byte_index=byte_index+1;end
  else begin nend=1;active=0;hold_req=1;end
 end else if(hold_req)begin if(!nreq)hold_req=0;end
 else if(nreq)begin
  slot=-1;for(k=0;k<32;k=k+1)if(lbas[k]===naddr)slot=k;
  if(slot<0)$fatal(1,"read outside sparse FAT fixture lba=%0d",naddr);
  active=1;byte_index=0;reads=reads+1;
 end
end
task wait_mount;begin ticks=0;while(!mounted&&!error&&ticks<20000)begin @(posedge clk);#1;ticks=ticks+1;end
 if(!mounted||files!==3||error)$fatal(1,"mount files=%0d err=%b state=%0d",files,error,dut.state);end endtask
task sector;
 input integer file_no,offset,virtual_lba;
 begin
  for(n=0;n<4096;n=n+1)expected[n]=0;
  if(file_no>=0)begin filename={base,$sformatf("_file%0d.bmp",file_no+1)};f=$fopen(filename,"rb");rc=$fread(expected,f);$fclose(f);end
  @(posedge clk);#1;address=virtual_lba;request=1;j=0;ticks=0;
  while(!done&&ticks<10000)begin
   @(posedge clk);#1;ticks=ticks+1;
   if(valid)begin if(j>=512||data!==expected[offset*512+j])$fatal(1,"FAT bytes case=%0d file=%0d sector=%0d byte=%0d got=%h want=%h",cases,file_no,offset,j,data,expected[offset*512+j]);j=j+1;end
  end
  if(j!=512||!done||error)$fatal(1,"FAT read completion bytes=%0d err=%b",j,error);
  repeat(4)begin @(posedge clk);#1;if(valid||done)$fatal(1,"held request replay");end
  request=0;repeat(3)@(posedge clk);checks=checks+512;
 end
endtask
initial begin
 names[0]="mbr";names[1]="super";names[2]="active";names[3]="bad_chain";
 for(cases=0;cases<4;cases=cases+1)begin
  @(posedge clk);#1;rst=1;card_ready=0;request=0;
  for(i=0;i<32;i=i+1)lbas[i]=32'hffffffff;
  base={"verification/legacy_fixtures/sd_main_fat32_quality_20261007/verification/",names[cases]};
  $readmemh({base,"_lbas.mem"},lbas);$readmemh({base,"_sectors.mem"},sectors);
  repeat(4)@(posedge clk);#1;rst=0;card_ready=1;wait_mount;
  if(cases<3)begin
   sector(-1,0,2047);
   sector(-1,0,32'h00010800);sector(-1,0,32'hffffffff); // high-address aliases must stay unmapped
   for(i=0;i<5;i=i+1)sector(0,i,2048+i);
   for(i=0;i<4;i=i+1)sector(1,i,2053+i);
   sector(2,0,2057);sector(-1,0,2058);
   // Rewind must restart the fragmented cluster walk; stale cache is unsafe.
   sector(0,4,2052);sector(0,0,2048);sector(0,2,2050);
   card_ready=0;repeat(4)@(posedge clk);#1;if(mounted||valid||done)$fatal(1,"card loss not canceled");
   card_ready=1;wait_mount;sector(2,0,2057);
  end else begin
   @(posedge clk);#1;address=2050;request=1;
   ticks=0;while(!error&&ticks<5000)begin @(posedge clk);#1;ticks=ticks+1;if(valid||done)$fatal(1,"bad cluster released payload");end
   if(!error||mounted)$fatal(1,"bad FAT chain not bounded");
  end
 end
 $display("PASS FAT32 source: %0d exact bytes, %0d native sector transactions; fragmented files/root, MBR/superfloppy, active FAT1, cache rewind, held request, card loss/remount, bad cluster",checks,reads);$finish;
end
initial begin #3000000;$fatal(1,"FAT timeout");end
endmodule
