from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
for board, name in [('aca420','aca420_audio.al'), ('hx4s20','contest_proj.al')]:
    path = root / board / name
    text = path.read_text(encoding='utf-8-sig')
    text = re.sub(r'(<Project\b[^>]*\bPath=")[^"]*', lambda m: m[1] + (root/board).as_posix(), text, count=1)
    path.write_text(text, encoding='utf-8')
path = root/'aca420/rtl/aca_kws_engine.v'
text = path.read_text(encoding='utf-8')
text = text.replace('E:/anlo_project/liantiao/voice/model/', (root/'voice/model').as_posix()+'/')
path.write_text(text, encoding='utf-8')
print('Prepared isolated local project:', root)
