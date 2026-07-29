#!/usr/bin/env python3
"""Build a browser preview of the phone from the real source and the real config.

The phone is a NUI page: in game it talks to the FiveM client over `fetch` and is handed its
state by a `postMessage`. Neither exists in a browser, so `html/app.js` carries a hook for
exactly this - `window.__VPHONE_PREVIEW_POST__` - which intercepts every callback and lets
something else answer.

This writes `preview/index.html`: the same markup, the same `html/` assets, the same
`config.lua` and the same `locales/en.lua` the resource ships. Nothing is a mock-up of the
phone - it IS the phone, wired to a table of deterministic replies instead of a server.

**It boots the way a fresh install boots.** The app list is built from `Config.Apps` with the
same module gates the server applies, so an app that would be hidden on a bare install is
hidden here too - the Music app, for instance, until a deck is installed. The test panel down
the side is how you turn those on and drive everything else.

    python tools/make-preview.py
    # then open preview/index.html in any browser

`preview/` is gitignored: it is generated, and rebuilt whenever the source moves.
"""

import json
import os
import shutil
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, 'preview')


def lua_world():
    """config.lua and both locale files, loaded from source."""
    from lupa import lua54
    lua = lua54.LuaRuntime()
    # config.lua uses vec3 for the charger and dead-zone coordinates.
    lua.execute('function vec3(x,y,z) return {x=x,y=y,z=z} end '
                'function vector3(x,y,z) return {x=x,y=y,z=z} end '
                'Locales = { en = {}, fr = {} }')
    for path in ('config.lua', 'locales/en.lua', 'locales/fr.lua'):
        with open(os.path.join(ROOT, path), encoding='utf-8') as f:
            lua.execute(f.read())
    return lua


def plain(value):
    """A Lua table as ordinary Python. Sequences become lists, maps become dicts."""
    if not hasattr(value, 'items'):
        return value
    keys = list(value.keys())
    if keys and all(isinstance(k, int) for k in keys) and keys == list(range(1, len(keys) + 1)):
        return [plain(v) for v in value.values()]
    return {str(k): plain(v) for k, v in value.items()}


def markup():
    """Everything inside <body> of the real page, so the preview cannot drift from it."""
    with open(os.path.join(ROOT, 'html', 'index.html'), encoding='utf-8') as f:
        html = f.read()
    body = re.search(r'<body[^>]*>(.*)</body>', html, re.S)
    if not body:
        raise SystemExit('could not find <body> in html/index.html')
    # The scripts are re-added below, after the harness has been defined.
    return re.sub(r'<script[^>]*>.*?</script>', '', body.group(1), flags=re.S)


# ── Which apps a fresh install actually shows ─────────────────────────────────
# The server hides an app whose owning module is not running. On a bare install the
# compatibility shims answer for most of them; `v-music` is the one that stays off until a
# music deck is installed, and `v-police` needs the job list to be non-empty.
def live_modules(cfg):
    compat = cfg.get('Compat', {})
    modules = compat.get('modules', {})
    return {
        'v-phone': True, 'v-core': True, 'v-ui': True, 'v-world': True,
        'v-banking': True, 'v-status': True, 'v-inventory': True,
        'v-police': len(compat.get('policeJobs', [])) > 0,
        'v-music': False,     # no deck on a fresh install; the panel turns it on
        'v-housing': modules.get('v-housing') is not False,
        'v-vehicles': modules.get('v-vehicles') is not False,
        'v-licenses': modules.get('v-licenses') is not False,
        'v-cityhall': modules.get('v-cityhall') is not False,
    }


def catalogue(cfg):
    """The app list, built from Config.Apps exactly as the server builds it."""
    live = live_modules(cfg)
    meta = cfg.get('AppMetadata', {})
    out = []
    for a in cfg.get('Apps', []):
        owner = a.get('owner') or 'v-phone'
        if not live.get(owner, False):
            continue
        row = dict(a)
        extra = meta.get(a.get('id'), {})
        row['features'] = extra.get('features')
        row['keywords'] = extra.get('keywords')
        row['owner'] = owner
        out.append(row)
    for a in cfg.get('StoreApps', []):
        row = dict(a)
        row['optional'] = True
        row['owner'] = 'v-phone'
        row['purchased'] = not row.get('price')
        out.append(row)
    out.sort(key=lambda r: (r.get('slot') or 99, r.get('id') or ''))
    return out


