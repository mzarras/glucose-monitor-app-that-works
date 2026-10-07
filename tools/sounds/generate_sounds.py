#!/usr/bin/env python3
# Sensor — alert sound generator (HANDOFF §5 "Sounds").
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Writes the eight alert sounds in Resources/Sounds/ from nothing but arithmetic: no samples, no
# recordings, no third-party code or libraries (Python standard library only). Every sound is
# therefore original work, licensed with the rest of this repository (GPL-3.0; see
# Resources/Sounds/README.md, which also lists the SHA-256 of each output).
#
#   python3 tools/sounds/generate_sounds.py            # (re)write Resources/Sounds/*.wav
#   python3 tools/sounds/generate_sounds.py --check    # verify committed files match, exit 1 if not
#
# Output formats, one pair per sound:
#   alert-<name>.wav  RIFF WAVE, linear PCM, 16-bit signed, mono, 22 050 Hz. For notifications
#                     (Apple "UNNotificationSound": Linear PCM, MA4 (IMA/ADPCM), µLaw or aLaw in aiff,
#                     wav or caf; shorter than 30 s) and the in-app AVAudioPlayer (ringer-off path).
#   alert-<name>.caf  Core Audio Format, Apple IMA4 (IMA/ADPCM, 64 frames in 34 bytes per packet),
#                     mono, 22 050 Hz, encoded here from the same samples. For AlarmKit system alarms
#                     (PROGRESS.md D26): Loop verified on hardware that AlarmKit plays bundled IMA4 .caf
#                     files by name (LoopKit/Loop PR #2520); WAV is unverified there.
# Every sound here is 2.4–5.2 s.
#
# Plus one silent file (PROGRESS.md D53): alert-vibrate.caf, 1 s of digital silence in the same IMA4
# CAF format, the notification sound of vibrate-only alerts (see SILENT below).
#
# Design rule (the reason this project exists): every sound differs from the others in rhythm AND
# pitch contour, not just pitch, and none is a constant-pitch train of high square-wave beeps (the
# classic pager tone). Michael verifies by ear on device (HANDOFF §11 step 1).
#
# Determinism: no randomness; only math.sin/math.exp on fixed inputs, rounded to 16-bit integers.
# The WAV header written by the `wave` module has no timestamps. Re-running produces identical
# bytes; `--check` proves it against the committed files.

import argparse
import hashlib
import math
import os
import struct
import sys
import wave

SAMPLE_RATE = 22050
PEAK = 0.89  # normalise every sound to about -1 dBFS peak

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUTPUT_DIR = os.path.join(REPO_ROOT, "Resources", "Sounds")

# Equal-tempered pitches (A4 = 440 Hz) used below, in Hz.
C4, E4, FS4, G4, A4 = 261.63, 329.63, 369.99, 392.00, 440.00
F4 = 349.23
C5, E5, G5 = 523.25, 659.26, 783.99


def silence(seconds):
    return [0.0] * int(round(seconds * SAMPLE_RATE))


def mix(buffer, samples, at_seconds, gain=1.0):
    """Adds `samples` into `buffer` starting at `at_seconds`, growing the buffer if needed."""
    start = int(round(at_seconds * SAMPLE_RATE))
    end = start + len(samples)
    if end > len(buffer):
        buffer.extend([0.0] * (end - len(buffer)))
    for i, s in enumerate(samples):
        buffer[start + i] += s * gain


def envelope(i, n, attack, release, decay_tau=None):
    """Linear attack, optional exponential decay, linear release at the very end (no clicks)."""
    t = i / SAMPLE_RATE
    duration = n / SAMPLE_RATE
    gain = 1.0
    if attack > 0 and t < attack:
        gain *= t / attack
    if decay_tau is not None:
        gain *= math.exp(-t / decay_tau)
    if release > 0 and t > duration - release:
        gain *= max(0.0, (duration - t) / release)
    return gain


def tone(freq, seconds, partials, attack=0.005, release=0.02, decay_tau=None):
    """Additive tone: `partials` is a list of (frequency ratio, amplitude)."""
    n = int(round(seconds * SAMPLE_RATE))
    out = []
    for i in range(n):
        t = i / SAMPLE_RATE
        value = 0.0
        for ratio, amplitude in partials:
            value += amplitude * math.sin(2 * math.pi * freq * ratio * t)
        out.append(value * envelope(i, n, attack, release, decay_tau))
    return out


