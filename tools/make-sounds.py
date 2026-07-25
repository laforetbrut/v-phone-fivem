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
import random
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


# ── Struck metal ───────────────────────────────────────────────────────────────
# The payphone's keys are milled chrome on a steel chassis, and a sine wave cannot sound
# like that however you tune it. Two things separate metal from a beep:
#
#   1. the partials are INHARMONIC. A struck plate's modes are not integer multiples of a
#      fundamental, and that mismatch is exactly what the ear reads as "metal" rather than
#      "note". These are the free-bar ratios.
#   2. the sound starts with a broadband IMPACT - the mechanical contact - a few
#      milliseconds of noise before any ringing at all.
#
# Higher modes also shed energy faster than low ones, which is why each partial gets its
# own decay rather than sharing one envelope.
METAL_RATIOS = (1.00, 2.76, 5.40, 8.93, 13.34)

# `base` sets the pitch of the clack, `tilt` how quickly it dies: a bigger tilt is a duller,
# deader button. The delete key is deliberately lower and duller than a digit.
# The bases are deliberately low for what is a small button. The pitch you hear is the whole
# inharmonic cluster, not the fundamental, and at 22 kHz a high base pushes every partial above
# 5.40x past Nyquist - which leaves one lonely sine, i.e. a beep again. Low base, four partials.
CLICKS = {
    'boothkey':     {'base': 1150, 'length': 0.050, 'noise': 0.0040, 'noise_gain': 0.42, 'tilt': 1.00},
    # Lower and deader than a digit, but not so damped that its upper modes vanish - strip
    # those and a metal button starts sounding like a wood block.
    'boothkeyback': {'base': 900,  'length': 0.064, 'noise': 0.0055, 'noise_gain': 0.50, 'tilt': 1.16},
}


def render_click(spec):
    """One press of a chrome button, from the impact to the last of the ring."""
    length = spec['length']
    total = int((length + 0.02) * RATE)
    buf = [0.0] * total

    # Seeded, so a rebuild produces a byte-identical file. A sound that changes every time
    # the script runs is a sound nobody can diff.
    rng = random.Random(0x5EED)

    # The impact: the button bottoming out against the plate.
    noise_len = spec['noise']
    for i in range(int(noise_len * RATE)):
        t = i / RATE
        buf[i] += rng.uniform(-1.0, 1.0) * math.exp(-t / (noise_len * 0.42)) * spec['noise_gain']

    # The ring.
    count = int(length * RATE)
    for n, ratio in enumerate(METAL_RATIOS):
        freq = spec['base'] * ratio
        # Above roughly nine tenths of Nyquist a partial only aliases back down as grit.
        if freq > RATE * 0.47:
            break
        # The upper modes have to stay AUDIBLE. Rolling them off steeply leaves a single sine
        # doing all the work, and one sine is a beep no matter how it is tuned - the whole
        # point is hearing several partials that do not belong to one harmonic series.
        gain = 1.0 / (1.0 + n * 0.45)
        # Still shorter for each higher mode, as real metal does, but not so short that the
        # mode is over before the ear registers it. The third partial matters most: at 5.40x
        # it sits nowhere near any harmonic, so it is the one that settles the question of
        # whether this reads as struck metal or as a slightly detuned note.
        tau = (length / (2.4 + n * 1.1)) / spec['tilt']
        for i in range(count):
            t = i / RATE
            # A half-millisecond attack: percussive, but without the DC step that a partial
            # starting at full amplitude would put at the front of the file.
            attack = min(1.0, t / 0.0005)
            buf[i] += math.sin(2 * math.pi * freq * t) * math.exp(-t / tau) * gain * attack * 0.5

    # Lower than the tonal files land at, and deliberately so. These are sharp transients, and
    # a transient normalised close to full scale at 22 kHz OVERSHOOTS past 1.0 when the browser
    # resamples it to 44.1 kHz - measured at 0.99 from a 0.82 file. The headroom is for the
    # interpolator, not for the ear.
    peak = max((abs(s) for s in buf), default=0.0)
    if peak > 0:
        buf = [s * (0.72 / peak) for s in buf]
    return buf


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

    # The struck-metal clicks have their own renderer, so they are written separately. They
    # are interface sounds all the same, hence the ui_ prefix.
    for name, spec in CLICKS.items():
        size = write('ui_' + name, render_click(spec))
        total += size
        print('%-18s %6.1f KB' % ('ui_' + name + '.wav', size / 1024))

    print('%d files, %.1f KB total' % (
        len(RINGTONES) + len(ALERTS) + len(UI) + len(CLICKS), total / 1024))


if __name__ == '__main__':
    main()
