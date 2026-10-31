"""Create a small listenable command set from held-out AISHELL-3 TTS voices."""
import json
from pathlib import Path
import soundfile as sf
import sherpa_onnx

ROOT=Path(__file__).resolve().parents[1]
MODEL=ROOT.parent/'research/voice/vits-icefall-zh-aishell3'
OUT=ROOT/'demo_multispeaker'

def main():
    OUT.mkdir(exist_ok=True)
    assets=json.loads((ROOT.parent/'research/voice/tts_assets.json').read_text(encoding='utf-8'))
    model=sherpa_onnx.OfflineTtsVitsModelConfig(model=str(MODEL/'model.onnx'),
        lexicon=str(MODEL/'lexicon.txt'),tokens=str(MODEL/'tokens.txt'))
    config=sherpa_onnx.OfflineTtsConfig(
        model=sherpa_onnx.OfflineTtsModelConfig(vits=model,num_threads=2),
        rule_fsts=','.join(str(MODEL/name) for name in
            ['phone.fst','date.fst','number.fst','new_heteronym.fst']),
        rule_fars=str(MODEL/'rule.far'))
    tts=sherpa_onnx.OfflineTts(config)
    rows=[]
    for sid in [7,23,51,89,121,170]:
        for text,label,name in [('下一张',1,'next'),('上一张',2,'previous')]:
            audio=tts.generate(text,sid=sid,speed=1.0)
            path=OUT/f'speaker_{sid:03d}_{name}.wav'
            sf.write(path,audio.samples,audio.sample_rate,subtype='PCM_16')
            rows.append(dict(path=path.name,text=text,label=label,speaker_id=sid,
                speaker_count=174,synthetic=True,sample_rate=audio.sample_rate))
    (OUT/'manifest.json').write_text(json.dumps(dict(source=assets.get('html_url'),
        real_speaker_test=False,clips=rows),ensure_ascii=False,indent=2),encoding='utf-8')
    print(f'PASS: {len(rows)} command clips from {len({r["speaker_id"] for r in rows})} TTS speakers')

if __name__=='__main__':main()