def build():
    lua = lua_world()
    cfg = plain(lua.globals().Config)
    # Which language the preview speaks.
    #
    #     python tools/make-preview.py --lang fr
    #
    # English by default because that is what the tools read when they check a screen. The
    # README's screenshots are French, and retaking one in the wrong language is a picture that
    # does not match the nine beside it - which is why this is a flag rather than an edit.
    lang = 'fr' if '--lang' in sys.argv and sys.argv[sys.argv.index('--lang') + 1] == 'fr' else 'en'
    S = plain(getattr(lua.globals().Locales, lang))

    apps = catalogue(cfg)
    installed = [a for a in apps if not a.get('optional')]

    booth = cfg.get('Booth', {})
    music = cfg.get('Music', {})
    remote = cfg.get('VehicleRemote', {})

    boot = {
        'ok': True, 'number': '555-0142', 'locale': lang, 'name': 'Alex Mercer',
        'power': {'battery': 76, 'charging': False, 'signal': 4},
        'strings': S,
        'apps': installed,
        'available': apps,
        'wallpapers': cfg.get('Wallpapers', ['ifruit']),
        'sounds': {'ringtones': cfg.get('Sounds', {}).get('ringtones', []),
                   'alerts': cfg.get('Sounds', {}).get('alerts', [])},
        'soundFiles': False,
        'customWallpaper': True,
        'allowAnonymous': bool(cfg.get('Settings', {}).get('anonymous')),
        'vehicleControls': remote.get('controls', {}) if remote.get('enabled') else {},
        'vehicleNeons': remote.get('neonColours', []),
        'prefs': {
            'setupComplete': True, 'setupVersion': 2, 'securityEnabled': False, 'faceId': False,
            'ownerName': 'Alex Mercer', 'deviceName': "Alex's iFruit",
            'wallpaper': cfg.get('DefaultWallpaper', 'ifruit'),
            'glass': cfg.get('DefaultGlass', 42), 'darkMode': 'dark', 'dark': True,
            'gridCols': 4, 'gridRows': 4, 'ringVolume': 0.7, 'vibrate': True,
            'ringtone': (cfg.get('Sounds', {}).get('ringtones') or ['classic'])[0],
            'alertTone': (cfg.get('Sounds', {}).get('alerts') or ['ping'])[0],
            'brightness': 1, 'cellular': True, 'wifi': True, 'bluetooth': False,
            'airplane': False, 'dnd': False, 'notifMuted': [], 'removed': [], 'added': [],
            'purchased': [], 'hideNumber': False, 'silenceUnknown': False,
            'previews': True, 'peek': True, 'size': 1, 'side': 'right',
        },
        'contacts': [
            # One contact with a picture, so the avatar that draws a photograph is
            # exercised alongside the two that fall back to an initial.
            {'id': 1, 'name': 'Mara Ortiz', 'number': '555-0188', 'favourite': 1,
             'photo': 'https://picsum.photos/seed/mara/160'},
            {'id': 2, 'name': 'Deputy Vance', 'number': '555-0110'},
            {'id': 3, 'name': 'Ray (Garage)', 'number': '555-0164'},
        ],
        'conversations': [
            {'number': '555-0188', 'name': 'Mara Ortiz', 'body': 'On my way, five minutes.',
             'at': '2026-07-25 21:40', 'unread': 2},
            {'number': '555-0164', 'name': 'Ray (Garage)', 'body': 'Car is ready when you are.',
             'at': '2026-07-25 20:12', 'unread': 0},
        ],
        'calls': [
            {'number': '555-0188', 'direction': 'in', 'answered': 1, 'at': '2026-07-25 21:05'},
            {'number': '555-0110', 'direction': 'out', 'answered': 1, 'at': '2026-07-25 18:22'},
        ],
        'job': {'name': 'mechanic', 'label': 'Mechanic', 'grade': 2, 'gradeLabel': 'Senior'},
    }

    # **Fixture images are placeholders on purpose.** A URL on a real media host carries the
    # account or bucket identifier of whoever uploaded it, and this file is published. Use
    # picsum.photos, example.invalid or your-cdn.tld - never a bucket that belongs to somebody.
    replies = {
        'refresh': dict(boot, ok=True),
        'ambient': {'ok': True, 'hours': 21, 'minutes': 40, 'weather': 'CLEAR'},
        # The widget strip. `w` carries the server-backed tiles; the rest of them are drawn
        # from what the page already holds and are not in here on purpose - a fixture for one
        # of those would be testing the fixture rather than the widget.
        'widgets': {'ok': True, 'at': 1785000000,
                    'ambient': {'hours': 21, 'minutes': 40, 'weather': 'CLEAR'},
                    'w': {
                        'bank': {'ok': True, 'masked': True},
                        'vitals': {'ok': True, 'hunger': 62, 'thirst': 48, 'stress': 14},
                        'garage': {'ok': True, 'n': 4, 'out': 1,
                                   'first': {'name': 'Sultan RS', 'plate': 'V-PHONE',
                                             'live': True}},
                        'reminders': {'ok': True, 'due': 1, 'someday': 2,
                                      'text': 'Passer au garage', 'list': 'personal',
                                      'dueAt': 1785001800},
                        'export': {'ok': True, 'market': 'export', 'moved': 3,
                                   'shop': 'Export', 'item': 'Or', 'price': 1240,
                                   'percent': 12.4},
                        'alerts': {'ok': True, 'n': 2, 'category': 'road',
                                   'title': 'Pont de Del Perro ferme',
                                   'emitter': 'LSPD', 'expiresAt': 1785003600},
                    }},
        'calls': {'ok': True, 'calls': boot['calls']},
        'conversation': {'ok': True, 'messages': [
            {'body': 'Are you around tonight?', 'outgoing': False, 'at': '2026-07-25 21:31'},
            {'body': 'Yeah, at the garage until nine.', 'outgoing': True, 'at': '2026-07-25 21:35'},
            {'body': 'On my way, five minutes.', 'outgoing': False, 'at': '2026-07-25 21:40'},
        ]},
        'app:bank': {'ok': True, 'cash': 1240, 'bank': 18650, 'transactions': [
            {'label': 'Tuner Shop', 'amount': -450, 'at': '2026-07-25 20:10'},
            {'label': 'Wages', 'amount': 2200, 'at': '2026-07-25 12:00'}]},
        'app:fruitee': {'ok': True,
            'limits': {'minGift': 1, 'maxGift': 100000, 'goalMax': 1000000, 'maxTiers': 4,
                       'payoutMin': 1,
                       'taxes': [{'key': 'platform', 'percent': 5},
                                 {'key': 'government', 'percent': 25}],
                       'taxTotal': 30,
                       'messages': True, 'anonymous': True,
                       'categories': ['community', 'medical', 'business', 'memorial',
                                      'event', 'other']},
            'page': {'id': 1, 'slug': 'pierrepair', 'title': 'Rebuild the pier stall',
                     'blurb': 'The storm took the roof off. We are putting it back up before '
                              'the weekend market.',
                     'cover': 'https://picsum.photos/seed/cover1/480/270',
                     'avatar': 'https://picsum.photos/seed/avatar1/480/270',
                     'category': 'community', 'goal': 12000, 'raised': 7400, 'gifts': 23,
                     'tiers': [{'amount': 25, 'label': 'A plank'},
                               {'amount': 100, 'label': 'A beam'},
                               {'amount': 500, 'label': 'The roof'}],
                     'anon': True, 'msgs': True, 'closed': False,
                     'owner': 'Alex Mercer', 'mine': True, 'ts': 1753900000},
            'balance': 6660,
            'gifts': [
                {'id': 3, 'amount': 500, 'body': 'For the roof. Good luck.',
                 'anon': False, 'name': 'Mara Ortiz', 'ts': 1753900000},
                {'id': 2, 'amount': 100, 'body': '', 'anon': True, 'ts': 1753890000},
                {'id': 1, 'amount': 25, 'body': 'A plank from me.',
                 'anon': False, 'name': 'Ray Boone', 'ts': 1753880000},
            ],
            'discover': [
                {'id': 1, 'slug': 'pierrepair', 'title': 'Rebuild the pier stall',
                 'blurb': 'The storm took the roof off.',
                 'cover': 'https://picsum.photos/seed/cover2/480/270', 'avatar': '',
                 'category': 'community', 'goal': 12000, 'raised': 7400, 'gifts': 23,
                 'tiers': [], 'anon': True, 'msgs': True, 'closed': False,
                 'owner': 'Alex Mercer', 'mine': True},
                {'id': 2, 'slug': 'inesmeds', 'title': "Ines's hospital bill",
                 'blurb': 'Three weeks in Pillbox and counting.',
                 'cover': 'https://picsum.photos/seed/cover3/480/270', 'avatar': '',
                 'category': 'medical', 'goal': 30000, 'raised': 8100, 'gifts': 41,
                 'tiers': [], 'anon': True, 'msgs': True, 'closed': False,
                 'owner': 'Ines Fontaine', 'mine': False},
                {'id': 3, 'slug': 'tunerclub', 'title': 'Track day for the club',
                 'blurb': 'Hiring the strip for a Sunday.',
                 'cover': 'https://picsum.photos/seed/cover4/480/270', 'avatar': '',
                 'category': 'event', 'goal': 0, 'raised': 2250, 'gifts': 9,
                 'tiers': [], 'anon': True, 'msgs': True, 'closed': False,
                 'owner': 'Ray Boone', 'mine': False},
            ],
            'given': [
                {'title': "Ines's hospital bill", 'slug': 'inesmeds', 'amount': 250,
                 'body': 'Get well.', 'at': '2026-07-27 18:20'},
            ]},
        'app:onlyfruits': {'ok': True,
            'limits': {'maxPrice': 5000, 'maxSubPrice': 10000, 'maxTip': 10000,
                       'subDays': 30, 'fee': 10},
            'me': {'handle': 'alexlens', 'name': 'Alex', 'bio': 'Photos of the city at night.',
                   'followers': 128, 'subscribers': 14, 'posts': 3, 'subPrice': 750, 'me': True},
            'balance': 4320,
            'feed': [
                {'id': 11, 'handle': 'mara', 'name': 'Mara Ortiz', 'caption': 'Vinewood, 3am.',
                 'price': 0, 'ts': 1753900000,
                 'image': 'https://i.imgur.com/8Km9tLL.jpg'},
                {'id': 12, 'handle': 'mara', 'name': 'Mara Ortiz', 'caption': 'Behind the sign.',
                 'price': 250, 'ts': 1753890000, 'locked': True},
                {'id': 13, 'handle': 'ray', 'name': 'Ray', 'caption': 'Subscribers only.',
                 'price': 0, 'subsOnly': True, 'ts': 1753880000, 'locked': True},
            ],
            'discover': [
                {'handle': 'mara', 'name': 'Mara Ortiz', 'bio': 'Night photography',
                 'followers': 940, 'subPrice': 500,
                 'avatar': 'https://i.imgur.com/8Km9tLL.jpg',
                 'cover': 'https://i.imgur.com/6PLzOQI.jpg'},
                {'handle': 'ray', 'name': 'Ray', 'bio': 'Cars, mostly',
                 'followers': 210, 'subPrice': 0,
                 'avatar': 'https://i.imgur.com/HkQrJdb.jpg',
                 'cover': 'https://i.imgur.com/kFTZbDl.jpg'},
            ],
            'posts': [
                {'id': 1, 'caption': 'Free one.', 'price': 0, 'sold': 0, 'ts': 1753870000,
                 'image': 'https://i.imgur.com/8Km9tLL.jpg'},
                {'id': 2, 'caption': 'For sale.', 'price': 300, 'sold': 7, 'ts': 1753860000,
                 'image': 'https://i.imgur.com/8Km9tLL.jpg'},
            ],
            'earnings': [
                {'kind': 'sale', 'amount': 270, 'ts': 1753860000},
                {'kind': 'sub', 'amount': 675, 'ts': 1753850000},
                {'kind': 'tip', 'amount': 90, 'ts': 1753840000},
                {'kind': 'payout', 'amount': -1200, 'ts': 1753830000},
            ]},
        'app:garage': {'ok': True, 'vehicles': [
            {'plate': 'MERC 01', 'model': 'Sultan RS', 'garage': 'Legion Square', 'live': True},
            {'plate': 'RAY 447', 'model': 'Futo GTX', 'garage': 'Mission Row', 'live': False}]},
        'app:wallet': {'ok': True, 'licenses': [
            {'type': 'driver', 'label': 'Driving Licence'}, {'type': 'weapon', 'label': 'Firearms'}]},
        'app:property': {'ok': True, 'properties': [{'label': 'Mirror Park 12', 'address': 'Mirror Park'}]},
        'app:jobs': {'ok': True, 'current': 'mechanic', 'jobs': [],
                     'me': {'label': 'Mechanic', 'name': 'mechanic', 'grade': 2, 'ranks': 4,
                            'salary': 850, 'ladder': []}},
        'app:health': {'ok': True, 'health': 100, 'armour': 25, 'hunger': 70, 'thirst': 60},
        'app:music': {'ok': True, 'enabled': True, 'provider': 'xdiskjockey', 'handoff': True,
                      'sources': [], 'allowCustomUrl': music.get('allowCustomUrl', True),
                      'hosts': music.get('hosts', []),
                      'limits': {'library': music.get('maxLibrary', 120),
                                 'playlists': music.get('maxPlaylists', 20),
                                 'tracks': music.get('maxTracksPerPlaylist', 100)},
                      'playlists': [dict(p, readonly=True) for p in music.get('defaultPlaylists', [])]},
        'vehicleFind': {'ok': True, 'netId': 1, 'distance': 6},
        'vehicleControl': {'ok': True},
        'notes': {'ok': True, 'notes': [{'id': 1, 'title': 'Shift notes', 'body': 'Order brake pads.',
                                         'at': '2026-07-25 18:00'}]},
        # One Fruitee page, opened. The sheet asks for this by slug; the harness answers with
        # the same page whatever is asked, which is enough to walk the giving flow.
        'fundPage': {'ok': True,
            'page': {'id': 2, 'slug': 'inesmeds', 'title': "Ines's hospital bill",
                     'blurb': 'Three weeks in Pillbox and counting. Her family is covering '
                              'what they can and the rest is on us.',
                     'cover': 'https://picsum.photos/seed/cover5/480/270',
                     'avatar': 'https://picsum.photos/seed/avatar2/480/270',
                     'category': 'medical', 'goal': 30000, 'raised': 8100, 'gifts': 41,
                     'tiers': [{'amount': 50, 'label': 'An hour of care'},
                               {'amount': 250, 'label': 'A day'},
                               {'amount': 1000, 'label': 'A week'}],
                     'anon': True, 'msgs': True, 'closed': False,
                     'owner': 'Ines Fontaine', 'mine': False},
            'supporters': [
                {'id': 9, 'amount': 250, 'body': 'Get well soon.', 'anon': False,
                 'name': 'Mara Ortiz', 'ts': 1753900000},
                {'id': 8, 'amount': 1000, 'body': '', 'anon': True, 'ts': 1753890000},
                {'id': 7, 'amount': 50, 'body': 'From all of us at the garage.',
                 'anon': False, 'name': 'Ray Boone', 'ts': 1753880000},
            ],
            'limits': {'minGift': 1, 'maxGift': 100000, 'goalMax': 1000000, 'maxTiers': 4,
                       'payoutMin': 1,
                       'taxes': [{'key': 'platform', 'percent': 5},
                                 {'key': 'government', 'percent': 25}],
                       'taxTotal': 30,
                       'messages': True, 'anonymous': True,
                       'categories': ['community', 'medical', 'business', 'memorial',
                                      'event', 'other']}},
        'app:brawl': {'ok': True,
            'stats': {'wins': 7, 'losses': 4, 'streak': 2, 'best': 5},
            'match': None, 'invite': None, 'queued': False,
            'stakes': {'on': True, 'max': 100},
            'board': [
                {'rank': 1, 'name': 'Mara Ortiz', 'wins': 31, 'losses': 9, 'best': 12},
                {'rank': 2, 'name': 'Ray Boone', 'wins': 22, 'losses': 14, 'best': 6},
                {'rank': 3, 'name': 'Alex Mercer', 'wins': 7, 'losses': 4, 'best': 5},
            ],
            'rules': {'health': 100, 'stamina': 6, 'start': 4, 'roundSeconds': 10,
                      'regain': 2,
                      'cost': {'jab': 1, 'heavy': 3, 'block': 0, 'grab': 2}}},
        'brawlPick': {'ok': True, 'picked': 'jab'},
        'brawlSolo': {'ok': True, 'match': {
            'id': 9, 'round': 1, 'endsAt': 0,
            'me':   {'hp': 100, 'stamina': 4, 'name': 'Alex Mercer', 'picked': False},
            'them': {'hp': 100, 'stamina': 4, 'name': 'Club Fighter', 'picked': False},
            'history': []}},
        'brawlQueue': {'ok': True, 'queued': True},
        'app:flappy': {'ok': True, 'game': 'flappy', 'nick': 'ALEX', 'best': 27, 'plays': 41,
            'rank': 4,
            'board': [
                {'rank': 1, 'nick': 'MARA', 'score': 63, 'mine': False},
                {'rank': 2, 'nick': 'xX_RAY_Xx', 'score': 48, 'mine': False},
                {'rank': 3, 'nick': 'Ines', 'score': 31, 'mine': False},
                {'rank': 4, 'nick': 'ALEX', 'score': 27, 'mine': True},
                {'rank': 5, 'nick': '', 'score': 12, 'mine': False},
            ],
            'limits': {'nickMin': 2, 'nickMax': 12, 'boardSize': 25, 'maxScore': 9999}},
        'arcadeScore': {'ok': True, 'best': 27, 'beaten': False, 'rank': 4, 'board': []},
        'arcadeNick': {'ok': True, 'nick': 'ALEX'},
        'fundSlug': {'ok': True, 'free': True, 'slug': 'mypage'},
        'fundGive': {'ok': True, 'amount': 250},
        'lookup': {'ok': True},
        'places': {'ok': True, 'places': []},
        'airdropScan': {'ok': True, 'devices': []},
        'photo': {'ok': True, 'photos': []},
        # No `address` and no `error`: that is what a character with no mailbox looks like,
        # and it is what makes the app offer to create one. An `error` here short-circuits
        # RENDER.mail into an empty state instead - which is the mistake this used to make.
        # The domains are the config's own, so the picker shows what your server offers.
        'mail': {'ok': True, 'domains': cfg.get('Mail', {}).get('domains', ['ls.com'])},
        'voicemail': {'ok': True, 'list': []},
        # The payphone, opened from the test panel. These are the config's own values.
        '__booth': {'ok': True, 'number': '311-04827',
                    'brand': booth.get('brand', 'Badger'), 'credit': 437,
                    'free': (booth.get('costPerMinute') or 0) <= 0,
                    'costPerMinute': booth.get('costPerMinute', 60),
                    'minimumSeconds': booth.get('minimumSeconds', 30),
                    'cardItem': (booth.get('card') or {}).get('item'),
                    'cardSeconds': (booth.get('card') or {}).get('seconds', 600),
                    'maxDialLength': booth.get('maxDialLength', 20)},
    }

    panel_rows = [
        ('First-run setup', "PV.setup()"),
        ('Security step only', "PV.security()"),
        ('Lock the phone', "PV.send({action:'lock'})"),
        ('Incoming call', "PV.send({action:'call', call:{id:1, state:'in', number:'555-0188'}})"),
        ('Incoming message', "PV.send({action:'notify', banner:{app:'messages', icon:'messages',"
                             " title:'Mara Ortiz', body:'On my way, five minutes.'}})"),
        ('Open the payphone', "PV.send({action:'booth:open', data:PV.booth, call:null})"),
        ('Payphone: in a call', "PV.send({action:'booth:call', call:{id:3, state:'active', number:'555-0142'}})"),
        ('Police terminal', "PV.send({action:'forensic:open'})"),
        ('Install a music deck', "PV.music()"),
        ('Add a paid app', "PV.paid()"),
        ('Battery at 8%', "PV.send({action:'power', power:{battery:8, charging:false, signal:2}})"),
        ('No signal', "PV.send({action:'power', power:{battery:76, charging:false, signal:0}})"),
        ('Reset', "PV.reset()"),
    ]

    harness = """
// ── The preview harness ──────────────────────────────────────────────────────
// app.js calls this instead of fetch() when it is present, so every screen is driven by a
// fixed table. The replies come from the real config.lua, which is why the phone here boots
// the way a fresh install boots - the Music app is hidden until a deck is installed, exactly
// as it would be on your server.
//
// **Everything lives inside this closure.** app.js declares `const post` at the top level and
// so did an earlier version of this harness: two `const` of the same name in the same global
// scope is a SyntaxError, and the browser refused to parse app.js at all - the page loaded,
// the panel drew, and the phone never appeared. Nothing here touches the global scope now
// except the two names the phone and the panel actually need.
(function () {
const PREVIEW = %s;
const STORAGE = {};
let MUSIC_ON = false;
let PAID_ON = false;

const DEMO_PAID_APP = {
  id: 'taxi_meter', label: 'Taxi Meter', icon: 'car', slot: 900, category: 'work',
  owner: 'v-phone', optional: true, custom: true, developer: 'Downtown Cab Co.',
  accent: '#FFD60A', desc: 'Fares, distance and a running total for the shift.',
  features: ['Live fare', 'Shift total'], permissions: ['Location'],
  price: 250, account: 'bank', purchased: false,
};

function bootState() {
  const b = JSON.parse(JSON.stringify(PREVIEW.refresh));
  if (MUSIC_ON) {
    // The Music app's owner is v-music, which is only "started" once a deck is installed.
    const music = PREVIEW.__musicApp;
    if (music && !b.available.some((a) => a.id === 'music')) {
      b.available.push(music); b.apps.push(music);
    }
  }
  if (PAID_ON && !b.available.some((a) => a.id === DEMO_PAID_APP.id)) {
    b.available.push(DEMO_PAID_APP);
  }
  b.action = 'open';
  return b;
}

// ── The simulated server ─────────────────────────────────────────────────────
// Not a lookup table: a small stateful server. Everything you do sticks for the session -
// create a mailbox and it stays created, send a text and it lands in the thread, save a note
// and it is there when you come back, buy an app and the money leaves the bank.
//
// It is deliberately NOT a re-implementation of server/main.lua. It is the smallest thing
// that behaves the way the real one does from the page's side, so what you are testing is
// the phone rather than a second copy of the server.
const DB = {
  prefs: JSON.parse(JSON.stringify(PREVIEW.refresh.prefs)),
  contacts: JSON.parse(JSON.stringify(PREVIEW.refresh.contacts)),
  conversations: JSON.parse(JSON.stringify(PREVIEW.refresh.conversations)),
  calls: JSON.parse(JSON.stringify(PREVIEW.refresh.calls)),
  threads: JSON.parse(JSON.stringify(PREVIEW.__threads)),   // [number] = messages
  notes: [{ id: 1, title: 'Shift notes', body: 'Order brake pads.', at: '2026-07-25 18:00' }],
  mail: { address: null, inbox: [], sent: [] },
  bank: 18650,
  cash: 1240,
  boothCredit: 437,
  cards: 2,
  seq: 100,
};

const now = () => new Date().toISOString().slice(0, 16).replace('T', ' ');
const nextId = () => ++DB.seq;

function conversationRow(number) {
  const msgs = DB.threads[number] || [];
  const last = msgs[msgs.length - 1];
  const known = DB.contacts.find((c) => c.number === number);
  return { number: number, name: known ? known.name : '', body: last ? last.body : '',
           at: last ? last.at : now(), unread: 0 };
}

function refreshState() {
  const b = bootState();
  b.prefs = DB.prefs;
  b.contacts = DB.contacts;
  b.conversations = Object.keys(DB.threads).map(conversationRow);
  b.calls = DB.calls;
  return b;
}

const HANDLERS = {
  refresh: () => refreshState(),

  // Every Settings toggle goes through here. It MUST return the new prefs: the page does
  // `state.prefs = res.prefs`, so answering a bare { ok: true } wipes them and the phone
  // falls apart on the next redraw.
  prefs: (b) => { Object.assign(DB.prefs, b); return { ok: true, prefs: DB.prefs }; },

  app: (b) => {
    if (b.app === 'music' && !MUSIC_ON) return { error: 'off' };
    if (b.app === 'bank') {
      return { ok: true, cash: DB.cash, bank: DB.bank,
               transactions: PREVIEW['app:bank'].transactions };
    }
    return PREVIEW['app:' + b.app] || { error: 'off' };
  },

  // The store's ratings. Kept in a little table so posting one moves the average on screen,
  // which is the behaviour worth exercising rather than a canned reply.
  storeReviews: (b) => {
    const db = (window.__STREV__ = window.__STREV__ || {});
    const list = db[b.app] || (db[b.app] = [
      { name: 'Mara O.', stars: 5, body: 'Does exactly what it says.', ts: 1753900000 },
      { name: 'Ray B.', stars: 4, body: 'Good, drains the battery a bit.', ts: 1753880000 },
      { name: 'Sofia D.', stars: 5, body: '', ts: 1753860000 },
    ]);
    const spread = [0, 0, 0, 0, 0];
    list.forEach((r) => { spread[r.stars - 1] += 1; });
    const total = list.length;
    const avg = total ? list.reduce((n, r) => n + r.stars, 0) / total : 0;
    const mine = list.find((r) => r.mine) || null;
    return { ok: true, average: Math.round(avg * 10) / 10, count: total, spread,
             reviews: list, mine, canReview: true, maxLength: 300 };
  },
  storeReview: (b) => {
    const db = (window.__STREV__ = window.__STREV__ || {});
    const list = db[b.app] || (db[b.app] = []);
    const at = list.findIndex((r) => r.mine);
    const row = { stars: b.stars, body: b.body, ts: Math.floor(Date.now() / 1000), mine: true };
    if (at >= 0) list[at] = row; else list.unshift(row);
    return { ok: true };
  },
  storeReviewDelete: (b) => {
    const db = (window.__STREV__ = window.__STREV__ || {});
    const list = db[b.app] || [];
    const at = list.findIndex((r) => r.mine);
    if (at >= 0) list.splice(at, 1);
    return { ok: at >= 0, error: at >= 0 ? undefined : 'gone' };
  },

  fanHandle: (b) => ({ ok: true, handle: String(b.handle || '').toLowerCase(),
    free: String(b.handle || '').length >= 3 && String(b.handle || '').toLowerCase() !== 'mara',
    why: String(b.handle || '').length < 3 ? 'short' : (String(b.handle || '').toLowerCase() === 'mara' ? 'taken' : undefined) }),
  fanSetup: () => ({ ok: true }),
  fanPost: () => ({ ok: true, id: 99 }),
  fanDelete: () => ({ ok: true }),
  fanFollow: (b) => ({ ok: true, following: b.on !== false }),
  fanSubscribe: () => ({ ok: true }),
  fanTip: () => ({ ok: true }),
  fanPayout: () => ({ ok: true, amount: 4320 }),
  // The bought picture comes back WITH its url, which is what the real one does: the server
  // sends it only once it has been paid for.
  fanUnlock: () => ({ ok: true, image: 'https://i.imgur.com/8Km9tLL.jpg' }),
  fanCreator: (b) => ({ ok: true,
    creator: { handle: b.handle, name: b.handle === 'mara' ? 'Mara Ortiz' : 'Ray',
               bio: 'Night photography', followers: 940, subscribers: 61,
               posts: 2, subPrice: b.handle === 'mara' ? 500 : 0, following: false },
    posts: [
      { id: 21, caption: 'Free sample.', price: 0, ts: 1753900000,
        image: 'https://i.imgur.com/8Km9tLL.jpg' },
      { id: 22, caption: 'Locked.', price: 250, ts: 1753890000, locked: true },
    ] }),

  appStorage: (b) => {
    const key = b.app + ':' + b.key;
    if (b.op === 'set') { STORAGE[key] = b.value; return { ok: true }; }
    return { ok: true, value: STORAGE[key] };
  },

  // ── Mail ──────────────────────────────────────────────────────────────────
  mail: (b) => {
    const domains = PREVIEW.__mailDomains;
    if (b.op === 'me') {
      // No address and NO error is what "you have no mailbox yet" looks like. An error here
      // sends RENDER.mail into an empty state instead of offering the sign-up.
      return DB.mail.address ? { ok: true, address: DB.mail.address, domains: domains }
                             : { ok: true, domains: domains };
    }
    if (b.op === 'create') {
      const local = String(b.local || '').trim();
      if (local.length < 3) return { error: 'short' };
      if (domains.indexOf(b.domain) === -1) return { error: 'domain' };
      DB.mail.address = local + '@' + b.domain;
      DB.mail.inbox = [{ id: nextId(), from_addr: 'welcome@' + b.domain, to_addr: DB.mail.address,
                         subject: 'Welcome to ' + b.domain, at: now(), seen: 0, box_id: nextId(),
                         mail_id: nextId(), body: 'Your mailbox is ready.' }];
      return { ok: true, address: DB.mail.address };
    }
    if (b.op === 'list') {
      const folder = b.folder || 'inbox';
      const rows = folder === 'sent' ? DB.mail.sent : DB.mail.inbox;
      return { ok: true, mail: rows, unread: DB.mail.inbox.filter((m) => !m.seen).length };
    }
    if (b.op === 'saved') return { ok: true, mail: [] };
    if (b.op === 'send') {
      DB.mail.sent.unshift({ id: nextId(), box_id: nextId(), mail_id: nextId(),
                             from_addr: DB.mail.address, to_addr: b.to, subject: b.subject,
                             body: b.body, at: now(), seen: 1, folder: 'sent' });
      return { ok: true };
    }
    if (b.op === 'seen') {
      const row = DB.mail.inbox.find((m) => m.box_id === b.boxId);
      if (row) row.seen = 1;
      return { ok: true };
    }
    return { ok: true };
  },

  // ── Notes ─────────────────────────────────────────────────────────────────
  notes: (b) => {
    if (b.op === 'list') return { ok: true, notes: DB.notes };
    if (b.op === 'save') {
      const row = DB.notes.find((n) => n.id === b.id);
      if (row) { row.title = b.title; row.body = b.body; row.at = now(); }
      else DB.notes.unshift({ id: nextId(), title: b.title, body: b.body, at: now() });
      return { ok: true };
    }
    if (b.op === 'del') { DB.notes = DB.notes.filter((n) => n.id !== b.id); return { ok: true }; }
    return { ok: true };
  },

  // ── Messages and contacts ─────────────────────────────────────────────────
  conversation: (b) => ({ ok: true, messages: DB.threads[b.number] || [] }),

  // Who is in a group. Enough to draw the sheet: the page shows a contact's name when it has
  // one and the masked number when it does not, so both cases want to be in here.
  groupMembers: (b) => ({
    ok: true,
    name: 'Braquage',
    members: [
      { number: PREVIEW.refresh.number, me: true, owner: true },
      { number: '555-0188', me: false, owner: false },
      { number: '555-0164', me: false, owner: false },
    ],
  }),

  send: (b) => {
    const to = String(b.number || '').trim();
    if (!to) return { error: 'nonumber' };
    // A payphone number cannot receive a text - the same refusal the real server gives.
    if (/^311-\\d+$/.test(to)) return { error: 'booth' };
    DB.threads[to] = DB.threads[to] || [];
    DB.threads[to].push({ body: b.body, outgoing: true, at: now(), kind: b.kind || 'text' });
    return { ok: true, id: nextId(), body: b.body, kind: b.kind || 'text' };
  },

  contactSave: (b) => {
    const row = DB.contacts.find((c) => c.id === b.id);
    if (row) Object.assign(row, { name: b.name, number: b.number });
    else DB.contacts.push({ id: nextId(), name: b.name, number: b.number });
    return { ok: true };
  },
  contactDelete: (b) => { DB.contacts = DB.contacts.filter((c) => c.id !== b.id); return { ok: true }; },

  calls: () => ({ ok: true, calls: DB.calls }),

  // ── The store ─────────────────────────────────────────────────────────────
  // A paid app really costs money here, and really refuses when you cannot afford it.
  install: (b) => {
    const app = bootState().available.find((a) => a.id === b.app);
    if (app && b.install && app.price && !DB.prefs.purchased.includes(app.id)) {
      if (DB.bank < app.price) return { error: 'nomoney', price: app.price };
      DB.bank -= app.price;
      DB.prefs.purchased = DB.prefs.purchased.concat([app.id]);
    }
    const key = (app && app.optional) ? 'added' : 'removed';
    const keep = (app && app.optional) ? b.install : !b.install;
    DB.prefs[key] = (DB.prefs[key] || []).filter((x) => x !== b.app);
    if (keep) DB.prefs[key] = DB.prefs[key].concat([b.app]);
    return { ok: true };
  },

  // ── The payphone ──────────────────────────────────────────────────────────
  boothCard: () => {
    if (DB.cards <= 0) return { error: 'nocarditem' };
    DB.cards -= 1;
    const added = PREVIEW.__booth.cardSeconds;
    DB.boothCredit = Math.min(7200, DB.boothCredit + added);
    return { ok: true, credit: DB.boothCredit, added: added };
  },
  boothCall: (b) => {
    const to = String(b.number || '').trim();
    if (!to) return { error: 'nonumber' };
    if (/^311-\\d+$/.test(to)) return { error: 'booth' };
    const free = ['911', '112', '999'].indexOf(to.replace(/\\D/g, '')) !== -1;
    if (!free && DB.boothCredit < PREVIEW.__booth.minimumSeconds) {
      return { error: 'lowcredit', need: PREVIEW.__booth.minimumSeconds, credit: DB.boothCredit };
    }
    setTimeout(() => send({ action: 'booth:call',
      call: { id: 9, state: 'active', number: PREVIEW.__booth.number } }), 700);
    return { ok: true, id: 9, free: free, credit: DB.boothCredit };
  },
  boothHangup: () => { send({ action: 'booth:call', call: null }); return { ok: true }; },
  boothClose: () => ({ ok: true }),

  vehicleFind: () => ({ ok: true, netId: 1, distance: 6 }),
  vehicleControl: () => ({ ok: true }),
};

window.__VPHONE_PREVIEW_POST__ = function (name, body) {
  body = body || {};
  const fn = HANDLERS[name];
  if (fn) return fn(body);
  // Anything with no handler answers "fine, nothing to show", which is what most screens
  // need in order to draw an empty state rather than an error.
  return PREVIEW[name] || { ok: true };
};

const send = (m) => window.postMessage(m, '*');
const reboot = () => send(bootState());

// The one handle the test panel talks to. A single global, named so it cannot collide with
// anything the phone declares.
window.PV = {
  send: send,
  reboot: reboot,
  music: function () { MUSIC_ON = true; reboot(); },
  paid: function () { PAID_ON = true; reboot(); },
  // A full wipe, not just the toggles: the simulated server keeps real state, so testing the
  // mail sign-up a second time means having no mailbox again.
  reset: function () {
    MUSIC_ON = false;
    PAID_ON = false;
    const fresh = JSON.parse(JSON.stringify(PREVIEW.refresh));
    DB.prefs = fresh.prefs;
    DB.contacts = fresh.contacts;
    DB.calls = fresh.calls;
    DB.threads = JSON.parse(JSON.stringify(PREVIEW.__threads));
    DB.notes = [{ id: 1, title: 'Shift notes', body: 'Order brake pads.', at: '2026-07-25 18:00' }];
    DB.mail = { address: null, inbox: [], sent: [] };
    DB.bank = 18650; DB.cash = 1240; DB.boothCredit = 437; DB.cards = 2;
    reboot();
  },
  booth: PREVIEW.__booth,

  // The first-run assistant: name, appearance, wallpaper, transparency, passcode, Face ID.
  // A brand new character has never completed it, and that is the ONLY thing that decides
  // whether it runs - so the preview reproduces it by booting as a character who has not.
  setup: function () {
    const b = bootState();
    b.prefs = Object.assign({}, b.prefs, {
      setupComplete: false, setupVersion: 0, securityEnabled: false, faceId: false,
      ownerName: '', deviceName: 'iFruit',
    });
    send(b);
  },

  // The security step on its own. An existing character below setupVersion 2 with no
  // passcode is shown just that part, once - which is a different screen from the full
  // assistant and worth being able to look at.
  security: function () {
    const b = bootState();
    b.prefs = Object.assign({}, b.prefs, { setupVersion: 1, securityEnabled: false });
    send(b);
  },
};

// Boot by RETRY rather than on `load`. app.js attaches its own message listener as it runs,
// and a single post fired at the wrong moment lands before that listener exists and is lost
// in silence - which looks exactly like a broken preview. This keeps posting until the phone
// is actually on screen, then stops.
(function boot(tries) {
  reboot();
  const device = document.getElementById('device');
  if ((!device || device.classList.contains('hidden')) && tries < 60) {
    setTimeout(() => boot(tries + 1), 50);
  }
})(0);
})();
""" % json.dumps(dict(replies,
                      __musicApp={'id': 'music', 'label': 'app.music', 'icon': 'music',
                                  'slot': 9, 'category': 'utilities', 'owner': 'v-phone'},
                      # The mail domains the sign-up offers, straight from Config.Mail.
                      __mailDomains=cfg.get('Mail', {}).get('domains', ['ls.com']),
                      # The seed conversations, so a reset can restore them.
                      __threads={
                          '555-0188': [
                              {'body': 'Are you around tonight?', 'outgoing': False, 'at': '2026-07-25 21:31'},
                              {'body': 'Yeah, at the garage until nine.', 'outgoing': True, 'at': '2026-07-25 21:35'},
                              {'body': 'On my way, five minutes.', 'outgoing': False, 'at': '2026-07-25 21:40'}],
                          '555-0164': [
                              {'body': 'Car is ready when you are.', 'outgoing': False, 'at': '2026-07-25 20:12'}]}),
                 ensure_ascii=False)

    panel = ('<div id="pvpanel"><h1>iFruit preview</h1>'
             '<p>The real page, the real config. Boots like a fresh install.</p>'
             + ''.join('<button onclick="%s">%s</button>' % (js.replace('"', '&quot;'), label)
                       for label, js in panel_rows)
             + '<small>Config: booth %s &middot; remote %s m &middot; %d playlists</small></div>'
             % (booth.get('numberFormat', '311-#####'),
                remote.get('distance', 20), len(music.get('defaultPlaylists', []))))

    # Everything is INLINED rather than linked. A single self-contained file can be opened
    # from anywhere, mailed to somebody, or dropped on a desktop - and it sidesteps the
    # sandboxes that refuse to execute a script reached through `../`, which is a failure that
    # looks exactly like a broken phone: the page loads, the assets fetch, and nothing runs.
    def asset(name):
        with open(os.path.join(ROOT, 'html', name), encoding='utf-8') as f:
            return f.read()

    css = '\n'.join(asset(n) for n in ('theme-vars.css', 'theme.css', 'style.css'))
    # Each file gets its OWN script tag below. Concatenating them means a throw in the first
    # silently stops the rest from ever running.
    #
    # theme.js is deliberately LEFT OUT. Its whole job is to swap in a `theme-vars.css`
    # served by the v-ui resource - `https://cfx-nui-v-ui/theme-vars.css` - which is a name
    # that only resolves inside FiveM. In a browser it is a guaranteed ERR_NAME_NOT_RESOLVED
    # in the console for no gain: the variables it would fetch are already inlined above.
    sdk_js = asset('sdk.js')
    app_js = asset('app.js')

    page = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>iFruit - preview</title>
