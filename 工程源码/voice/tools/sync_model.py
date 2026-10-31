"""Refresh synthesis defaults after training; ROM files remain a single source."""
import json,re
from pathlib import Path
root=Path(__file__).resolve().parents[1]
cfg=json.loads((root/'model/config.json').read_text())
p=root.parent/'aca420/rtl/aca_kws_engine.v'
s=p.read_text()
for key,name in [('WEIGHTS_FILE','weights.mem'),('BIAS_FILE','bias.mem')]:
    path=(root/'model'/name).resolve().as_posix()
    s=re.sub(key+r'="[^"]+"',lambda m:f'{key}="{path}"',s)
s=re.sub(r'SHIFT=\d+,MIN_MARGIN=\d+',f"SHIFT={cfg['shift']},MIN_MARGIN={cfg['margin']}",s)
p.write_text(s)
assert cfg['hidden']==48
assert len((root/'model/weights.mem').read_text().split())==37008
print('Synced model paths, shift and acceptance margin.')
