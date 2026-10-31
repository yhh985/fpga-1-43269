`timescale 1ns/1ps
// Read-only FAT32 root-directory BMP source. Exposes contiguous VIRTUAL
// sectors to the existing BMP parser; read_addr[31] selects WAV sectors; physical file clusters may be fragmented.
// Parses CRC-verified metadata; parameterized file records use synchronous RAM.
// Independent implementation of FAT32 BPB/directory/cluster-chain conventions.
module fat32_bmp_source #(
    parameter integer MAX_FILES=8, ROOT_CLUSTER_LIMIT=128,
    parameter [31:0] VIRTUAL_BASE=2048,
    parameter [31:0] MAX_FILE_BYTES=3145782,
    parameter integer FILE_INDEX_BITS=(MAX_FILES>1 ? $clog2(MAX_FILES) : 1),
    parameter integer FILE_COUNT_BITS=$clog2(MAX_FILES+1)
)(
    input clk,rst,native_init_done,
    output reg init_done, output reg fs_error,
    output reg [FILE_COUNT_BITS-1:0] file_count,
    output [31:0] last_sector,
    output reg wav_found, output reg [31:0] wav_bytes,
    input [2:0] track_index,output reg [3:0] track_count,
    output [2:0] active_track,
    input read_req, input [31:0] read_addr,
    output reg [7:0] read_data, output reg read_valid,read_end,
    output reg native_req, output reg [31:0] native_addr,
    input [7:0] native_data, input native_valid,native_end
);
localparam WAIT_CARD=0,REQUEST=1,RECEIVE=2,BOOT_DECIDE=3,LAYOUT=4,
    CAPACITY=5,ROOT_START=6,DIR_DONE=7,FAT_DONE=8,READY=9,LOOKUP=10,
    FILE_CLUSTER=11,DATA_START=12,DATA_RECEIVE=13,ZERO=14,END_READ=15,
    WAIT_RELEASE=16,FAILED=17,ADDR_SUB=18,ADDR_SHIFT=19,ADDR_ADD=20,ADDR_CHECK=21,LOOKUP_FETCH=22,
    CAPACITY_COUNT=23,CAPACITY_CHECK=24,LAYOUT_DATA=25,LAYOUT_CHECK=26,LOOKUP_CHECK=27,WAV_CHECK=28,FILE_PREP=29,FILE_SELECT=30,FILE_TEST=31,FILE_FAT_ADDR=32,ADDR_COMMIT=33,LAYOUT_WAIT=34,FILE_CACHE_CHECK=35;
localparam META_BOOT=0,META_DIR=1,META_FAT_ROOT=2,META_FAT_FILE=3;
localparam BASE_BITS=$clog2(VIRTUAL_BASE+MAX_FILES*((MAX_FILE_BYTES+511)/512)+1);
localparam RECORD_BITS=28+BASE_BITS+13;
localparam ROOT_STEP_BITS=$clog2(ROOT_CLUSTER_LIMIT+1);
reg [5:0] state;
reg ordinal_equal,ordinal_bad;
reg [1:0] meta_kind;
reg [9:0] count;
// Byte counting is independent of the scheduling priority. In RECEIVE the
// tenth bit alone means >=512; the state machine still rejects long sectors.
wire clear_count=state==REQUEST ||
 (state==LOOKUP_CHECK && lookup_index>=file_count) ||
 (state==WAV_CHECK && !wav_request_valid) ||
 (state==ADDR_COMMIT && physical_valid && address_is_file);
wire step_count=(state==RECEIVE && native_valid && !count[9]) ||
 (state==DATA_RECEIVE && native_valid) || (state==ZERO && count!=10'd511);
always @(posedge clk or posedge rst)begin
 if(rst)count<=0;
 else if(native_init_done)begin
  if(clear_count)count<=0;
  else if(step_count)count<=count+1'b1;
 end
end
reg [31:0] volume_lba,partition_lba,partition_size;
reg partition_found,partition_type_ok,boot_is_partition;
reg [31:0] mbr_lba,mbr_size;
reg [15:0] reserved_sectors,ext_flags;
reg [1:0] bytes_per_sector,root_entries,fat16_size; // byte validation flags
reg signature0,signature1;
reg [7:0] sectors_per_cluster,fat_count;
reg [7:0] cluster_last_sector;
// BPB fields settle hundreds of clocks before directory/file addressing.
// Register the cluster mask once instead of subtracting on dispatch paths.
always @(posedge clk)cluster_last_sector<=sectors_per_cluster-8'd1;
reg [31:0] total_sectors,fat_size,root_cluster;
reg [3:0] cluster_shift;
reg [31:0] fat_lba,data_lba,volume_end,data_sectors,max_cluster;
reg [31:0] cluster_count;
reg [32:0] reserved_end,layout_end_r,layout_data_r;
reg [BASE_BITS:0] lookup_difference;
reg [31:0] root_current;
reg [ROOT_STEP_BITS-1:0] root_steps;
reg [7:0] root_sector;
reg dir_end;
reg entry_first,ext0,ext1,ext2;
reg wav0,wav1,wav2;
reg [27:0] wav_cluster,wav_cached_cluster;
reg [59:0] tracks[0:7];
reg [2:0] track_loaded;
assign active_track=track_loaded;
wire [2:0] track_select=(^track_index === 1'bx) ? 3'd0 : track_index;
reg [16:0] wav_cached_ordinal;
reg wav_cached_valid,selected_audio; // valid first byte and case-insensitive extension flags
reg [7:0] entry_attr;
reg [31:0] entry_cluster,entry_size;
reg [BASE_BITS-1:0] virtual_next;
// Power-of-two depth and unconditional synchronous read match the TD BRAM
// template. LOOKUP_CHECK rejects the end sentinel before using its contents.
(* ram_style="bram" *) reg [RECORD_BITS-1:0] file_records[0:(1<<FILE_INDEX_BITS)-1];
reg [RECORD_BITS-1:0] record_out;
reg [27:0] first_selected,cached_cluster;
reg [12:0] cached_ordinal;
reg [FILE_INDEX_BITS-1:0] cached_file;
reg cached_valid;
reg use_wav_cache,use_image_cache;
reg [FILE_INDEX_BITS-1:0] selected_file;
reg [FILE_COUNT_BITS-1:0] lookup_index; // also represents the end-of-list sentinel
reg [BASE_BITS-1:0] request_latched;
reg request_high;
reg [31:0] current_cluster;
reg [16:0] relative_sector;
reg [16:0] target_ordinal,current_ordinal;
reg [17:0] wav_sector_count;
reg wav_request_valid;
reg [7:0] sector_in_cluster;
reg [8:0] fat_offset;
reg [31:0] fat_value;
wire [31:0] next_cluster={4'd0,fat_value[27:0]};
wire [32:0] fat_span=(fat_count==2)?({1'b0,fat_size}<<1):{1'b0,fat_size};
wire [32:0] layout_end={1'b0,volume_lba}+{1'b0,total_sectors};
// One shared, pipelined physical-address calculator for directory and files.
// Full 35-bit shift prevents overflow from wrapping a malformed cluster LBA.
reg physical_valid;
reg boot_valid,layout_valid;
reg address_is_file;
reg [31:0] address_cluster;
reg [7:0] address_sector;
reg [27:0] address_minus_two;
reg [34:0] address_offset;
reg [35:0] physical_address;
reg valid_cluster,next_eoc,next_same_root,next_same_file;
reg address_cluster_ok,entry_cluster_ok,root_chain_bad;
reg image_low16_min,wav_low16_min,image_low16_limit,size_low16_zero;
always @(posedge clk)begin
 valid_cluster<=next_cluster>=2 && next_cluster<=max_cluster && next_cluster<32'h0ffffff0;
 next_eoc<=next_cluster>=32'h0ffffff8;
 next_same_root<=next_cluster==root_current;next_same_file<=next_cluster==current_cluster;
 address_cluster_ok<=address_cluster>=2 && address_cluster<=max_cluster && address_cluster<32'h0ffffff0;
 entry_cluster_ok<=entry_cluster>=2 && entry_cluster<=max_cluster && entry_cluster<32'h0ffffff0;
 root_chain_bad<=root_steps>=ROOT_CLUSTER_LIMIT-1 || (root_current>>7)>=fat_size;
 // Size bytes 28/29 are complete two byte clocks before directory commit at
 // byte31. Byte30's high octet and byte31's input remain in the final check.
 image_low16_min<=entry_size[15:0]>=16'd54;
 wav_low16_min<=entry_size[15:0]>=16'd44;
 image_low16_limit<=entry_size[15:0]<=MAX_FILE_BYTES[15:0];
 size_low16_zero<=entry_size[15:0]==0;
end
integer k;
assign last_sector=virtual_next-1'b1;
wire directory_match=state==RECEIVE && meta_kind==META_DIR && native_valid && count<512 && count[4:0]==31 &&
 !dir_end && entry_first && !(entry_attr&8'h18) &&
 ext0 && ext1 && ext2 && entry_cluster_ok &&
 ((|native_data) || (|entry_size[23:16]) || image_low16_min) &&
 ({native_data,entry_size[23:16]}<MAX_FILE_BYTES[31:16] ||
  ({native_data,entry_size[23:16]}==MAX_FILE_BYTES[31:16] && image_low16_limit)) && file_count<MAX_FILES;
wire directory_wav=state==RECEIVE && meta_kind==META_DIR && native_valid && count<512 && count[4:0]==31 &&
 !dir_end && entry_first && !(entry_attr&8'h18) && wav0 && wav1 && wav2 && track_count<8 &&
 entry_cluster_ok &&
 ((|native_data) || (|entry_size[23:16]) || wav_low16_min) &&
 (native_data<8'd4 || (native_data==8'd4 && entry_size[23:16]==0 && size_low16_zero));
wire [12:0] directory_sectors=({native_data,entry_size[23:0]}>>9)+(|entry_size[8:0]);
always @(posedge clk)begin
 boot_valid<=signature0 && signature1 && bytes_per_sector==3 && reserved_sectors!=0 &&
       root_entries==3 && fat16_size==3 && fat_size!=0 && root_cluster>=2 && root_cluster<32'h0ffffff0 &&
       (fat_count==1 || fat_count==2) && sectors_per_cluster!=0 && sectors_per_cluster<=128 &&
       (sectors_per_cluster&(sectors_per_cluster-1'b1))==0 &&
       (!ext_flags[7] || ext_flags[3:0]<fat_count) && (!boot_is_partition || total_sectors<=partition_size);
 layout_valid<=!layout_end_r[32]&&!layout_data_r[32]&&layout_data_r<layout_end_r;
 wav_sector_count<=wav_bytes[26:9]+(|wav_bytes[8:0]);
 if(directory_match)file_records[file_count[FILE_INDEX_BITS-1:0]]<={entry_cluster[27:0],virtual_next,directory_sectors};
 record_out<=file_records[lookup_index[FILE_INDEX_BITS-1:0]];
end
// Byte collectors do not depend on mounted/card-health fanout. A card
// loss resets the scheduler, and each new complete sector overwrites fields.
always @(posedge clk or posedge rst)begin
 if(rst)begin
  partition_type_ok<=0;mbr_lba<=0;mbr_size<=0;
  bytes_per_sector<=0;reserved_sectors<=0;root_entries<=0;fat16_size<=0;ext_flags<=0;
  sectors_per_cluster<=0;fat_count<=0;signature0<=0;signature1<=0;total_sectors<=0;
  fat_size<=0;root_cluster<=0;entry_first<=0;entry_attr<=0;ext0<=0;ext1<=0;ext2<=0;
  entry_cluster<=0;entry_size<=0;fat_value<=0;wav0<=0;wav1<=0;wav2<=0;
 end else if(state==RECEIVE && native_valid && count<512)begin
  if(meta_kind==META_BOOT)begin
       case(count)
        11:bytes_per_sector[0]<=native_data==0;12:bytes_per_sector[1]<=native_data==2;
        13:sectors_per_cluster<=native_data;
        14:reserved_sectors[7:0]<=native_data;15:reserved_sectors[15:8]<=native_data;
        16:fat_count<=native_data;
        17:root_entries[0]<=native_data==0;18:root_entries[1]<=native_data==0;
        22:fat16_size[0]<=native_data==0;23:fat16_size[1]<=native_data==0;
        32:total_sectors[7:0]<=native_data;33:total_sectors[15:8]<=native_data;
        34:total_sectors[23:16]<=native_data;35:total_sectors[31:24]<=native_data;
        36:fat_size[7:0]<=native_data;37:fat_size[15:8]<=native_data;
        38:fat_size[23:16]<=native_data;39:fat_size[31:24]<=native_data;
        40:ext_flags[7:0]<=native_data;41:ext_flags[15:8]<=native_data;
        44:root_cluster[7:0]<=native_data;45:root_cluster[15:8]<=native_data;
        46:root_cluster[23:16]<=native_data;47:root_cluster[31:24]<=native_data;
        510:signature0<=native_data==8'h55;511:signature1<=native_data==8'haa;
       endcase
   if(count>=446 && count<510)case((count-446)&15)
    4:partition_type_ok<=native_data==8'h0b || native_data==8'h0c;
    8:mbr_lba[7:0]<=native_data;9:mbr_lba[15:8]<=native_data;
    10:mbr_lba[23:16]<=native_data;11:mbr_lba[31:24]<=native_data;
    12:mbr_size[7:0]<=native_data;13:mbr_size[15:8]<=native_data;14:mbr_size[23:16]<=native_data;
   endcase
  end else if(meta_kind==META_DIR)begin
   case(count[4:0])
    0:entry_first<=native_data!=0 && native_data!=8'he5;
    8:begin ext0<=(native_data&8'hdf)=="B";wav0<=(native_data&8'hdf)=="W";end
    9:begin ext1<=(native_data&8'hdf)=="M";wav1<=(native_data&8'hdf)=="A";end
    10:begin ext2<=(native_data&8'hdf)=="P";wav2<=(native_data&8'hdf)=="V";end
    11:entry_attr<=native_data;
    20:entry_cluster[23:16]<=native_data;21:entry_cluster[31:24]<=native_data;
    26:entry_cluster[7:0]<=native_data;27:entry_cluster[15:8]<=native_data;
    28:entry_size[7:0]<=native_data;29:entry_size[15:8]<=native_data;30:entry_size[23:16]<=native_data;
   endcase
  end else begin
   if(count==fat_offset)fat_value[7:0]<=native_data;
   if(count==fat_offset+1)fat_value[15:8]<=native_data;
   if(count==fat_offset+2)fat_value[23:16]<=native_data;
   if(count==fat_offset+3)fat_value[31:24]<=native_data;
  end
 end
end
always @(posedge clk or posedge rst) begin
 if(rst)begin
  state<=WAIT_CARD;init_done<=0;fs_error<=0;file_count<=0;wav_found<=0;wav_bytes<=0;track_count<=0;track_loaded<=0;wav_cached_valid<=0;
  native_req<=0;native_addr<=0;read_valid<=0;read_end<=0;read_data<=0;
  volume_lba<=0;partition_lba<=0;partition_size<=0;partition_found<=0;
  boot_is_partition<=0;
  
  
  cluster_shift<=0;fat_lba<=0;data_lba<=0;volume_end<=0;
  data_sectors<=0;max_cluster<=0;root_current<=0;root_steps<=0;root_sector<=0;dir_end<=0;
  cluster_count<=0;reserved_end<=0;layout_end_r<=0;layout_data_r<=0;lookup_difference<=0;
  
  virtual_next<=VIRTUAL_BASE;selected_file<=0;lookup_index<=0;request_latched<=0;request_high<=0;
  relative_sector<=0;target_ordinal<=0;current_cluster<=0;current_ordinal<=0;
  sector_in_cluster<=0;fat_offset<=0;meta_kind<=META_BOOT;
  physical_valid<=0;address_is_file<=0;address_cluster<=0;address_sector<=0;
  address_minus_two<=0;address_offset<=0;physical_address<=0;
  ordinal_equal<=0;ordinal_bad<=0;wav_request_valid<=0;selected_audio<=0;wav_cluster<=0;wav_cached_cluster<=0;wav_cached_ordinal<=0;first_selected<=0;cached_cluster<=0;cached_ordinal<=0;cached_file<=0;cached_valid<=0;
  use_wav_cache<=0;use_image_cache<=0;
 end else if(!native_init_done)begin
  state<=WAIT_CARD;init_done<=0;fs_error<=0;file_count<=0;wav_found<=0;wav_bytes<=0;track_count<=0;track_loaded<=0;wav_cached_valid<=0;native_req<=0;read_valid<=0;read_end<=0;
  boot_is_partition<=0;partition_found<=0;volume_lba<=0;partition_lba<=0;partition_size<=0;
  virtual_next<=VIRTUAL_BASE;root_steps<=0;
  cached_valid<=0;
 end else begin
  read_valid<=0;read_end<=0;
  case(state)
   WAIT_CARD:begin meta_kind<=META_BOOT;native_addr<=0;state<=REQUEST;end
   REQUEST:begin
    native_req<=1;state<=RECEIVE;
    // Each complete boot/FAT sector overwrites every consumed field.
    // Truncated sectors fail before any field is used; no request-time clear.
    if(meta_kind==META_DIR)dir_end<=0;
   end
   RECEIVE:begin
    if(native_valid)begin
     if(count>=512)begin fs_error<=1;state<=FAILED;native_req<=0;end
     else begin
      if(meta_kind==META_BOOT)begin
       if(count>=446 && count<510 && ((count-446)&15)==15 && !partition_found &&
          partition_type_ok && mbr_lba!=0 && {native_data,mbr_size[23:0]}!=0)begin
        partition_lba<=mbr_lba;partition_size<={native_data,mbr_size[23:0]};partition_found<=1;
       end
      end else if(meta_kind==META_DIR)begin
       if(count[4:0]==0 && native_data==0)dir_end<=1;
       if(directory_match)begin virtual_next<=virtual_next+directory_sectors;file_count<=file_count+1'b1;end
       if(directory_wav)begin
        tracks[track_count[2:0]]<={entry_cluster[27:0],native_data,entry_size[23:0]};track_count<=track_count+1'b1;
        if(!wav_found)begin wav_found<=1;wav_cluster<=entry_cluster[27:0];wav_bytes<={native_data,entry_size[23:0]};end
       end
      end
     end
    end
    if(native_end)begin
     native_req<=0;
     if(count!=512 || native_valid)begin fs_error<=1;state<=FAILED;end
     else if(meta_kind==META_BOOT)state<=BOOT_DECIDE;
     else if(meta_kind==META_DIR)state<=DIR_DONE;
     else state<=FAT_DONE;
    end
   end
   BOOT_DECIDE:begin
    if(boot_valid)begin
     case(sectors_per_cluster)
      1:cluster_shift<=0;2:cluster_shift<=1;4:cluster_shift<=2;8:cluster_shift<=3;
      16:cluster_shift<=4;32:cluster_shift<=5;64:cluster_shift<=6;128:cluster_shift<=7;
     endcase
     state<=LAYOUT;
    end else if(!boot_is_partition && partition_found && signature0 && signature1)begin
     boot_is_partition<=1;volume_lba<=partition_lba;native_addr<=partition_lba;state<=REQUEST;
    end else begin fs_error<=1;state<=FAILED;end
   end
   LAYOUT:begin
    reserved_end<={1'b0,volume_lba}+reserved_sectors;layout_end_r<=layout_end;state<=LAYOUT_DATA;
   end
   LAYOUT_DATA:begin layout_data_r<=reserved_end+fat_span;state<=LAYOUT_WAIT;end
   LAYOUT_WAIT:state<=LAYOUT_CHECK;
   LAYOUT_CHECK:begin
    if(!layout_valid)begin fs_error<=1;state<=FAILED;end
    else begin
     fat_lba<=reserved_end[31:0]+((ext_flags[7] && ext_flags[3:0]==1)?fat_size:0);
     data_lba<=layout_data_r[31:0];volume_end<=layout_end_r[31:0];
     data_sectors<=layout_end_r[31:0]-layout_data_r[31:0];state<=CAPACITY;
    end
   end
   CAPACITY:begin cluster_count<=data_sectors>>cluster_shift;state<=CAPACITY_COUNT;end
   CAPACITY_COUNT:begin max_cluster<=cluster_count+1'b1;state<=CAPACITY_CHECK;end
   CAPACITY_CHECK:begin
    if(max_cluster>=32'h0ffffff0 || (max_cluster>>7)>=fat_size)begin fs_error<=1;state<=FAILED;end
    else begin
     root_current<={4'd0,root_cluster[27:0]};root_sector<=0;root_steps<=0;state<=ROOT_START;
    end
   end
   ROOT_START:begin
    address_is_file<=0;address_cluster<=root_current;address_sector<=root_sector;state<=ADDR_SUB;
   end
   DIR_DONE:begin
    if(dir_end)begin init_done<=1;state<=READY;end
    else if(root_sector<cluster_last_sector)begin root_sector<=root_sector+1'b1;state<=ROOT_START;end
    else if(root_chain_bad)begin fs_error<=1;state<=FAILED;end
    else begin
     native_addr<=fat_lba+(root_current>>7);fat_offset<={root_current[6:0],2'b00};
     meta_kind<=META_FAT_ROOT;state<=REQUEST;
    end
   end
   FAT_DONE:begin
    if(meta_kind==META_FAT_ROOT)begin
     if(next_eoc)begin init_done<=1;state<=READY;end
     else if(!valid_cluster || next_same_root)begin fs_error<=1;state<=FAILED;end
     else begin root_current<=next_cluster;root_sector<=0;root_steps<=root_steps+1'b1;state<=ROOT_START;end
    end else if(!valid_cluster || next_same_file)begin fs_error<=1;init_done<=0;state<=FAILED;end
    else begin
     current_cluster<=next_cluster;current_ordinal<=current_ordinal+1'b1;
     if(selected_audio)begin wav_cached_cluster<=next_cluster;wav_cached_ordinal<=current_ordinal+1'b1;wav_cached_valid<=1;end
     else begin cached_cluster<=next_cluster;cached_ordinal<=current_ordinal[12:0]+1'b1;cached_file<=selected_file;cached_valid<=1;end
     state<=FILE_CLUSTER;
    end
   end
   READY:if(track_select!=track_loaded && track_select<track_count)begin
    {wav_cluster,wav_bytes}<=tracks[track_select];track_loaded<=track_select;wav_cached_valid<=0;
   end else if(read_req)begin
    selected_audio<=read_addr[31];
    if(read_addr[31])begin
     wav_request_valid<=wav_found && read_addr[30:18]==0 && read_addr[17:0]<wav_sector_count;
     relative_sector<=read_addr[16:0];first_selected<=wav_cluster;state<=WAV_CHECK;
    end else begin request_latched<=read_addr;request_high<=(read_addr>>BASE_BITS)!=0;lookup_index<=0;state<=LOOKUP_FETCH;end
   end
   LOOKUP_FETCH:state<=LOOKUP;
   LOOKUP:begin lookup_difference<={1'b0,request_latched}-record_out[13+:BASE_BITS];state<=LOOKUP_CHECK;end
   LOOKUP_CHECK:begin
    if(lookup_index>=file_count)begin state<=ZERO;end
    else if(!request_high && !lookup_difference[BASE_BITS] && lookup_difference[BASE_BITS-1:0]<record_out[12:0])begin
     selected_file<=lookup_index;relative_sector<=lookup_difference[12:0];first_selected<=record_out[RECORD_BITS-1-:28];state<=FILE_PREP;
     // Separate relative-sector calculation from cluster selection.

    end else begin lookup_index<=lookup_index+1'b1;state<=LOOKUP_FETCH;end
   end
   WAV_CHECK:begin
    if(wav_request_valid)state<=FILE_PREP;
    else begin state<=ZERO;end
   end
   FILE_PREP:begin
    target_ordinal<=relative_sector>>cluster_shift;
    sector_in_cluster<=relative_sector&cluster_last_sector;
    state<=FILE_CACHE_CHECK;
   end
   FILE_CACHE_CHECK:begin
    // Compare ordinals before driving the cluster/ordinal selection mux.
    use_wav_cache<=selected_audio && wav_cached_valid && target_ordinal>=wav_cached_ordinal;
    use_image_cache<=!selected_audio && cached_valid && cached_file==selected_file && target_ordinal>=cached_ordinal;
    state<=FILE_SELECT;
   end
   FILE_SELECT:begin
    if(use_wav_cache)begin
     current_cluster<=wav_cached_cluster;current_ordinal<=wav_cached_ordinal;
    end else if(use_image_cache)begin
     current_cluster<=cached_cluster;current_ordinal<=cached_ordinal;
    end else begin current_cluster<=first_selected;current_ordinal<=0;end
    state<=FILE_CLUSTER;
   end
   FILE_CLUSTER:begin
    ordinal_equal<=current_ordinal==target_ordinal;
    ordinal_bad<=current_ordinal>target_ordinal || (current_cluster>>7)>=fat_size;
    state<=FILE_TEST;
   end
   FILE_TEST:begin
    if(ordinal_equal)state<=DATA_START;
    else if(ordinal_bad)begin fs_error<=1;init_done<=0;state<=FAILED;end
    else state<=FILE_FAT_ADDR;
   end
   FILE_FAT_ADDR:begin
    native_addr<=fat_lba+(current_cluster>>7);fat_offset<={current_cluster[6:0],2'b00};
    meta_kind<=META_FAT_FILE;state<=REQUEST;
   end
   DATA_START:begin
    address_is_file<=1;address_cluster<=current_cluster;address_sector<=sector_in_cluster;state<=ADDR_SUB;
   end
   ADDR_SUB:begin
    address_minus_two<=address_cluster[27:0]-28'd2;
    state<=ADDR_SHIFT;
   end
   ADDR_SHIFT:begin address_offset<=({7'd0,address_minus_two}<<cluster_shift)|address_sector;state<=ADDR_ADD;end
   ADDR_ADD:begin physical_address<={1'b0,address_offset}+data_lba;state<=ADDR_CHECK;end
   ADDR_CHECK:begin
    // Cluster validity has settled during SUB/SHIFT/ADD. Both checks must
    // pass before COMMIT can publish any native sector request.
    physical_valid<=address_cluster_ok && !(|physical_address[35:32]) && physical_address[31:0]<volume_end;state<=ADDR_COMMIT;
   end
   ADDR_COMMIT:begin
    if(!physical_valid)begin fs_error<=1;init_done<=0;state<=FAILED;end
    else begin
     native_addr<=physical_address[31:0];
     if(address_is_file)begin native_req<=1;state<=DATA_RECEIVE;end
     else begin meta_kind<=META_DIR;state<=REQUEST;end
    end
   end
   DATA_RECEIVE:begin
    if(native_valid)begin read_data<=native_data;read_valid<=1;end
    if(native_end)begin
     native_req<=0;
     if(count!=512 || native_valid)begin fs_error<=1;init_done<=0;state<=FAILED;end
     else state<=END_READ;
    end
   end
   ZERO:begin read_data<=0;read_valid<=1;if(count==511)state<=END_READ;end
   END_READ:begin read_end<=1;state<=WAIT_RELEASE;end
   WAIT_RELEASE:if(!read_req)state<=READY;
   FAILED:begin native_req<=0;init_done<=0;end
   default:state<=WAIT_CARD;
  endcase
 end
end
endmodule