<style>%s</style>
<style>
  /* The preview shell only. Nothing here touches the phone itself. */
  html, body { height: 100%%; margin: 0; background: #0b0d10; }
  /* The phone centres in the space LEFT OF the panel, not in the whole window: the panel is
     taken out of flow, so the padding is what keeps the handset off it. */
  body {
    display: flex; align-items: center; justify-content: center;
    padding-left: 250px; box-sizing: border-box;
  }
  #pvpanel {
    position: fixed; left: 0; top: 0; bottom: 0; width: 250px;
    padding: 22px 18px; box-sizing: border-box; overflow-y: auto;
    background: #0e1116; border-right: 1px solid #1b2027;
    font: 13px/1.5 -apple-system, "Segoe UI", system-ui, sans-serif; color: #cbd3dc;
  }
  #pvpanel::-webkit-scrollbar { width: 8px; }
  #pvpanel::-webkit-scrollbar-thumb { background: #232a33; border-radius: 4px; }
  #pvpanel h1 { margin: 0 0 4px; font-size: 17px; color: #fff; }
  #pvpanel p { margin: 0 0 14px; font-size: 12px; color: #7f8b98; }
  #pvpanel button {
    display: block; width: 100%%; margin-bottom: 6px; padding: 9px 11px;
    border: 0; border-radius: 8px; text-align: left; cursor: pointer;
    font: inherit; color: #dce3ea; background: #1b2027;
  }
  #pvpanel button:hover { background: #262d36; }
  #pvpanel small { display: block; margin-top: 12px; color: #5f6b76; font-size: 11px; }
