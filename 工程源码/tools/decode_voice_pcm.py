"""Decode lossless 8 kHz recognition-input PCM and simultaneous voice features."""
from pathlib import Path
import argparse
import binascii
import hashlib
import json
import wave

import numpy as np
from decode_voice_capture import decode as decode_features

SIZE = 596


def packets(raw):
    blocks = []
    bad = offset = 0
    while True:
        pos = raw.find(b'\xa5\x5a\x55', offset)
        if pos < 0 or pos + SIZE > len(raw):
            break
        b = raw[pos:pos+SIZE]
        if binascii.crc_hqx(b[:-2], 0xffff) != int.from_bytes(b[-2:], 'little'):
            bad += 1
            offset = pos + 1
            continue
        blocks.append(b)
        offset = pos + SIZE
    return blocks, bad


def decode(raw, passes=3):
    blocks, bad = packets(raw)
    frames = [int.from_bytes(b[3:5], 'little') for b in blocks]
    gaps = [[a, b] for a, b in zip(frames, frames[1:]) if b != (a+1) & 65535]
    counts = [int.from_bytes(b[72:74], 'little') for b in blocks]
    faults = [i for i, b in enumerate(blocks) if b[71] or b[70] != 0x25 or counts[i] != 256]
    # Reuse the established feature parser without changing its old protocol.
    old = bytearray()
    for b in blocks:
        header = bytearray(b[:72])
        header[2] = 0x52
        old += header + binascii.crc_hqx(header, 0xffff).to_bytes(2, 'little')
    feature_report, f = decode_features(old,passes=passes)
    trace = [dict(frame=frames[i], debug_sequence=int.from_bytes(b[586:588], "little"),
                  issued_count=int.from_bytes(b[588:590], "little"),
                  ack_count=int.from_bytes(b[590:592], "little"),
                  online=bool(b[592]&1), voice_running=bool(b[592]&2),
                  pending=bool(b[592]&4), failed=bool(b[592]&8), overflow=bool(b[592]&16),
                  display=(b[592]>>5)&3, command=b[593]) for i,b in enumerate(blocks)]
    pcm = np.concatenate([np.frombuffer(b[74:586], dtype='<i2') for b in blocks]) if blocks else np.zeros(0, dtype='<i2')
    report = dict(valid_packets=len(blocks), crc_errors=bad, frame_gaps=gaps,
                  faulty_packets=faults, raw_sha256=hashlib.sha256(raw).hexdigest(),
                  audio_contiguous=bool(blocks) and not (bad or gaps or faults),
                  sample_rate_nominal=8000, samples=len(pcm), seconds=len(pcm)/8000,
                  peak=int(np.abs(pcm.astype(np.int32)).max()) if len(pcm) else 0,
                  full_scale_flag_packets=sum(bool(b[5] & 16) for b in blocks),
                  clip_flag_note='Sticky raw-ADC full-scale flag; not number of clipped PCM samples',
                  feature_report=feature_report, command_trace=trace)
    return report, f, pcm


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('capture', type=Path)
    ap.add_argument('--passes',type=int,choices=[1,3],default=3,
                    help='Use 1 for sensitive-guard firmware; 3 for normalized firmware')
    args = ap.parse_args()
    report, f, pcm = decode(args.capture.read_bytes(),passes=args.passes)
    args.capture.with_suffix('.pcm.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf8')
    print(json.dumps({k: v for k, v in report.items() if k not in ('feature_report','command_trace')}, indent=2))
    if not report['audio_contiguous']:
        raise SystemExit('No continuous valid PCM: check firmware, voice mode and 460800 baud. WAV was not exported.')
    np.save(args.capture.with_suffix('.features.npy'), f)
    old = bytearray()
    for block in packets(args.capture.read_bytes())[0]:
        header = bytearray(block[:72]); header[2] = 0x52
        old += header + binascii.crc_hqx(header, 0xffff).to_bytes(2, 'little')
    args.capture.with_suffix('.feature.bin').write_bytes(old)
    with wave.open(str(args.capture.with_suffix('.wav')), 'wb') as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(8000)
        wav.writeframes(pcm.astype('<i2').tobytes())
    print('WAV:', args.capture.with_suffix('.wav'))


if __name__ == '__main__':
    main()
