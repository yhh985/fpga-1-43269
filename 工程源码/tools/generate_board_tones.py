"""Create three short, distinct PCM16 48kHz tones for physical track testing."""
from pathlib import Path
import wave,math,struct
root=Path(__file__).resolve().parents[1]/'card_test'
root.mkdir(exist_ok=True)
for index,freq in enumerate([220,660,1320],1):
    frames=bytearray()
    for i in range(48000*3):
        env=min(1,i/480,(144000-1-i)/480)
        value=round(4000*env*math.sin(2*math.pi*freq*i/48000))
        frames+=struct.pack('<hh',value,value)
    with wave.open(str(root/f'TEST{index:03}.WAV'),'wb') as f:
        f.setnchannels(2);f.setsampwidth(2);f.setframerate(48000);f.writeframes(frames)
print('Three original test tones generated: 220/660/1320Hz, PCM16 stereo 48kHz, 3s each.')
