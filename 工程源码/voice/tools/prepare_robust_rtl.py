"""Create a candidate alongside experiments, leaving production untouched."""
from pathlib import Path
import hashlib,json,re
root=Path(__file__).resolve().parents[2]
source=root/'archive/before_voice_robust_20261023/aca_kws_engine.v'
s=source.read_text()
def sub(a,b):
    global s
    assert a in s,a
    s=s.replace(a,b)
sub('history[0:767]','history[0:2047]')
sub('reg [5:0] write_frame,filled;', 'reg [6:0] write_frame,filled;')
sub('reg [9:0] oldest,read_addr;', 'reg [10:0] oldest,read_addr;')
sub('wire signed [7:0] input_q=layer?hidden_q:\n   (ENDPOINT_MODE && ISOLATE_UTTERANCE && input_count<first_valid_input)?8\'sd0:history_q;',
'''// Three whole-utterance time scales; six trailing quiet frames are zero.
 reg [6:0] utterance_start,normalized_start,speech_frames;
 wire [5:0] pad_frames=pass_index==0?6'd4:pass_index==1?6'd2:6'd0;
 wire normalized_valid=input_count[9:4]>=pad_frames && input_count[9:4]<42;
 wire signed [7:0] input_q=layer?hidden_q:!normalized_valid?8'sd0:history_q;
 // Precompute floor(j*length/target) by accumulation and repeated subtraction.
 // This removes division/multiplication from the 50 MHz history address path.
 reg [6:0] frame_map[0:47];
 reg [5:0] map_index;
 reg [6:0] map_offset;
 reg [7:0] map_phase;
 wire [5:0] target_frames=pass_index==0?6'd38:pass_index==1?6'd40:6'd42;
 wire [9:0] next_count=input_count+10'd1;
 wire [10:0] next_mapped_addr={frame_map[next_count[9:4]],next_count[3:0]};''')
start=s.index(' wire [5:0] next_oldest=')
end=s.index(' // TD infers ERAM',start)
s=s[:start]+s[end:]
sub('quiet_run<=0;utterance_allowed<=0;','quiet_run<=0;utterance_allowed<=0;\n   utterance_start<=0;normalized_start<=0;speech_frames<=0;\n   map_index<=0;map_offset<=0;map_phase<=0;')
sub('if(!utterance)utterance_allowed<=quiet_run>=PREQUIET_FRAMES;',
    'if(!utterance)begin utterance_allowed<=quiet_run>=PREQUIET_FRAMES;utterance_start<=write_frame;end')
sub('utterance_frames>=64','utterance_frames>=96')
sub('utterance_frames<64','utterance_frames<96')
sub("write_frame<=write_frame==47?0:write_frame+1'b1;", "write_frame<=write_frame+1'b1;")
sub("if(filled<48)filled<=filled+1'b1;", "if(filled<127)filled<=filled+1'b1;")
a=s.index('      // Evaluate three adjacent endpoint alignments')
b=s.index('      pass_index<=0;',a)
s=s[:a]+'''      // Capture complete speech (up to 90 frames), not the last 48 only.
      normalized_start<=utterance_start;speech_frames<=utterance_frames-7'd5;
      read_addr<={utterance_start,4'b0};
      map_index<=0;map_offset<=0;map_phase<=0;
'''+s[b:]
sub('pass_index<=0;vote_class<=0;votes_ok<=1;\n      weight_addr<=0;input_count<=0;neuron<=0;layer<=0;state<=1;',
    'pass_index<=0;vote_class<=0;votes_ok<=1;\n      weight_addr<=0;input_count<=0;neuron<=0;layer<=0;state<=5;')
sub('read_addr<=oldest;state<=1;', "read_addr<={frame_map[0],4'b0};state<=1;")
sub("if(!layer)read_addr<=read_addr==767?0:read_addr+1'b1;", "if(!layer)read_addr<=next_mapped_addr;")
a=s.index('      oldest<=oldest>=752')
b=s.index('      weight_addr<=0;',a)
s=s[:a]+'''      read_addr<={normalized_start,4'b0};
      map_index<=0;map_offset<=0;map_phase<=0;
'''+s[b:]
sub('weight_addr<=0;input_count<=0;neuron<=0;layer<=0;state<=1;\n     end else begin',
    'weight_addr<=0;input_count<=0;neuron<=0;layer<=0;state<=5;\n     end else begin')
sub('    default:state<=0;', '''    5:begin
     if(map_index<pad_frames || map_index>=42)begin
      frame_map[map_index]<=normalized_start;
      if(map_index==47)state<=1;else map_index<=map_index+1'b1;
     end else begin
      frame_map[map_index]<=normalized_start+map_offset;
      map_phase<=map_phase+{1'b0,speech_frames};
      map_index<=map_index+1'b1;state<=6;
     end
    end
    6:begin
     if(map_phase>={2'b0,target_frames})begin
      map_phase<=map_phase-{2'b0,target_frames};map_offset<=map_offset+1'b1;
     end else state<=5;
    end
    default:state<=0;''')
dest=root/'voice/experiments/robust_normalized/aca_kws_engine.v'
model=dest.parent/'model'
cfg=json.loads((model/'config.json').read_text())
for key,name in [('WEIGHTS_FILE','weights.mem'),('BIAS_FILE','bias.mem')]:
 s=re.sub(key+r'="[^"]+"',key+'="'+(model/name).as_posix()+'"',s)
s=re.sub(r'SHIFT=\d+,MIN_MARGIN=\d+',f"SHIFT={cfg['shift']},MIN_MARGIN={cfg['margin']}",s)
dest.write_text(s)
(dest.parent/'rtl_baseline.json').write_text(json.dumps(dict(source=str(source),sha256=hashlib.sha256(source.read_bytes()).hexdigest()),indent=2))
print('Created candidate:',dest)