</style>
</head>
<body>
%s
%s
<script>%s</script>
<script>%s</script>
<script>%s</script>
</body>
</html>
""" % (css, panel, markup(), sdk_js, harness, app_js)

    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, 'index.html')
    with open(path, 'w', encoding='utf-8') as f:
        f.write(page)

    # The store previews, beside the page rather than inlined.
    #
    # Everything else here is folded into one file, which cannot work for these: they are a
    # manifest the page fetches and the media it names, and a `fetch` of `previews/index.json`
    # resolves next to `preview/index.html`. Without the copy the store falls back to its drawn
    # mock-ups and the preview quietly stops showing what the resource actually ships - which
    # is the one thing this tool exists to avoid.
    src = os.path.join(ROOT, 'html', 'previews')
    if os.path.isdir(src):
        dst = os.path.join(OUT, 'previews')
        shutil.rmtree(dst, ignore_errors=True)
        shutil.copytree(src, dst)

    hidden = [a['id'] for a in cfg.get('Apps', []) if a not in apps]
    print('preview written: %s' % path)
    print('  %d locale strings' % len(S))
    print('  %d apps shown of %d in config' % (len(apps), len(cfg.get('Apps', []))))
    print('  booth %s, remote %sm, %d playlists'
          % (booth.get('numberFormat'), remote.get('distance'), len(music.get('defaultPlaylists', []))))
    return path


if __name__ == '__main__':
    build()
