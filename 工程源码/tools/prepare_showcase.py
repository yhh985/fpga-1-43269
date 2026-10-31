"""Resolve project metadata and ROM paths to the extracted project directory."""
from pathlib import Path
import json,re,xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[1]
def prepare():
    for board,name in [('aca420','aca420_audio.al'),('hx4s20','contest_proj.al')]:
        p=ROOT/board/name
        s=p.read_text(encoding='utf-8-sig').replace('Name="UsedInP&R"','Name="UsedInP&amp;R"')
        s=re.sub(r'(<Project\b[^>]*\bPath=")[^"]*',lambda m:m[1]+(ROOT/board).as_posix(),s,count=1)
        p.write_text(s,encoding='utf-8')
        tree=ET.fromstring(s)
        missing=[e.attrib['Path'] for e in tree.iter('File') if not (p.parent/e.attrib['Path']).is_file()]
        assert not missing,(board,missing)
    p=ROOT/'aca420/rtl/aca_ctc_engine.v'
    s=p.read_text(encoding='utf-8-sig')
    s=re.sub(r'MODEL_DIR="[^"]*"',lambda _: 'MODEL_DIR="'+(ROOT/'voice/model_ctc').as_posix()+'/"',s,count=1)
    p.write_text(s,encoding='utf-8')
    p=ROOT/'aca420/rtl/aca_kws_engine.v'
    s=p.read_text(encoding='utf-8-sig')
    for param,name in [('WEIGHTS_FILE','weights.mem'),('BIAS_FILE','bias.mem')]:
        s=re.sub(param+r'="[^"]*"',lambda _,a=param,b=name:a+'="'+(ROOT/'voice/experiments/robust_normalized/model'/b).as_posix()+'"',s,count=1)
    p.write_text(s,encoding='utf-8')
    for name in ['weights.mem','bias.mem','shift.mem','logadd.mem','codes.mem','lengths.mem','commands.mem']:
        assert (ROOT/'voice/model_ctc'/name).is_file(),name
    (ROOT/'verification').mkdir(exist_ok=True)
    print('PASS project paths, 2 TD source lists, and CTC model dependencies:',ROOT)
if __name__=='__main__':prepare()