def glide(f_start, f_end, seconds, partials, attack=0.02, release=0.04):
    """Tone whose pitch moves exponentially from f_start to f_end (phase-continuous)."""
    n = int(round(seconds * SAMPLE_RATE))
    out = []
    phase = 0.0
    for i in range(n):
        frac = i / max(1, n - 1)
        freq = f_start * (f_end / f_start) ** frac
        phase += 2 * math.pi * freq / SAMPLE_RATE
        value = 0.0
        for ratio, amplitude in partials:
            value += amplitude * math.sin(phase * ratio)
        out.append(value * envelope(i, n, attack, release))
    return out


# Timbres, as (ratio, amplitude) partial lists.
RICH = [(1, 1.0), (2, 0.5), (3, 0.3), (4, 0.15)]            # bright, dense: urgent
SOFT = [(1, 1.0), (2, 0.15)]                                  # nearly pure: gentle swell
MARIMBA = [(1, 1.0), (3.93, 0.25), (9.2, 0.06)]               # wooden bar ratios ~1:4:10
BELL = [(1, 1.0), (2.0, 0.45), (3.0, 0.25), (4.2, 0.12)]      # bright bell
CHIME = [(1, 1.0), (2.76, 0.35), (5.4, 0.12)]                 # tubular chime-like, inharmonic
HOLLOW = [(1, 1.0), (3, 0.28), (5, 0.12)]                     # odd harmonics only, soft square-ish


def cascade():
    """Urgent low. Fast falling four-note figure (E5-C5-A4-E4) in three tight bursts, then a
    pause; the whole phrase twice. Dense harmonics, hard attacks: the most insistent sound."""
    out = []
    burst = [E5, C5, A4, E4]
    t = 0.0
    for _phrase in range(2):
        for _burst in range(3):
            for f in burst:
                mix(out, tone(f, 0.11, RICH, attack=0.004, release=0.015), t)
                t += 0.13
            t += 0.22
        t += 0.9
    return out


def tide():
    """Urgent low soon. Slow falling minor third (A4 then F#4) with a swelling attack, twice."""
    out = []
    t = 0.0
    for _ in range(2):
        mix(out, tone(A4, 0.65, SOFT, attack=0.12, release=0.12), t)
        mix(out, tone(FS4, 0.95, SOFT, attack=0.12, release=0.25), t + 0.7)
        t += 2.1
    return out


def dusk():
    """Low. Three unhurried descending wooden notes (G4-E4-C4), ringing out."""
    out = []
    for k, f in enumerate([G4, E4, C4]):
        mix(out, tone(f, 1.4, MARIMBA, attack=0.003, release=0.05, decay_tau=0.45), k * 0.5)
    return out


def summit():
    """High. Three bright ascending bell notes (C5-E5-G5), the last one held."""
    out = []
    for k, f in enumerate([C5, E5, G5]):
        length = 1.8 if k == 2 else 0.9
        mix(out, tone(f, length, BELL, attack=0.003, release=0.08, decay_tau=0.6), k * 0.28)
    return out


def swoop():
    """Rise / fall rate. A continuous up-and-down pitch glide ("whoop"), twice."""
    out = []
    t = 0.0
    for _ in range(2):
        mix(out, glide(300, 900, 0.55, SOFT), t)
        mix(out, glide(900, 300, 0.55, SOFT), t + 0.55)
        t += 1.5
    return out


def sonar():
    """Missed readings. A single ping with an echo, repeated once after a long gap: sparse."""
    out = []
    for start in (0.0, 1.9):
        mix(out, tone(880, 1.2, SOFT, attack=0.002, release=0.05, decay_tau=0.28), start)
        mix(out, tone(880, 1.0, SOFT, attack=0.002, release=0.05, decay_tau=0.25), start + 0.36, gain=0.35)
    return out


def doorbell():
    """Sensor information (warm-up done, expiring, grace period). Two-note ding-dong (E5, C5)."""
    out = []
    mix(out, tone(E5, 1.6, CHIME, attack=0.003, release=0.1, decay_tau=0.7), 0.0)
    mix(out, tone(C5, 2.0, CHIME, attack=0.003, release=0.15, decay_tau=0.8), 0.55)
    return out


