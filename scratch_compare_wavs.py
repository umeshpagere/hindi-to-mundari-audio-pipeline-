import wave
import sys
import numpy as np

def analyze_wav(filepath):
    try:
        with wave.open(filepath, 'rb') as f:
            n_channels = f.getnchannels()
            sampwidth = f.getsampwidth()
            framerate = f.getframerate()
            n_frames = f.getnframes()
            data = f.readframes(n_frames)
            # compute max amplitude
            if sampwidth == 2:
                samples = np.frombuffer(data, dtype=np.int16)
                max_amp = np.max(np.abs(samples))
                mean_amp = np.mean(np.abs(samples))
            else:
                max_amp = 0
                mean_amp = 0
            
            print(f"File: {filepath}")
            print(f"  Channels: {n_channels}")
            print(f"  Sample width: {sampwidth} bytes ({sampwidth*8} bits)")
            print(f"  Sample rate: {framerate} Hz")
            print(f"  Frames: {n_frames}")
            print(f"  Duration: {n_frames / framerate:.2f} seconds")
            print(f"  Max amplitude: {max_amp}")
            print(f"  Mean amplitude: {mean_amp:.2f}")
            print("")
    except Exception as e:
        print(f"Error reading {filepath}: {e}")

analyze_wav('/Users/umeshpagere/hindi-to-mandari-audio-pipeline/test_output_1.wav')
analyze_wav('/Users/umeshpagere/hindi-to-mandari-audio-pipeline/pipeline_output.wav')
