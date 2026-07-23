#!/usr/bin/env python3
"""Render the phone's tones to real audio files.

The phone has always synthesised its sounds in the browser, which keeps the resource
small but leaves them thin: a bare sine has no body, and WebAudio has to be resumed by a
gesture before it makes a sound at all. This renders the same scores to WAV files that
ship with the resource, with harmonics and a proper envelope, so a ringtone sounds like
a ringtone and plays the instant it is asked for.

Nothing here is sampled from anywhere. Every file is generated from the numbers below,
which is what makes them safe to ship.

    python tools/make-sounds.py

Mono, 22050 Hz, 16 bit: small enough that ten of them cost about a megabyte, and far
above what a phone speaker in a game needs.
"""

import math
import os
import struct
import wave

RATE = 22050
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(HERE), 'sounds')

# A note is (frequency, start seconds, length seconds, gain). The scores match the ones
# the page falls back to, so a server that turns files off hears the same melody.
RINGTONES = {
    'classic': [(880, 0.00, .16), (1175, .18, .16), (880, .36, .16), (1175, .54, .30),
                (880, 0.90, .16), (1175, 1.08, .16), (880, 1.26, .16), (1175, 1.44, .40)],
    'chime':   [(1319, 0.00, .50), (1568, .12, .50), (2093, .24, .80),
                (1319, 1.10, .50), (1568, 1.22, .50), (2093, 1.34, .90)],
    'pulse':   [(440, 0.00, .10), (440, .14, .10), (440, .28, .10), (660, .42, .34),
                (440, 0.90, .10), (440, 1.04, .10), (440, 1.18, .10), (660, 1.32, .40)],
    'radar':   [(523, 0.00, .22), (659, .22, .22), (784, .44, .22), (1047, .66, .44),
                (523, 1.20, .22), (659, 1.42, .22), (784, 1.64, .22), (1047, 1.86, .50)],
    # One that is not in the built-in set: a low two note pattern for somebody who wants
    # a phone that does not sound like a phone.
    'signal':  [(392, 0.00, .26), (330, .28, .40), (392, .90, .26), (330, 1.18, .50)],
}

ALERTS = {
    'ping': [(1568, 0.00, .18), (2093, .07, .26)],
    'pop':  [(880, 0.00, .09), (1320, .05, .14)],
    'tick': [(1200, 0.00, .05)],
    'note': [(1046, 0.00, .12), (1568, .09, .20)],
}

# The interface sounds. Short enough that the page could synthesise them, but shipping
# them too means every sound the phone makes comes from one place.
UI = {
    'unlock':  [(1046, 0.00, .09), (1568, .05, .16)],
    'lock':    [(784, 0.00, .07), (523, .05, .15)],
    'success': [(1318, 0.00, .08), (1760, .07, .10), (2637, .15, .20)],
    'error':   [(311, 0.00, .11), (233, .10, .20)],
    'shutter': [(2400, 0.00, .02), (1200, .03, .06)],
}


def envelope(pos, length):
    """Attack, then an exponential tail. A note that stops dead clicks."""
    attack = min(0.008, length * 0.25)
    if pos < attack:
        return pos / attack
    remaining = (pos - attack) / max(1e-6, length - attack)
    return math.exp(-4.2 * remaining)


def render(score, tail=0.25):
    """A score to a list of samples, harmonics included.

    The second and third harmonics at a fifth and a sixth of the level turn a sine into
    something with a body to it, which is the whole difference between a tone and a
    ringtone.
    """
    duration = max(start + length for _, start, length in score) + tail
    total = int(duration * RATE)
    buffer = [0.0] * total

    for freq, start, length in score:
        first = int(start * RATE)
        count = int(length * RATE)
        for i in range(count):
            index = first + i
            if index >= total:
                break
            t = i / RATE
            amp = envelope(t, length)
            sample = (
                math.sin(2 * math.pi * freq * t)
                + 0.20 * math.sin(4 * math.pi * freq * t)
                + 0.08 * math.sin(6 * math.pi * freq * t)
            )
            buffer[index] += sample * amp * 0.32

    # One pass of normalisation, so every file lands at the same loudness and a server
    # does not have to trim the volume per ringtone.
    peak = max((abs(s) for s in buffer), default=0.0)
    if peak > 0:
        scale = 0.89 / peak
        buffer = [s * scale for s in buffer]
    return buffer


def write(name, samples):
    path = os.path.join(OUT, name + '.wav')
    with wave.open(path, 'wb') as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes(b''.join(
            struct.pack('<h', max(-32768, min(32767, int(s * 32767)))) for s in samples))
    return os.path.getsize(path)


def main():
    os.makedirs(OUT, exist_ok=True)
    total = 0
    for group, tail in ((RINGTONES, 0.45), (ALERTS, 0.20), (UI, 0.18)):
        for name, score in group.items():
            prefix = ('ring_' if group is RINGTONES
                      else 'alert_' if group is ALERTS else 'ui_')
            size = write(prefix + name, render(score, tail))
            total += size
            print('%-18s %6.1f KB' % (prefix + name + '.wav', size / 1024))
    print('%d files, %.1f KB total' % (
        len(RINGTONES) + len(ALERTS) + len(UI), total / 1024))


if __name__ == '__main__':
    main()
