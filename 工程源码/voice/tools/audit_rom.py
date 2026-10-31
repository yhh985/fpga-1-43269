"""Confirm trained weight bitplanes survived TD synthesis as initialized ERAM."""
import hashlib,json,re
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
netlist=ROOT.parent/'aca420/verification/aca420_gate_audit.v'
text=netlist.read_text()
weight_file=ROOT/'model/weights.mem'
weights=[int(v,16) for v in weight_file.read_text().split()]
planes={}
for bank in range(8):
    for bit in range(8):
        value=sum((((weights[a] if a<len(weights) else 0)>>bit)&1)<<i
                  for i,a in enumerate(range(bank*8192,(bank+1)*8192)))
        planes[bank,bit]=value
covered=set();blocks=0
for params,name,ports in re.findall(r'EG_PHY_BRAM #\((.*?)\)\s*(\\[^\s]+)\s*\((.*?)\);',text,re.S):
    if 'weight_addr' not in ports:continue
    blocks+=1
    assert '.DATA_WIDTH_A("1")' in params and '.WEAMUX("0")' in params
    bank=sum((c=='SIG')<<i for i,c in enumerate(re.findall(r'\.CSA[012]\("(.*?)"\)',params)))
    vals={int(i,16):int(v,16) for i,v in re.findall(r"\.INIT_([0-9A-Fa-f]{2})\(256'h([0-9a-fA-F]+)\)",params)}
    value=sum(vals.get(i,0)<<(256*i) for i in range(32))
    matches={key for key,p in planes.items() if key[0]==bank and p==value}
    assert matches,f'Unexpected ROM contents in {name}'
    covered.update(matches)
# Identical sign-bit planes may share a physical RAM; constant zero planes can be optimized away.
required={key for key,value in planes.items() if key[0]*8192<len(weights) and value!=0}
assert required<=covered,sorted(required-covered)
report=dict(passed=True,weight_bytes=len(weights),physical_weight_rams=blocks,
            verified_nonzero_bitplanes=len(required),
            weight_sha256=hashlib.sha256(weight_file.read_bytes()).hexdigest(),
            netlist_sha256=hashlib.sha256(netlist.read_bytes()).hexdigest(),
            scope='Synthesized weight ERAM initialization and bank selection; not post-route functional simulation.')
(ROOT/'verification/rom_audit.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
