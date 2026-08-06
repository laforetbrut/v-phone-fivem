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

    # ── The soft ones ──────────────────────────────────────────
    # Written for the renderer above rather than for the old one: long notes that overlap, a
    # pentatonic set so no two of them can clash however they land, and no note below 500 Hz -
    # a phone speaker cannot reproduce the low ones and only rattles trying.

    # Rising, unresolved, and it never lands on the note it is heading for. The most
    # answerable ringtone here: it asks a question rather than making a demand.
    'drift':   [(587, 0.00, .60), (784, .30, .60), (880, .60, .60), (1175, .90, .90),
                (587, 1.60, .60), (784, 1.90, .60), (880, 2.20, .60), (1319, 2.50, 1.10)],
    # Two notes a fifth apart, sounded together and left to ring. Nothing else. This is the
    # one to choose for a phone that should be noticed without being answered in a panic.
    'still':   [(659, 0.00, 1.20), (988, 0.06, 1.20),
                (659, 1.70, 1.20), (988, 1.76, 1.40)],
    # A falling pentatonic run. Fast enough to read as a phone ringing, soft enough that the
    # notes blur into each other rather than arriving as five separate events.
    'cascade': [(1319, 0.00, .34), (1175, .16, .34), (988, .32, .34), (784, .48, .34),
                (659, .64, .70),
                (1319, 1.40, .34), (1175, 1.56, .34), (988, 1.72, .34), (784, 1.88, .34),
                (659, 2.04, .80)],
}

ALERTS = {
    'ping': [(1568, 0.00, .18), (2093, .07, .26)],
    'pop':  [(880, 0.00, .09), (1320, .05, .14)],
    'tick': [(1200, 0.00, .05)],
    'note': [(1046, 0.00, .12), (1568, .09, .20)],

    # ── The soft ones ──────────────────────────────────────────
    # One event, two notes at most, and both of them left ringing. An alert is heard dozens of
    # times an evening and it is the sound that decides whether a phone is pleasant to carry.

    # A rising fourth, quiet and open. The default anybody should be happy leaving alone.
    'breeze': [(1175, 0.00, .26), (1568, .10, .44)],
    # A single note with its octave under it, which is as close to "a nudge" as a tone gets.
    'hush':   [(1568, 0.00, .34), (784, 0.00, .30)],
    # Down rather than up: a falling interval reads as "something arrived" where a rising one
    # reads as "something needs you".
    'soften': [(1568, 0.00, .20), (1319, .08, .40)],
}

