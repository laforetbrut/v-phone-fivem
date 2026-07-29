#!/usr/bin/env python3
"""Prepare recorded fight sounds for the phone.

    python tools/make-brawl-sounds.py "C:/path/to/your/recordings"

Takes `brawl_<name>.wav` from a folder of raw recordings and writes them into `sounds/`, ready
to play. Re-run it whenever a sound is re-recorded; it never edits the originals.

**The leading silence is the whole reason this exists.** Every take starts with the moment
between pressing record and making the sound - between a third of a second and a full second in
the recordings this was written for. In a game where the punch is drawn the instant the round
resolves, that silence is the punch landing late, and no amount of tuning the animation fixes a
sound that begins after it. It is cut here rather than by hand, so it stays cut the next time.

What it does to each file, in order:

  1. trims silence off the front, so the sound starts on its first sample;
  2. trims silence off the end, so nothing overlaps what comes next - `hit` and `hurt` play
     160 ms apart, and a two-second take would still be going during the following round;
  3. caps the length, per sound: an action is a beat, a win is a moment;
  4. fades the last 40 ms, because a hard cut is a click;
  5. mixes to mono - it is a phone, and it halves the file;
  6. normalises loudness, so the quietest take is not lost under the loudest.

Needs ffmpeg on PATH.
"""

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, 'sounds')

# How long each one may run. An action is a beat; the end of a fight is allowed a moment.
# Generous rather than tight: these are somebody's performance, and clipping the character out
# of a sound to save a tenth of a second is a bad trade.
LIMIT = {
    'jab': 0.8, 'heavy': 0.9, 'block': 0.8, 'grab': 0.9,
    'hit': 0.9, 'hurt': 1.0,
    'win': 1.8, 'lose': 1.8,
    'bell': 0.9,
}

# The floor that counts as silence. -45 dB is below a quiet room and above a held breath, which
# is the line that matters: a take that begins with an intake of breath should keep it.
NOISE_FLOOR = '-45dB'


def have_ffmpeg():
    try:
        return subprocess.run(['ffmpeg', '-version'], shell=True,
                              capture_output=True).returncode == 0
    except OSError:
        return False


def duration(path):
    r = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration',
                        '-of', 'csv=p=0', path], shell=True, capture_output=True, text=True)
    try:
        return float(r.stdout.strip())
    except ValueError:
        return 0.0


def convert(src, dst, cap):
    chain = ','.join([
        # Front, then back. `areverse` twice is how `silenceremove` is made to work on the tail
        # as well - it only ever trims the start of the stream it is given.
        'silenceremove=start_periods=1:start_silence=0:start_threshold=%s' % NOISE_FLOOR,
        'areverse',
        'silenceremove=start_periods=1:start_silence=0:start_threshold=%s' % NOISE_FLOOR,
        'areverse',
        'atrim=0:%.3f' % cap,
        # A hard cut is a click. Faded over the last 40 ms of whatever length survived.
        'afade=t=out:st=%.3f:d=0.04' % max(0.0, cap - 0.04),
        'loudnorm=I=-16:TP=-1.5:LRA=11',
        'aresample=48000',
    ])
    r = subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', src,
                        '-af', chain, '-ac', '1', '-c:a', 'pcm_s16le', dst],
                       shell=True, capture_output=True, text=True)
    return r.returncode == 0, r.stderr.strip()[:200]


def main():
    if len(sys.argv) < 2:
        sys.exit('usage: python tools/make-brawl-sounds.py "<folder of recordings>"')
    src_dir = sys.argv[1]
    if not os.path.isdir(src_dir):
        sys.exit('no such folder: ' + src_dir)
    if not have_ffmpeg():
        sys.exit('no ffmpeg on PATH')

    os.makedirs(OUT, exist_ok=True)
    done, missing = 0, []

    for name in sorted(LIMIT):
        src = os.path.join(src_dir, 'brawl_%s.wav' % name)
        if not os.path.isfile(src):
            missing.append(name)
            continue
        dst = os.path.join(OUT, 'brawl_%s.wav' % name)
        before = duration(src)
        ok, err = convert(src, dst, LIMIT[name])
        if not ok:
            print('  FAIL %-6s %s' % (name, err))
            continue
        after = duration(dst)
        kb = os.path.getsize(dst) // 1024
        print('  %-6s %5.2fs -> %4.2fs  %4d KB' % (name, before, after, kb))
        done += 1

    print('')
    print('%d sound(s) written to sounds/' % done)
    if missing:
        # Named rather than counted: a fight is missing exactly these, and each one falls back
        # to a synthesised note rather than to silence.
        print('not found (the game will use its synthesised note for these): '
              + ', '.join(missing))


if __name__ == '__main__':
    main()
