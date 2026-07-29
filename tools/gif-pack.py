# -*- coding: utf-8 -*-
"""Build the starter GIF library that ships in config.lua.

    python tools/gif-pack.py            # print the Lua block
    python tools/gif-pack.py --write    # replace the block in config.lua
    python tools/gif-pack.py --check    # only verify what is already in config.lua

Why this exists rather than a list somebody pasted once: every URL in that block is a link to
somebody else's CDN, and links rot. A hand-written list decays silently into a grid of broken
tiles that nobody can tell from an empty one. This asks for the pictures, checks each answer is
really an image and really small, and writes only what passed - so refreshing the library is one
command instead of an afternoon.

`--check` is the half worth running on an existing checkout: it says which shipped URLs have
stopped answering, without changing anything.

Nothing here needs an API key. These are plain media links off a public CDN, the same kind the
wallpaper list already carries, and no credential is read, stored or written.
"""
from __future__ import print_function

import io
import os
import re
import sys

try:                                        # py3
    from urllib.request import Request, urlopen
except ImportError:                         # py2
    from urllib2 import Request, urlopen

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG = os.path.join(ROOT, 'config.lua')

UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
TIMEOUT = 14

# The categories, and what to ask for. Keys are what the phone shows as a tab; the search terms
# are only used while building and never ship.
#
# Chosen for what people actually send each other on a server: an answer, a reaction, and the
# handful of things a city has that a chat app does not know about.
WANTED = [
    ('hello',    'hello wave',        6),
    ('yes',      'thumbs up yes',     6),
    ('no',       'nope no way',       6),
    ('haha',     'laughing hard',     6),
    ('love',     'heart love',        6),
    ('sad',      'crying sad',        6),
    ('angry',    'angry mad',         6),
    ('wow',      'shocked surprised', 6),
    ('ok',       'ok hand fine',      6),
    ('please',   'begging please',    6),
    ('waiting',  'still waiting',     6),
    ('bye',      'goodbye leaving',   6),
    ('dance',    'dancing party',     6),
    ('money',    'money cash',        6),
    ('police',   'police siren',      6),
    ('car',      'driving car',       6),
    ('cheers',   'cheers drink',      6),
    ('shrug',    'shrug i dont know', 6),
]

MAX_BYTES = 900 * 1024      # a GIF in a text bubble, not a film
MIN_BYTES = 3 * 1024        # below this it is a spacer or an error page


def get(url, headers=None):
    req = Request(url, headers=dict({'User-Agent': UA}, **(headers or {})))
    return urlopen(req, timeout=TIMEOUT)


def candidates(term):
    """Media URLs advertised on a public search page, best first, de-duplicated."""
    url = 'https://tenor.com/search/%s-gifs' % term.replace(' ', '-')
    try:
        page = get(url).read().decode('utf-8', 'replace')
    except Exception as exc:                                   # noqa: BLE001
        print('  ! could not read the %s page: %s' % (term, exc))
        return []
    found = re.findall(r'https://media[0-9]*\.tenor\.com/[A-Za-z0-9_-]+/[^"\'\\ ]+?\.gif', page)
    seen, out = set(), []
    for u in found:
        if u in seen:
            continue
        seen.add(u)
        out.append(u)
    return out


def usable(url):
    """True only if that URL really answers with a GIF of a sensible size.

    Asked with a real GET rather than a HEAD: a CDN that answers HEAD with a 200 and a GET with
    a redirect to an error page would pass a HEAD check and ship a broken tile.
    """
    try:
        r = get(url)
        kind = (r.headers.get('Content-Type') or '').lower()
        if 'image/gif' not in kind:
            return False
        blob = r.read(MAX_BYTES + 1)
    except Exception:                                          # noqa: BLE001
        return False
    if len(blob) > MAX_BYTES or len(blob) < MIN_BYTES:
        return False
    # A GIF starts GIF87a or GIF89a. Content-Type is what a server claims; this is what it sent.
    return blob[:3] == b'GIF'


def build():
    packs = []
    for key, term, want in WANTED:
        picked = []
        for url in candidates(term):
            if len(picked) >= want:
                break
            if usable(url):
                picked.append(url)
        print('  %-9s %d/%d' % (key, len(picked), want))
        if picked:
            packs.append((key, picked))
    return packs


def lua(packs):
    lines = []
    for key, urls in packs:
        lines.append('            { key = %r, gifs = {' % key)
        for u in urls:
            lines.append("                '%s'," % u)
        lines.append('            } },')
    return '\n'.join(lines).replace("'", "'")


def span(text):
    """Where the pack list starts and ends, by matching braces rather than by pattern.

    **This was a regex once, and it deleted two unrelated config sections.** `packs = \\{\\n`
    followed by a lazy `.*?\\n        \\}` looks like it finds the end of the block; it does not,
    because the opening group ate the newline, so the closing pattern had to find the NEXT line
    starting with eight spaces and a brace - which was several hundred lines further down,
    inside a different table. Everything between went out with the substitution.

    Counting braces cannot make that mistake. Strings are stepped over so an apostrophe or a
    brace inside a URL is not read as structure.
    """
    start = text.find('packs = {')
    if start < 0:
        return None
    i = text.index('{', start)
    depth, quote, j = 0, None, i
    while j < len(text):
        c = text[j]
        if quote:
            if c == '\\':
                j += 2
                continue
            if c == quote:
                quote = None
        elif c in '"\'':
            quote = c
        elif c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return i + 1, j
        j += 1
    return None


def check():
    text = io.open(CONFIG, encoding='utf-8').read()
    at = span(text)
    if not at:
        sys.exit('no GIF pack block found in config.lua')
    urls = re.findall(r"'(https://[^']+\.gif)'", text[at[0]:at[1]])
    if not urls:
        sys.exit('the GIF pack block holds no URLs')
    bad = [u for u in urls if not usable(u)]
    print('%d checked, %d no longer answer with a GIF' % (len(urls), len(bad)))
    for u in bad:
        print('  dead  %s' % u)
    return 1 if bad else 0


def write(packs):
    text = io.open(CONFIG, encoding='utf-8').read()
    at = span(text)
    if not at:
        sys.exit('no GIF pack block found in config.lua - add the marker first')
    before, after = text[:at[0]], text[at[1]:]
    out = before + '\n' + lua(packs) + '\n        ' + after

    # Everything outside the pack list must come through untouched. Checked rather than assumed:
    # the previous version of this function was also certain it only rewrote one block.
    old_outside = before + after
    new_at = span(out)
    if not new_at:
        sys.exit('refusing to write: the new pack list cannot be found again')
    if out[:new_at[0]] + out[new_at[1]:] != old_outside:
        sys.exit('refusing to write: this would have changed config.lua outside the pack list')

    io.open(CONFIG, 'w', encoding='utf-8', newline='').write(out)
    print('config.lua updated: %d categories, rest of the file unchanged' % len(packs))


if __name__ == '__main__':
    if '--check' in sys.argv:
        sys.exit(check())
    print('asking for %d categories' % len(WANTED))
    got = build()
    total = sum(len(u) for _, u in got)
    print('%d categories, %d pictures' % (len(got), total))
    if '--write' in sys.argv:
        write(got)
    else:
        print('')
        print(lua(got))
