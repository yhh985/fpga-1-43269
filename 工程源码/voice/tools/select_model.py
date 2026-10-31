"""Compare only the fixed augmented validation split; never use test scores."""
import hashlib,json,shutil
from pathlib import Path
root=Path(__file__).resolve().parents[1]
names=['mel_first_calibrated','mel_calibrated','mel_conv13','mel_conv24','mel_dense_selected']
rows=[]
for name in names:
    folder=root/'experiments'/name
    r=json.loads((folder/'training.json').read_text())
    cm=r['validation']['confusion']
    commands=sum(sum(row) for row in cm[1:]);correct=cm[1][1]+cm[2][2]
    negatives=sum(cm[0]);fa=sum(cm[0][1:])
    assert commands==400 and negatives==1026
    w=folder/'model/weights.mem'
    assert hashlib.sha256(w.read_bytes()).hexdigest()==r['weight_sha256']
    rows.append(dict(name=name,command_correct=correct,commands=commands,
                     false_accepts=fa,negatives=negatives,
                     architecture=r['model'].get('architecture','dense'),
                     eligible=fa<=int(negatives*.005)))
best=max((r for r in rows if r['eligible']),key=lambda r:(r['command_correct'],-r['false_accepts']))
folder=root/'experiments'/best['name']
for p in (folder/'model').iterdir():shutil.copy2(p,root/'model'/p.name)
shutil.copy2(folder/'training.json',root/'verification/training.json')
report=dict(selected=best['name'],criterion='Quantized command accuracy; validation false accepts <= 0.5%',
            test_used_for_selection=False,candidates=rows,
            note='Earlier development test replays exist; this is not a fresh blind real-person evaluation.')
(root/'verification/model_selection.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
