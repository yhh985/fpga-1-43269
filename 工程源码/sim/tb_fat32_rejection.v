`timescale 1ns/1ps
module tb_fat32_rejection;
reg clk=0,rst=1,card_ready=0,request=0,nvalid=0,nend=0;
reg [31:0] address=2048;reg [7:0] ndata=0;
wire mounted,error,valid,done,nreq;wire [3:0] files;wire [31:0] naddr;
reg [31:0] lbas[0:31];reg [7:0] sectors[0:16383],original[0:16383];
integer active=0,hold_req=0,byte_index=0,slot=0,k,i,j,cases=0,ticks=0,boot_slot,fat_slot,root_slot,second_root;
integer short_length=512;
always #5 clk=~clk;
fat32_bmp_source #(.ROOT_CLUSTER_LIMIT(4)) dut(.clk(clk),.rst(rst),.native_init_done(card_ready),
 .init_done(mounted),.fs_error(error),.file_count(files),.read_req(request),.read_addr(address),
 .read_data(),.read_valid(valid),.read_end(done),.native_req(nreq),.native_addr(naddr),
 .native_data(ndata),.native_valid(nvalid),.native_end(nend));
always @(negedge clk)begin
 nvalid=0;nend=0;
 if(rst||!card_ready)begin active=0;hold_req=0;end
 else if(active)begin
  if(byte_index<short_length)begin ndata=sectors[slot*512+byte_index];nvalid=1;byte_index=byte_index+1;end
  else begin nend=1;active=0;hold_req=1;end
 end else if(hold_req)begin if(!nreq)hold_req=0;end
 else if(nreq)begin
  slot=-1;for(k=0;k<32;k=k+1)if(lbas[k]===naddr)slot=k;
  if(slot<0)$fatal(1,"invalid metadata caused physical request lba=%0d case=%0d",naddr,cases);
  active=1;byte_index=0;
 end
end
task restore;begin
 @(posedge clk);#1;rst=1;card_ready=0;request=0;short_length=512;
 for(i=0;i<16384;i=i+1)sectors[i]=original[i];
 repeat(4)@(posedge clk);#1;
end endtask
task start_card;begin rst=0;card_ready=1;ticks=0;
 while(!error&&!mounted&&ticks<15000)begin @(posedge clk);#1;ticks=ticks+1;end end endtask
task rejection;begin
 start_card;
 if(!error||mounted||nreq)$fatal(1,"malformed FAT not rejected case=%0d state=%0d",cases,dut.state);
 repeat(5)@(posedge clk);#1;if(valid||done||mounted)$fatal(1,"error released bytes");cases=cases+1;
end endtask
initial begin
 for(i=0;i<32;i=i+1)lbas[i]=32'hffffffff;
 $readmemh("verification/legacy_fixtures/sd_main_fat32_quality_20261007/verification/mbr_lbas.mem",lbas);
 $readmemh("verification/legacy_fixtures/sd_main_fat32_quality_20261007/verification/mbr_sectors.mem",original);
 lbas[31]=3295;for(i=0;i<512;i=i+1)original[31*512+i]=0;
 for(i=0;i<32;i=i+1)begin
  if(lbas[i]==2048)boot_slot=i*512;
  if(lbas[i]==2080)fat_slot=i*512;
  if(lbas[i]==3280)root_slot=i*512;
  if(lbas[i]==3294)second_root=i*512;
 end
 restore;sectors[511]=0;rejection; // MBR signature
 restore;sectors[boot_slot+11]=0;sectors[boot_slot+12]=4;rejection; // 1024-byte sectors
 restore;sectors[boot_slot+13]=3;rejection; // non-power-of-two cluster
 restore;sectors[boot_slot+40]=8'h82;rejection; // active FAT outside count
 restore;sectors[boot_slot+39]=8'h80;rejection; // FAT multiplication overflow
 restore;sectors[boot_slot+36]=1;sectors[boot_slot+37]=0;rejection; // undersized FAT
 restore;sectors[458]=1;sectors[459]=0;sectors[460]=0;sectors[461]=0;rejection; // volume beyond partition
 restore;sectors[boot_slot+44]=1;rejection; // reserved root cluster
 restore;sectors[fat_slot+8]=2;sectors[fat_slot+9]=0;sectors[fat_slot+10]=0;sectors[fat_slot+11]=0;rejection; // self loop
 restore;
 for(i=0;i<512;i=i+1)begin sectors[second_root+i]=0;sectors[31*512+i]=0;end
 for(i=0;i<512;i=i+32)begin sectors[second_root+i]=8'he5;sectors[31*512+i]=8'he5;end
 sectors[fat_slot+36]=2;sectors[fat_slot+37]=0;sectors[fat_slot+38]=0;sectors[fat_slot+39]=0;
 rejection; // bounded multi-cluster root loop
 restore;short_length=511;rejection; // truncated native metadata sector
 restore;sectors[root_slot]=0;start_card;
 if(error||!mounted||files!=0||dut.last_sector!=2047)$fatal(1,"empty directory not mounted");cases=cases+1;
 restore;
 for(j=1;j<8;j=j+1)for(i=0;i<32;i=i+1)sectors[second_root+j*32+i]=sectors[second_root+i];
 start_card;if(error||!mounted||files!=8||dut.last_sector!=2087)$fatal(1,"eight file directory failed count=%0d",files);cases=cases+1;
 restore;start_card;short_length=511;address=2048;request=1;ticks=0;
 while(!error&&ticks<3000)begin @(posedge clk);#1;ticks=ticks+1;if(done)$fatal(1,"short data completed");end
 if(!error||mounted)$fatal(1,"short file sector not canceled");cases=cases+1;
 $display("PASS FAT32 rejection: %0d cases; malformed BPB/MBR/FAT/cluster, root cycles, short metadata/data, empty root, full 8-file root",cases);$finish;
end
initial begin #5000000;$fatal(1,"negative FAT timeout");end
endmodule