def warble():
    """Faults (sensor failed/error/expired, Bluetooth, Trio bridge). Low two-tone trill (F4/A4 at
    ten notes a second) in three bursts: sounds like something is wrong, not like a reading."""
    out = []
    t = 0.0
    for _burst in range(3):
        for k in range(8):
            f = F4 if k % 2 == 0 else A4
            mix(out, tone(f, 0.1, HOLLOW, attack=0.004, release=0.01), t + k * 0.1)
        t += 0.8 + 0.45
    return out


# (file name, generator). File names are prefixed `alert-` so they never collide with the font
# files that are copied into the same app-bundle root (PROGRESS.md D13).
SOUNDS = [
    ("alert-cascade.wav", cascade),
    ("alert-tide.wav", tide),
    ("alert-dusk.wav", dusk),
    ("alert-summit.wav", summit),
    ("alert-swoop.wav", swoop),
    ("alert-sonar.wav", sonar),
    ("alert-doorbell.wav", doorbell),
    ("alert-warble.wav", warble),
]


# Silent notification sounds (PROGRESS.md D53, vibrate-only alerts): IMA4 .caf of digital silence.
# iOS has no vibrate-only option for a local notification; it plays the vibration that goes with a
# notification sound (subject to Settings → Sounds & Haptics → Haptics), so a silent sound gives the
# vibration without any sound. IMA4 of all-zero samples decodes to exact zeros (each 4-bit code is 0
# and the step never grows past 7, so every difference is 7 >> 3 = 0).
SILENT = [
    ("alert-vibrate.caf", 1.0),
]


def render(generator):
    """The sound as 16-bit integer samples, normalised to PEAK."""
    samples = generator() + silence(0.05)
    peak = max(abs(s) for s in samples) or 1.0
    scale = PEAK / peak
    return [max(-32768, min(32767, int(round(s * scale * 32767)))) for s in samples]


def pcm16_le(samples):
    return b"".join(struct.pack("<h", v) for v in samples)


# --- Apple IMA4 (IMA ADPCM) -----------------------------------------------------------------
# The standard IMA ADPCM step and index tables (IMA Digital Audio Focus and Technical Working
# Groups, "Recommended Practices for Enhancing Digital Audio Compatibility in Multimedia Systems",
# rev. 3.00, 1992). Apple's 'ima4' packs each channel into 34-byte packets: a big-endian 16-bit
# header whose top 9 bits are the predictor (low 7 bits of the predictor are zero) and whose low 7
# bits are the step index, then 32 bytes holding 64 4-bit codes, earlier sample in the low nibble.
# (Apple Core Audio Format Specification, "IMA4"; decoders: FFmpeg libavcodec/adpcm.c
# AV_CODEC_ID_ADPCM_IMA_QT.) The encoder below mirrors the decoder exactly, so its state never
# drifts from what the player reconstructs; AlertSoundCatalogTests decodes every .caf with Apple's
# own AVAudioFile and compares it with the .wav.
IMA_STEPS = [
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66,
    73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408,
    449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
    2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630,
    9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794,
    32767,
]
IMA_INDEX_ADJUST = [-1, -1, -1, -1, 2, 4, 6, 8]
IMA4_FRAMES_PER_PACKET = 64
IMA4_BYTES_PER_PACKET = 34


def ima4_packets(samples):
    """Encodes 16-bit samples as Apple IMA4 packets (the last packet padded with zeros)."""
    padded = list(samples)
    while len(padded) % IMA4_FRAMES_PER_PACKET:
        padded.append(0)
    predictor, index = 0, 0
    out = bytearray()
    for start in range(0, len(padded), IMA4_FRAMES_PER_PACKET):
        # The decoder restarts each packet from the stored 9-bit predictor; do the same.
        # Keep the top 9 bits: an arithmetic shift rounds towards −∞, exactly like masking the
        # 16-bit two's-complement value with 0xFF80.
        header_predictor = (predictor >> 7) << 7
        predictor = header_predictor
        out += struct.pack(">H", (header_predictor & 0xFF80) | index)
        codes = []
        for sample in padded[start:start + IMA4_FRAMES_PER_PACKET]:
            step = IMA_STEPS[index]
            diff = sample - predictor
            code = 0
            if diff < 0:
                code = 8
                diff = -diff
            delta = step >> 3
            if diff >= step:
                code |= 4
                diff -= step
                delta += step
            if diff >= step >> 1:
                code |= 2
                diff -= step >> 1
                delta += step >> 1
            if diff >= step >> 2:
                code |= 1
                delta += step >> 2
            predictor = predictor - delta if code & 8 else predictor + delta
            predictor = max(-32768, min(32767, predictor))
            index = max(0, min(88, index + IMA_INDEX_ADJUST[code & 7]))
            codes.append(code)
        for i in range(0, IMA4_FRAMES_PER_PACKET, 2):
            out.append(codes[i] | (codes[i + 1] << 4))
    return bytes(out)