# ── The emergency alert ────────────────────────────────────────────────────────
# Not a notification. This is the one sound on the phone that is meant to be alarming, for a
# staff broadcast about something happening to the whole city.
#
# It is the **WEA attention signal**: 853 Hz and 960 Hz sounded TOGETHER, which is what every
# emergency alert on a real phone uses. The two tones are close enough to beat against each
# other rather than blend, and that roughness is the entire design - it is deliberately not a
# pleasant interval, because a pleasant interval is one people learn to ignore. Two bursts, as
# the standard specifies, so it reads as a signal rather than as a phone ringing.
#
# Both partials are written at full weight and the render normalises the sum, so this lands
# louder than any other sound the phone makes - which is the point.
EMERGENCY = {
    'emergency': [
        (853, 0.00, .90), (960, 0.00, .90),
        (853, 1.00, .90), (960, 1.00, .90),
    ],
    # The 911 app's alert, for the service being called out.
    #
    # Deliberately NOT the wireless-alert pair above. That one is a warning to a whole city
    # and it is meant to be alarming; this one lands on the phone of somebody at work, over
    # and over, all evening. It has to be unmistakable on the first note and bearable on the
    # fiftieth - so it is the two-tone European siren interval, played briefly and clean,
    # rather than a klaxon.
    #
    # A 435/580 Hz pair is a perfect fourth: it reads as "signal" rather than as music, which
    # is exactly what a dispatch tone is for.
    'alert911': [
        (580, 0.00, .26), (435, 0.24, .26),
        (580, 0.50, .26), (435, 0.74, .34),
    ],
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
    """A soft attack, then a long exponential tail.

    **The attack is a raised cosine, not a ramp.** A linear ramp reaches full amplitude with a
    corner in it, and a corner is a click - which is what every note on this phone started
    with. `(1 - cos(pi x)) / 2` leaves and arrives with zero slope, so the note fades in
    instead of switching on. Eighteen milliseconds: long enough to hear as soft, short enough
    that the note still lands on the beat.

    The decay is gentler too. `exp(-4.2 x)` is down 65 dB at the end of the note, which reads
    as a pluck; `exp(-3.0 x)` leaves the tail audible into the note that follows, and notes
    that overlap are most of what makes a phone tone sound expensive.
    """
    attack = min(0.018, length * 0.35)
    if pos < attack:
        return (1.0 - math.cos(math.pi * pos / attack)) * 0.5
    remaining = (pos - attack) / max(1e-6, length - attack)
    return math.exp(-3.0 * remaining)


def space(buffer, amount=0.16, delay=0.055, taps=4):
    """A small room around the tone.

    Not a reverb in any serious sense - four feedback taps, each quieter and later than the
    last. That is enough to stop a note sounding like it was recorded pressed against a wall,
    and it is what separates a FruitOS tone from a beep more than any amount of tuning does.

    In place would be wrong: a tap must read the DRY signal, or each one feeds the next and the
    tail turns to mush.
    """
    if amount <= 0:
        return buffer
    out = list(buffer)
    step = int(delay * RATE)
    if step <= 0:
        return out
    for tap in range(1, taps + 1):
        gain = amount * (0.55 ** (tap - 1))
        offset = step * tap
        for i in range(len(buffer) - offset):
            out[i + offset] += buffer[i] * gain
    return out


def render(score, tail=0.25, peak_at=0.82, room=0.16, edge=0.0):
    """A score to a list of samples.

    **The harmonic stack is what decides whether a tone is soft or sharp**, and the old one was
    sharp: a second harmonic at 0.20 for body, and a THIRD at 0.08. The third harmonic is the
    twelfth - an octave and a fifth up - and it is the partial the ear reads as edge. It is
    gone. What is left is the octave, quieter than before, plus a trace of the double octave,
    which reads as air rather than as bite.

    `edge` puts some of it back for the two sounds that are supposed to cut through: the
    wireless emergency signal and the 911 dispatch tone. Softening those would be a bug, not a
    feature - they are alarms.

    `peak_at` is the ceiling. A notification at the same level as a ringtone is a notification
    that startles somebody wearing headphones, so the families land at different heights.
    """
    duration = max(start + length for _, start, length in score) + tail
    total = int(duration * RATE)
    buffer = [0.0] * total

    for freq, start, length in score:
        first = int(start * RATE)
        # The note is written PAST its nominal length, so its tail decays into what follows
        # instead of being cut off at the note boundary. That overlap is most of the softness.
        count = int(min(length * 2.2, length + 0.45) * RATE)
        for i in range(count):
            index = first + i
            if index >= total:
                break
            t = i / RATE
            amp = envelope(t, length)
            # Below about a thousandth of full scale nothing is audible and the remaining
            # samples are pure arithmetic. On a two-second ringtone that is most of them.
            if t > length and amp < 0.001:
                break
            sample = (
                math.sin(2 * math.pi * freq * t)
                + 0.14 * math.sin(4 * math.pi * freq * t)
                + 0.03 * math.sin(8 * math.pi * freq * t)
                + edge * math.sin(6 * math.pi * freq * t)
            )
            buffer[index] += sample * amp * 0.32

    buffer = space(buffer, room)

    # One pass of normalisation per file, so a server does not have to trim the volume per
    # ringtone - and a per-family ceiling, so an alert is quieter than a ring.
    peak = max((abs(s) for s in buffer), default=0.0)
    if peak > 0:
        scale = peak_at / peak
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
    # tail, peak, room, edge - per family, because they are not the same kind of sound.
    #
    #   ringtones  loud, and in a room. They play across a street.
    #   alerts     QUIETER than a ring by 6 dB. This one arrives while somebody is wearing
    #              headphones, and it is the sound the phone makes most often.
    #   interface  quieter still, and almost dry. A tap that echoes is a tap that lags.
    #   emergency  loudest, driest, and with the edge harmonic put back. It is an alarm.
    for group, tail, peak, room, edge in (
            (RINGTONES, 0.70, 0.86, 0.20, 0.0),
            (ALERTS, 0.40, 0.62, 0.14, 0.0),
            (UI, 0.28, 0.52, 0.06, 0.0),
            (EMERGENCY, 0.30, 0.94, 0.02, 0.10)):
        for name, score in group.items():
            prefix = ('ring_' if group is RINGTONES
                      else 'alert_' if group is ALERTS
                      else 'ui_' if group is UI else 'ui_')
            size = write(prefix + name, render(score, tail, peak, room, edge))
            total += size
            print('%-18s %6.1f KB' % (prefix + name + '.wav', size / 1024))

    # The struck-metal clicks have their own renderer, so they are written separately. They
    # are interface sounds all the same, hence the ui_ prefix.
    for name, spec in CLICKS.items():
        size = write('ui_' + name, render_click(spec))
        total += size
        print('%-18s %6.1f KB' % ('ui_' + name + '.wav', size / 1024))

    print('%d files, %.1f KB total' % (
        len(RINGTONES) + len(ALERTS) + len(UI) + len(EMERGENCY) + len(CLICKS), total / 1024))


if __name__ == '__main__':
    main()
