"""Reproducible CPU reference for the FPGA KWS investigation, never board firmware.

Official sherpa-onnx Chinese Zipformer 3.3M, published default KWS settings.
No training, owner enrollment or threshold search on the real recording.
"""
from pathlib import Path
import argparse, hashlib, json, time
import numpy as np
import soundfile as sf
import sherpa_onnx
from scipy.signal import resample_poly

ROOT = Path(__file__).resolve().parents[2]
RESEARCH = ROOT / 'research/voice_sequence_20261023'
MODEL = RESEARCH / 'sherpa-onnx-kws-zipformer-wenetspeech-3.3M-2024-01-01'
OUT = ROOT / 'voice/experiments/open_kws_reference'
KEYWORDS = ('x i\u00e0 y \u012b zh \u0101ng @NEXT\n'
            'sh \u00e0ng y \u012b zh \u0101ng @PREV\n'
            'x i\u00e0 y \u00ec zh \u0101ng @NEXT\n'
            'sh \u00e0ng y \u00ec zh \u0101ng @PREV\n')

def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()

def create():
    OUT.mkdir(parents=True, exist_ok=True)
    keywords = OUT / 'keywords.txt'
    keywords.write_text(KEYWORDS, encoding='utf-8')
    tokens = dict(line.rsplit(' ', 1) for line in (MODEL/'tokens.txt').read_text(encoding='utf-8').splitlines())
    for line in KEYWORDS.splitlines():
        assert all(token in tokens for token in line.split()[:-1])
    return sherpa_onnx.KeywordSpotter(
        tokens=str(MODEL/'tokens.txt'),
        encoder=str(MODEL/'encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx'),
        decoder=str(MODEL/'decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx'),
        joiner=str(MODEL/'joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx'),
        keywords_file=str(keywords), num_threads=2,
        keywords_score=1.0, keywords_threshold=0.25,
        num_trailing_blanks=1, max_active_paths=4)

def detect(kws, audio, sr):
    s = kws.create_stream()
    # Fixed padding permits final model chunks, not training or noise calibration.
    padded = np.r_[np.zeros(sr, dtype=np.float32), audio,
                   np.zeros(sr, dtype=np.float32)].astype(np.float32)
    hits = []
    tick = max(1, sr//50)
    t0 = time.perf_counter()
    for lo in range(0, len(padded), tick):
        s.accept_waveform(sr, padded[lo:lo+tick])
        while kws.is_ready(s):
            kws.decode_stream(s)
            r = kws.get_result(s)
            if r:
                hits.append(dict(command=r, audio_available_seconds=(min(len(padded), lo+tick)-sr)/sr))
                kws.reset_stream(s)
    s.input_finished()
    while kws.is_ready(s):
        kws.decode_stream(s)
        r = kws.get_result(s)
        if r:
            hits.append(dict(command=r, audio_available_seconds=(len(padded)-sr)/sr))
            kws.reset_stream(s)
    return dict(hits=hits, cpu_seconds=time.perf_counter()-t0,
                audio_seconds=len(audio)/sr)

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--synthetic-test', action='store_true')
    args = ap.parse_args()
    kws = create()
    wav = ROOT/'verification/user_20261021_170604.wav'
    annotation = ROOT/'verification/real_voice_transient.json'
    ann = json.loads(annotation.read_text())
    assert ann['real_direction_labels_confirmed'] and ann['spoken_classes'] == [2, 1]
    assert sha(wav) == ann['sources']['verification\\user_20261021_170604.wav']
    a, sr = sf.read(wav, dtype='float32')
    assert sr == 48000 and a.ndim == 1
    # The exact box decimator from the FPGA: six PCM samples summed then /8.
    pcm = np.rint(a*32768).astype(np.int64)
    box = (pcm[:len(pcm)//6*6].reshape(-1, 6).sum(1) >> 3).astype(np.float32)/32768
    rng = np.random.default_rng(20261023)
    noisy = np.clip(a*.7+rng.uniform(-500/32768, 500/32768, len(a))+
                    220/32768*np.sin(2*np.pi*120*np.arange(len(a))/sr), -1, 1)
    views = dict(native48k=(a, sr), fpga_box8k=(box, 8000),
                 gain_quarter=(a*.25, sr), synthetic_noise=(noisy, sr),
                 slow_resampled=(resample_poly(a, 5, 4), sr),
                 fast_resampled=(resample_poly(a, 4, 5), sr))
    real = {name: detect(kws, x, fs) for name, (x, fs) in views.items()}
    # Rate changes here change pitch too; they are stress variants, not new people.
    noise = rng.uniform(-500/32768, 500/32768, 16000*120).astype(np.float32)
    t = np.arange(len(noise))/16000
    noise += (220/32768*np.sin(2*np.pi*120*t)).astype(np.float32)
    non_speech = detect(kws, noise, 16000)
    test = None
    paths = [Path(__file__), wav, annotation, OUT/'keywords.txt',
             RESEARCH/(MODEL.name+'.tar.bz2')]
    paths += [MODEL/n for n in ['tokens.txt',
              'encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx',
              'decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx',
              'joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx']]
    if args.synthetic_test:
        data = Path('E:/anlo_project/liantiao/voice')
        manifest = data/'data/manifest.json'
        paths.append(manifest)
        rows = json.loads(manifest.read_text(encoding='utf-8'))
        cm = np.zeros((3, 3), dtype=int)
        errors = []
        for i, row in enumerate(r for r in rows if r['split'] == 'test'):
            p = data/row['path']
            assert sha(p) == row['sha256']
            x, fs = sf.read(p, dtype='float32')
            r = detect(kws, x, fs)
            pred = {'NEXT': 1, 'PREV': 2}.get(r['hits'][0]['command'], 0) if r['hits'] else 0
            cm[row['label'], pred] += 1
            if pred != row['label']:
                errors.append(dict(path=row['path'], label=row['label'], prediction=pred, hits=r['hits']))
            if i % 100 == 0:
                print('synthetic test', i, flush=True)
        test = dict(confusion=cm.tolist(), correct=int(cm[1,1]+cm[2,2]),
                    wrong_direction=int(cm[1,2]+cm[2,1]), false_accepts=int(cm[0,1:].sum()),
                    command_clips=int(cm[1:].sum()), negative_clips=int(cm[0].sum()), errors=errors)
    report = dict(cpu_reference_only=True, fpga_deployed=False,
                  pretrained_model='Chinese WenetSpeech Zipformer 3.3M, official int8 epoch12',
                  settings_selected_before_real_replay=True,
                  training_on_real_recording=False, threshold_search=False,
                  parameters=dict(keywords_threshold=.25, keywords_score=1, trailing_blanks=1, paths=4),
                  sherpa_version=sherpa_onnx.__version__, real=real, synthetic_non_speech=non_speech,
                  synthetic_test=test,
                  limitations=['Two labelled real utterances, not independent human validation.',
                               'CPU timings are not FPGA or screen response timings.',
                               'Synthetic waveform variants are correlated, not new recordings.',
                               '120s synthetic noise does not measure real room false alarms.',
                               'Pretrained Chinese model is not a bitstream for this FPGA.'],
                  sources={str(p): sha(p) for p in paths})
    (OUT/'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps({k:v for k,v in report.items() if k not in ['sources', 'synthetic_test']}, indent=2))
    if test:
        print(json.dumps({k:v for k,v in test.items() if k!='errors'}, indent=2))

if __name__ == '__main__':
    main()