def caf_ima4_bytes(samples):
    """Core Audio Format file (big-endian chunks, Apple CAF spec): 'caff' header, 'desc' chunk
    (AudioStreamBasicDescription), 'data' chunk (edit count + packets). Constant bit rate, so no
    packet table is needed; the last packet's zero padding plays as < 3 ms of silence."""
    packets = ima4_packets(samples)
    out = b"caff" + struct.pack(">HH", 1, 0)
    # desc: sample rate (Float64), format 'ima4', flags 0, bytes/packet 34, frames/packet 64,
    # channels 1, bits/channel 0 (compressed).
    desc = struct.pack(">d4sIIIII", float(SAMPLE_RATE), b"ima4", 0, IMA4_BYTES_PER_PACKET,
                       IMA4_FRAMES_PER_PACKET, 1, 0)
    out += b"desc" + struct.pack(">q", len(desc)) + desc
    out += b"data" + struct.pack(">q", 4 + len(packets)) + struct.pack(">I", 0) + packets
    return out


def wav_bytes(frames):
    """RIFF/WAVE container by hand, so the header is fully determined by the frame count."""
    data_size = len(frames)
    header = b"RIFF" + struct.pack("<I", 36 + data_size) + b"WAVE"
    # fmt chunk: PCM (1), mono, sample rate, byte rate, block align, bits per sample.
    header += b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, SAMPLE_RATE, SAMPLE_RATE * 2, 2, 16)
    header += b"data" + struct.pack("<I", data_size)
    return header + frames


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify committed files, write nothing")
    args = parser.parse_args()

    mismatches = 0
    for name, generator in SOUNDS:
        samples = render(generator)
        caf_name = name.replace(".wav", ".caf")
        for file_name, data in ((name, wav_bytes(pcm16_le(samples))), (caf_name, caf_ima4_bytes(samples))):
            path = os.path.join(OUTPUT_DIR, file_name)
            digest = hashlib.sha256(data).hexdigest()
            seconds = len(samples) / SAMPLE_RATE
            if args.check:
                try:
                    with open(path, "rb") as f:
                        same = f.read() == data
                except FileNotFoundError:
                    same = False
                status = "ok" if same else "MISMATCH"
                mismatches += 0 if same else 1
                print(f"{status:8} {file_name:22} {seconds:5.2f} s  sha256 {digest}")
            else:
                os.makedirs(OUTPUT_DIR, exist_ok=True)
                with open(path, "wb") as f:
                    f.write(data)
                print(f"wrote    {file_name:22} {seconds:5.2f} s  sha256 {digest}")
    for file_name, seconds in SILENT:
        samples = [0] * int(round(seconds * SAMPLE_RATE))
        data = caf_ima4_bytes(samples)
        path = os.path.join(OUTPUT_DIR, file_name)
        digest = hashlib.sha256(data).hexdigest()
        if args.check:
            try:
                with open(path, "rb") as f:
                    same = f.read() == data
            except FileNotFoundError:
                same = False
            status = "ok" if same else "MISMATCH"
            mismatches += 0 if same else 1
            print(f"{status:8} {file_name:22} {seconds:5.2f} s  sha256 {digest}  (silence)")
        else:
            with open(path, "wb") as f:
                f.write(data)
            print(f"wrote    {file_name:22} {seconds:5.2f} s  sha256 {digest}  (silence)")
    # Sanity-check the container with the standard library reader.
    if not args.check:
        for name, _ in SOUNDS:
            with wave.open(os.path.join(OUTPUT_DIR, name), "rb") as w:
                assert w.getnchannels() == 1 and w.getsampwidth() == 2 and w.getframerate() == SAMPLE_RATE
                assert w.getnframes() / SAMPLE_RATE < 30
    return 1 if mismatches else 0


if __name__ == "__main__":
    sys.exit(main())
