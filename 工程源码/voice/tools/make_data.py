"""Reproducible synthetic bootstrapping set; never represents real-speaker testing."""
import argparse, hashlib, json
from pathlib import Path
import sherpa_onnx
import soundfile as sf

ROOT = Path(__file__).resolve().parents[1]
PHRASES = [(1, '下一张'), (2, '上一张'), (0, '今天的天气很好'),
           (0, '请把声音调大一点'), (0, '我想听音乐'), (0, '你好'),
           (0, '下一首'), (0, '上一首'), (0, '这张照片很好看'),
           (0, '谢谢大家'), (0, '现在几点了'), (0, '不要切换图片')]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--speakers', type=int, default=120)
    args = ap.parse_args()
    p = ROOT.parents[0] / 'research/voice/vits-icefall-zh-aishell3'
    v = sherpa_onnx.OfflineTtsVitsModelConfig(model=str(p/'model.onnx'),
         lexicon=str(p/'lexicon.txt'), tokens=str(p/'tokens.txt'))
    conf = sherpa_onnx.OfflineTtsConfig(model=sherpa_onnx.OfflineTtsModelConfig(vits=v,num_threads=2),
         rule_fsts=','.join(str(p/f) for f in ['phone.fst','date.fst','number.fst','new_heteronym.fst']),
         rule_fars=str(p/'rule.far'))
    tts = sherpa_onnx.OfflineTts(conf)
    rows = []
    for sid in range(args.speakers):
        split = 'train' if sid % 6 < 4 else 'validation' if sid % 6 == 4 else 'test'
        for pi, (label, text) in enumerate(PHRASES):
            for si, speed in enumerate([0.95, 1.2] if label else [1.05]):
                path = ROOT/'data'/f's{sid:03d}_p{pi:02d}_{si}.wav'
                if not path.exists():
                    audio = tts.generate(text, sid=sid, speed=speed)
                    sf.write(path, audio.samples, audio.sample_rate, subtype='PCM_16')
                rows.append(dict(path=str(path.relative_to(ROOT)), label=label,text=text,
                                 speaker=f'aishell3_tts_{sid}', split=split, synthetic=True,
                                 sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
        (ROOT/'data/manifest.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2),encoding='utf8')
        print(f'speaker {sid+1}/{args.speakers}: {len(rows)} clips', flush=True)
    (ROOT/'data/provenance.json').write_text(json.dumps(dict(
        source='https://github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models',
        asset='vits-icefall-zh-aishell3.tar.bz2',
        asset_sha256=hashlib.sha256((p.parent/(p.name+'.tar.bz2')).read_bytes()).hexdigest(),
        purpose='Synthetic bootstrap only. Held-out TTS voices are NOT independent real people.',
        real_speaker_test=False),indent=2),encoding='utf8')

if __name__ == '__main__': main()
