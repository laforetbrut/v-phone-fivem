# v-phone

An iOS 27 style phone for FiveM that runs on **your** framework. qb-core, qbx_core, ox_core, ESX or no framework at all: the phone detects what is running and adapts, and every one of those decisions is a line in the config file when you want it to be different.

Twenty apps, a real FruitStore, three social networks, an app SDK so other resources can ship their own apps, and a first run setup with a passcode and Face ID.

## Screenshots

### First run

A phone opened for the first time is activated, not just switched on: a name, an appearance, a wallpaper with the Clear Glass slider, a six digit passcode, and Face ID if the player wants it.

| Hello | Wallpaper and transparency | Face ID |
|---|---|---|
| <img src="docs/images/01-setup-hello.png" alt="First run" width="240"> | <img src="docs/images/02-setup-wallpaper.png" alt="Wallpaper" width="240"> | <img src="docs/images/03-setup-faceid.png" alt="Face ID" width="240"> |

### Every day

| Home screen | Lock screen | Dynamic Island |
|---|---|---|
| <img src="docs/images/04-home.png" alt="Home" width="240"> | <img src="docs/images/10-lock-screen.png" alt="Lock screen" width="240"> | <img src="docs/images/08-dynamic-island.png" alt="Dynamic Island" width="240"> |

The Dynamic Island is not decoration: a message arrives out of it, a call lives in it, and locking pinches it around a padlock.

### Apps

| Settings | Bank | Messages |
|---|---|---|
| <img src="docs/images/05-settings.png" alt="Settings" width="240"> | <img src="docs/images/06-bank.png" alt="Bank" width="240"> | <img src="docs/images/09-messages.png" alt="Messages" width="240"> |

### Control centre

Pull down from the top right for the toggles, the brightness and volume slabs, and what is playing.

<img src="docs/images/07-control-centre.png" alt="Control centre" width="300">

## Features

### The phone
- **iOS 27 interface**: Clear Glass materials, a Dynamic Island that reacts to calls, notifications, locking and Face ID, a control centre, a notification shade and a Spotlight search.
- **First run setup**: name, appearance, wallpaper, transparency, a six digit passcode and optional Face ID. The passcode never reaches the page: the server keeps a character salted SHA-256 digest and blocks for thirty seconds after five failures.
- **Configurable home screen**: choose the dock, which apps ship installed, their order, which cannot be removed and which are hidden, all in one table.
- **Grid sizes** from 3x3 to 6x7, chosen by the player in Settings.
- **Sound**: sixteen audio files ship with the phone, five ringtones, four alerts, five interface sounds and the payphone's two struck-metal key clicks. They are generated rather than sampled, so a melody is a table in `tools/make-sounds.py` and nothing is taken from anywhere.
- **In hand**: a prop, an animation, and a phone that keeps working while you walk and drive.
- **Battery** with charging in a vehicle, at a public charger, and inside a property you have a key to (Quasar housing and the rest). Power banks and a low battery warning.
- **Police forensics**: a warrant terminal at a map point where police read a suspect's texts, contacts, calls and social from the number. Cipher stays end-to-end encrypted, with an optional, deliberately hard lawful-intercept crack.
- **Payphones**: the call boxes already standing in Los Santos, made to work - no coordinate list, because the client finds the props themselves. A booth **places calls and can never receive them**, its number is derived from where it stands so it is the same every restart, and calls are paid for with a prepaid card item fed into the box. Emergency numbers are free, and walking away hangs up.
- **`/refreshphone`**: a get-out-of-jail command for a phone stuck to the hand or a frozen animation.
- **Media hosting**: photos and short video clips captured in game and uploaded to a CDN (Fivemanage), with a per-file auto-delete clock. Clips post to Bleeter and Snapmatic.
- **Front camera**: a selfie mode - a game camera in front of you - for photos and clips of yourself.
- **FaceTime**: a real video call. With `Config.FaceTime.videoFeed` on, the front camera goes up and a shrunk, cropped frame of each player is relayed to the other a few times a second, over the normal voice call. Needs [screenshot-basic](https://github.com/citizenfx/screenshot-basic); off by default.

### The apps
Phone, Messages, Contacts, Mail, Maps, Camera, Gallery, Music, Bank, Garage, Property, Wallet, Jobs, Health, Notes, Reminders, Calculator, MDT, FruitStore, Settings, plus four downloads: Bleeter, Snapmatic, Hush and Cipher.

- **Phone**: keypad, favourites, history, voicemail, speaker mode heard by nearby players.
- **Messages**: private and group threads, photos, GIFs, location sharing, reactions, forwarding and emoji.
- **Bank**: the balance your framework already keeps, a statement, transfers to another character by phone number, saved beneficiaries, and a notification when money arrives - a salary, a society payout, a transfer. No companion resource - it reads qb-core, qbx, ESX, ox or your banking script through the bridge. Limits, an optional fee and offline transfers are configurable.
- **Bleeter** (Twitter): two timelines, likes, comments, reposts, a searchable directory, follows, direct messages and profiles.
- **Snapmatic** (Instagram): stories with a 24 hour life, a photo feed, a profile grid, search and direct messages.
- **Hush** (Tinder): a card you throw with your finger, matches kept in their own tab, an editable profile.
- **Cipher**: an encrypted messenger. The server routes sealed envelopes and keeps neither the clear text nor a private key.

### For developers
- **Drop-in apps**: an app is a folder in `apps/`. No edit to the phone, no build step, no JavaScript framework. See [DEVELOPERS.md](DEVELOPERS.md).
- **App SDK**: the same Clear Glass components the native apps use.
- **Integration hooks**: point any app at your own script in one function rather than forking the resource.
- **A documented API**: thirty two server exports, five client exports, three events and seven hooks. See [API.md](API.md).

## Compatibility

Everything below is detected automatically. Naming one explicitly in `Config.Compat` always wins, and `off` disables the integration.

| Kind | Supported |
|---|---|
| Framework | qb-core, qbx_core, ox_core, es_extended, standalone |
| Inventory | ox_inventory, qs-inventory (Quasar), ps-inventory, qb-inventory, origen_inventory, codem-inventory |
| Banking | qs-banking, Renewed-Banking, qb-banking, okokBanking, esx_banking |
| Garage | qs-advancedgarages, jg-advancedgarages, qb-garages, cd_garage, okokGarage |
| Housing | qs-housing, ps-housing, qb-houses, ox_property, loaf_housing, esx_property |
| Voice | pma-voice, saltychat, mumble-voip |
| Notifications | ox_lib, qb-core, ESX, chat, or your own event |

**Every app is audited per ecosystem.** [COMPATIBILITY.md](COMPATIBILITY.md) lists what each app needs, what it reads on qb, ox, ESX and Quasar, and how to point it at your own script in one function.

**Standalone works.** With no framework the phone falls back to the licence identifier, and apps that need a job or a bank simply are not offered.

**The phone owns its own storage.** Preferences, layouts and photo lists live in `vphone_kv`, keyed by character. Nothing is written into your framework's metadata column, so a framework update cannot break the phone.

**Every table it creates begins with `vphone_`,** so it can never collide with another script's table. A server upgraded from an older build has its data moved to the new names automatically at boot.

## Dependencies

**Required** - the phone will not start without it:

- [oxmysql](https://github.com/overextended/oxmysql) - the database layer.

**Optional** - each unlocks one feature and is detected at runtime; the phone runs fine without any of them:

| Resource | Unlocks | Link |
|---|---|---|
| [screenshot-basic](https://github.com/citizenfx/screenshot-basic) | the Camera app uploading photos, and the FaceTime live picture | citizenfx/screenshot-basic |
| [screencapture](https://github.com/itschip/screencapture) | photos and **video clips** to a CDN (Fivemanage) | itschip/screencapture |
| [pma-voice](https://github.com/AvarianKnight/pma-voice) | phone call voice | AvarianKnight/pma-voice |
| [xsound](https://github.com/Xogy/xsound) | **the Music app actually playing** - see below | Xogy/xsound |
| [ox_lib](https://github.com/overextended/ox_lib) | nicer notifications | overextended/ox_lib |
| [ox_target](https://github.com/overextended/ox_target) | targeting the police forensics terminal | overextended/ox_target |
| A framework | jobs, money, licences, character names | [qb-core](https://github.com/qbcore-framework/qb-core) · [qbx_core](https://github.com/Qbox-project/qbx_core) · [ox_core](https://github.com/overextended/ox_core) · [es_extended](https://github.com/esx-framework/esx_core) |

Inventory, banking, garage and housing scripts are detected too - see [COMPATIBILITY.md](COMPATIBILITY.md) for the full list and the exact resource names.

The Bank, Garage, Property, Wallet and Jobs apps need **no companion resource**: they read whatever your framework and your scripts already keep, through the bridge.

### Music needs a player

The phone has no audio engine of its own, and it cannot have one: playing a URL out loud in
GTA means an NUI page that streams it, and that page belongs to a resource. So the Music app
keeps the library, the playlists, the queue and the favourites - all of that works with
nothing installed - and hands the actual sound to whatever player your server runs.

Install [**xsound**](https://github.com/Xogy/xsound) (MIT, free) and the phone plays tracks
itself, with all three outputs working:

```
ensure xsound
```

| Output | What happens |
|---|---|
| Headphones | only you hear it |
| Phone speaker | everybody near you hears it, and it follows you as you walk |
| Car radio | positioned on the vehicle, so it moves with the car |

`Config.Music.speakerRange` sets how far the speaker carries - 12 m by default, because a
phone speaker is a phone speaker.

`rcore_radiocar` and `xdiskjockey` are detected too, but neither can be driven from outside:
with those the phone opens their own interface and copies the link for you to paste. With no
player at all the app still works as a library and says so on screen.


## Installation

Nothing here is optional-but-actually-required. Step 3 is the only one most servers need.

### 1. oxmysql

The one hard requirement. [Install it](https://github.com/overextended/oxmysql) and make sure
your `mysql_connection_string` is set, because every table the phone needs is created through
it on the first start.

### 2. Drop the folder in

`resources/[phone]/v-phone`, or wherever you keep things. The folder name **must stay
`v-phone`** - the resource looks itself up by name in a few places.

### 3. server.cfg

Order matters: after your framework, after oxmysql.

```cfg
ensure oxmysql
ensure qb-core          # or qbx_core, ox_core, es_extended - whatever you run
ensure v-phone
```

### 4. Start the server once

Every table is created automatically, and the console says what was detected:

```
[v-phone] framework: qb-core
```

If that line says `standalone` and you do run a framework, the framework started *after* the
phone - move its `ensure` above. (Turn `Config.Log.boot = true` on to see that line at all;
it is off by default so a live console stays readable.)

### 5. Give players a phone item

**Skipped entirely if you do not want an item.** Set `Config.Settings.requireItem = false`, or
`set phone_requireItem false` in server.cfg, and everybody has a phone. That is a legitimate
choice and plenty of servers make it.

If you *do* want the item, see [Creating the phone item](#creating-the-phone-item) below - it
is one row of SQL or one table entry, per framework.

### 6. Optional convars

```cfg
setr phone_locale "en"        # or fr, or any locale file you add
set phone_battery false      # any Config.Settings key, prefixed with phone_
set phone_requireItem false   # everybody gets a phone, no item needed
set phone_camera true         # the Camera app (needs screenshot-basic or screencapture)
set phone_media true          # photo hosting
setr phone_verbose true       # the boot summary
setr phone_debug true         # the page's tracing in F8. Leave this OFF on a live server
```

`setr` where the client has to read it too, `set` where only the server does. A plain `set`
convar does not exist on a client at all, which is a mistake worth knowing about before it
costs you an afternoon.

### 7. Staff permissions

```cfg
add_ace group.admin vphone.admin allow
```

qb-core's own `qbadmin.menu` is accepted too, so existing staff usually work without this. See
[Admin commands](#admin-commands).

## Creating the phone item

Only needed when `Config.Settings.requireItem` is on (it is, by default). The item name the
phone looks for is `Config.PhoneItem`, `phone` out of the box - and `phone` and `iphone` are
both accepted whatever you set, so an item you already have usually just works.

The phone does **not** need the item to be usable-on-click: it opens with the keybind either
way. Making it usable is nicer, so both halves are below.

### qb-core

`qb-core/shared/items.lua` - add one entry:

```lua
['phone'] = {
    ['name'] = 'phone',
    ['label'] = 'Phone',
    ['weight'] = 700,
    ['type'] = 'item',
    ['image'] = 'phone.png',
    ['unique'] = false,
    ['useable'] = true,
    ['shouldClose'] = true,
    ['combinable'] = nil,
    ['description'] = 'To call and text people',
},
```

Recent qb-core versions ship a `phone` item already - check before adding a second one. Put a
`phone.png` in `qb-inventory/html/images/` or the slot shows a blank square.

Give one to a player:

```
/giveitem 1 phone 1
```

### qbx_core (Qbox)

Items live in `ox_inventory/data/items.lua`, because Qbox uses ox_inventory:

```lua
['phone'] = {
    label = 'Phone',
    weight = 700,
    stack = false,
    close = true,
    description = 'To call and text people',
},
```

No `client` block and no export: the phone listens to `ox_inventory:usedItem` itself, so
declaring the item is all there is to do.

### ox_core / ox_inventory

Same file, same entry as Qbox above.

### ESX

ESX keeps items in the database. One row:

```sql
INSERT INTO items (name, label, weight, rare, can_remove)
VALUES ('phone', 'Phone', 1, 0, 1);
```

On an ESX server using ox_inventory, use the ox entry above instead - ox_inventory reads its
own file, not the `items` table.

Give one to a player:

```
/giveitem 1 phone 1
```

### Any inventory: making it open the phone

The phone registers a usable item by itself for every inventory it detects: `ox_inventory`,
`qs-inventory`, `ps-inventory`, `qb-inventory`, `origen_inventory`, `codem-inventory`. On
qb-core and qbx it goes through `CreateUseableItem`, on ESX through `ESX.RegisterUsableItem`,
and on ox_inventory it listens to `ox_inventory:usedItem` - so on all of those, declaring the
item is enough.

If yours is not in that list, have it call the client export:

```lua
exports['v-phone']:Open()
```

`Config.Compat.inventory` also takes a resource name instead of `'auto'`, for a fork whose name
the bridge does not recognise.

## Admin commands

Behind `Config.Admin.ace` (`vphone.admin` by default), or qb-core's `qbadmin.menu`. Type
`/phoneadmin` in chat and the autocomplete lists every subcommand with its arguments - staff
only, so a player who cannot run them is never offered them.

Each one has its own switch in `Config.Admin.actions`, so an action you would rather staff did
not have is **removed**, not merely left untyped.

### Reading a phone

```
/phoneadmin info     [id|cid|number]      number, battery, unread, online
/phoneadmin who                            everybody with a phone open right now
/phoneadmin number   [id|cid]              read a number
/phoneadmin contacts [id|cid]              read the contact book
/phoneadmin apps     [id|cid]              what is installed
/phoneadmin bricked                        which phones are out of service
/phoneadmin outages                        what outages are in force, and for how long
/phoneadmin verified (snap)                who holds a verified badge
```

### Acting on one phone

```
/phoneadmin open     [id]                  open their phone on their screen (support)
/phoneadmin battery  [id] [0-100]
/phoneadmin number   [id|cid] [number]     set a number
/phoneadmin message  [id|cid] [text]       a text message, from Staff
/phoneadmin notify   [id|cid] [text]       a banner - does not persist, comes from no number
/phoneadmin app      [id|cid] give|take [appid]
/phoneadmin brick    [id|cid] (minutes)    take one handset out of service
/phoneadmin unbrick  [id|cid]
/phoneadmin wipe     [id|cid] confirm      DELETE everything on that phone. Irreversible
```

### The whole server

```
/phoneadmin announce   [text]              a banner on every phone online
/phoneadmin batteryall [0-100]
/phoneadmin outage     [bars 0-4] (minutes)              the whole server
/phoneadmin outage here [radius] [bars] (minutes)        a circle around you
/phoneadmin outage at [x] [y] [z] [radius] [bars] (minutes)
/phoneadmin outage clear [id|all]
```

An outage is a **ceiling in bars**, not an on/off switch: one bar is a far more interesting
outage than no phone, because calls drop and players have to move to be heard. It goes through
the same path as the map's dead zones and the worst one wins, so a global outage cannot be
escaped by standing somewhere with perfect reception. `minutes = 0`, or omitted, means until
somebody clears it. **Nothing is persisted** - a restart lifts every outage, deliberately, so
one nobody remembers setting can never survive a crash.

`brick` is the other half: the network is fine, that handset is not. For a phone that was
smashed or confiscated. Keyed by citizen id, so it survives reconnecting, and a bricked phone
refuses to **open** rather than opening onto features that quietly fail.

### Social

```
/phoneadmin verify [@handle] (off) (snap)   grant or revoke the verified badge
```

By handle rather than by character, because a badge belongs to an account and a report has the
@handle in it. It is an **export, never a callback**: a client cannot ask to be verified.

### Everybody's commands

```
/refreshphone      reset your own stuck phone: prop, animation, NUI focus, control guard
/phonediag         staff only, and only with debug on: what each callback and provider answers
```

Every refused staff command is printed to the server console with who tried it.


## Support

| You want to... | Go to |
| --- | --- |
| Report something broken | [Bug report](https://github.com/laforetbrut/v-phone-fivem/issues/new?template=01-bug.yml) |
| An app does not read your inventory / banking / housing script | [Compatibility report](https://github.com/laforetbrut/v-phone-fivem/issues/new?template=02-compatibility.yml) |
| Suggest a feature | [Feature request](https://github.com/laforetbrut/v-phone-fivem/issues/new?template=03-feature.yml) |
| Fix the docs | [Documentation](https://github.com/laforetbrut/v-phone-fivem/issues/new?template=04-docs.yml) |
| Ask a question, get setup help | [Discussions](https://github.com/laforetbrut/v-phone-fivem/discussions) |
| Report a vulnerability | [Privately](https://github.com/laforetbrut/v-phone-fivem/security/advisories/new) — never a public issue |

A bug report needs **both** consoles (server and client F8) and steps from a fresh connection.
Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## Licence

[MIT with an attribution requirement](LICENSE). Use it, change it, sell your server with it.

The one thing you may not do is remove the credit the phone shows the player in **Settings > About**. Restyle it, translate it, put your own credits next to it. Do not take it away.

## Credits

Author: vyrriox

Bleeter, Snapmatic and Hush are brands from Grand Theft Auto V.

---

# v-phone (Version Française)

Un téléphone au style iOS 27 pour FiveM qui tourne sur **votre** framework. qb-core, qbx_core, ox_core, ESX ou aucun framework : le téléphone détecte ce qui tourne et s'y adapte, et chacune de ces décisions est une ligne du fichier de configuration quand vous voulez en changer.

Vingt applications, un vrai FruitStore, trois réseaux sociaux, un SDK pour que d'autres ressources livrent leurs propres applications, et une configuration au premier démarrage avec code et Face ID.

## Captures d'écran

### Premier démarrage

Un téléphone ouvert pour la première fois est activé, pas seulement allumé : un nom, une apparence, un fond d'écran avec le curseur Clear Glass, un code à six chiffres, et Face ID si le joueur le souhaite.

| Bonjour | Fond et transparence | Face ID |
|---|---|---|
| <img src="docs/images/01-setup-hello.png" alt="Premier démarrage" width="240"> | <img src="docs/images/02-setup-wallpaper.png" alt="Fond d'écran" width="240"> | <img src="docs/images/03-setup-faceid.png" alt="Face ID" width="240"> |

### Au quotidien

| Écran d'accueil | Écran de verrouillage | Dynamic Island |
|---|---|---|
| <img src="docs/images/04-home.png" alt="Accueil" width="240"> | <img src="docs/images/10-lock-screen.png" alt="Verrouillage" width="240"> | <img src="docs/images/08-dynamic-island.png" alt="Dynamic Island" width="240"> |

La Dynamic Island n'est pas décorative : un message en sort, un appel y vit, et le verrouillage la pince autour d'un cadenas.

### Applications

| Réglages | Banque | Messages |
|---|---|---|
| <img src="docs/images/05-settings.png" alt="Réglages" width="240"> | <img src="docs/images/06-bank.png" alt="Banque" width="240"> | <img src="docs/images/09-messages.png" alt="Messages" width="240"> |

### Centre de contrôle

Tirez depuis le coin haut droit pour les interrupteurs, les curseurs de luminosité et de volume, et ce qui est en lecture.

<img src="docs/images/07-control-centre.png" alt="Centre de contrôle" width="300">

## Caractéristiques

### Le téléphone
- **Interface iOS 27** : matériaux Clear Glass, Dynamic Island qui réagit aux appels, aux notifications, au verrouillage et au Face ID, centre de contrôle, volet de notifications et recherche Spotlight.
- **Configuration au premier démarrage** : nom, apparence, fond d'écran, transparence, code à six chiffres et Face ID optionnel. Le code n'atteint jamais la page : le serveur garde une empreinte SHA-256 salée par personnage et bloque trente secondes après cinq échecs.
- **Écran d'accueil configurable** : le dock, les applications livrées, leur ordre, celles qu'on ne peut pas supprimer et celles qui sont masquées, le tout dans une seule table.
- **Grilles** de 3x3 à 6x7, choisies par le joueur dans les Réglages.
- **Son** : seize fichiers audio sont livrés avec le téléphone, cinq sonneries, quatre alertes, cinq sons d'interface et les deux clics de touche en métal frappé de la cabine. Ils sont générés plutôt qu'échantillonnés : une mélodie est une table dans `tools/make-sounds.py` et rien n'est repris de nulle part.
- **En main** : un prop, une animation, et un téléphone qui continue de fonctionner en marchant et en conduisant.
- **Batterie** avec recharge dans un véhicule, à une borne publique, et à l'intérieur d'un logement dont vous avez la clé (Quasar housing et les autres). Batteries externes et alerte de batterie faible.
- **Enquête police** : un terminal d'analyse à un point de la carte où la police lit les SMS, contacts, appels et réseaux d'un suspect à partir du numéro. Cipher reste chiffré de bout en bout, avec une interception légale optionnelle et volontairement difficile.
- **Cabines téléphoniques** : les bornes déjà présentes à Los Santos, rendues fonctionnelles - aucune liste de coordonnées, car le client trouve les props lui-même. Une cabine **passe des appels et ne peut jamais en recevoir**, son numéro est dérivé de sa position et reste donc identique à chaque redémarrage, et les appels se paient avec un item carte prépayée inséré dans la borne. Les numéros d'urgence sont gratuits, et s'éloigner raccroche.
- **`/refreshphone`** : une commande de secours quand le téléphone reste collé à la main ou qu'une animation se fige.
- **Hébergement média** : photos et courts clips vidéo capturés en jeu et envoyés vers un CDN (Fivemanage), avec une horloge de suppression automatique par fichier. Les clips se publient sur Bleeter et Snapmatic.
- **Caméra frontale** : un mode selfie - une caméra de jeu devant vous - pour se photographier et se filmer.
- **FaceTime** : un vrai appel vidéo. Avec `Config.FaceTime.videoFeed` activé, la caméra frontale se lève et une image réduite et recadrée de chaque joueur est relayée à l'autre plusieurs fois par seconde, par-dessus l'appel vocal normal. Nécessite [screenshot-basic](https://github.com/citizenfx/screenshot-basic) ; désactivé par défaut.

### Les applications
Téléphone, Messages, Contacts, Mail, Plans, Appareil photo, Galerie, Musique, Banque, Garage, Logement, Portefeuille, Emplois, Santé, Notes, Rappels, Calculatrice, MDT, FruitStore, Réglages, plus quatre téléchargements : Bleeter, Snapmatic, Hush et Cipher.

- **Téléphone** : clavier, favoris, historique, répondeur, haut-parleur entendu par les joueurs autour.
- **Messages** : conversations privées et groupées, photos, GIF, partage de position, réactions, transfert et emoji.
- **Banque** : le solde que votre framework tient déjà, un relevé, des virements vers un autre personnage par numéro de téléphone, des bénéficiaires enregistrés, et une notification quand de l'argent arrive — salaire, versement de société, virement. Aucune ressource compagnon : elle lit qb-core, qbx, ESX, ox ou votre script bancaire via le bridge. Limites, frais optionnels et virements hors ligne configurables.
- **Bleeter** (Twitter) : deux fils, likes, commentaires, republications, annuaire cherchable, abonnements, messages privés et profils.
- **Snapmatic** (Instagram) : stories d'une journée, fil photo, profil en grille, recherche et messages privés.
- **Hush** (Tinder) : une carte qu'on lance au doigt, les matchs conservés dans leur onglet, un profil modifiable.
- **Cipher** : messagerie chiffrée. Le serveur route des enveloppes scellées et ne conserve ni le texte clair ni la clé privée.

### Pour les développeurs
- **Applications déposables** : une application est un dossier dans `apps/`. Aucune modification du téléphone, aucune étape de build, aucun framework JavaScript. Voir [DEVELOPERS.md](DEVELOPERS.md).
- **SDK** : les mêmes composants Clear Glass que les applications natives.
- **Points d'accroche** : branchez n'importe quelle application sur votre propre script en une fonction plutôt qu'en forkant la ressource.
- **Une API documentée** : trente-deux exports serveur, cinq exports client, trois événements et sept hooks. Voir [API.md](API.md).

## Compatibilité

Tout ce qui suit est détecté automatiquement. Nommer explicitement une ressource dans `Config.Compat` l'emporte toujours, et `off` désactive l'intégration.

| Type | Pris en charge |
|---|---|
| Framework | qb-core, qbx_core, ox_core, es_extended, autonome |
| Inventaire | ox_inventory, qs-inventory (Quasar), ps-inventory, qb-inventory, origen_inventory, codem-inventory |
| Banque | qs-banking, Renewed-Banking, qb-banking, okokBanking, esx_banking |
| Garage | qs-advancedgarages, jg-advancedgarages, qb-garages, cd_garage, okokGarage |
| Logement | qs-housing, ps-housing, qb-houses, ox_property, loaf_housing, esx_property |
| Voix | pma-voice, saltychat, mumble-voip |
| Notifications | ox_lib, qb-core, ESX, chat, ou votre propre événement |

**Chaque application est auditée par écosystème.** [COMPATIBILITY.md](COMPATIBILITY.md) liste ce dont chaque application a besoin, ce qu'elle lit sur qb, ox, ESX et Quasar, et comment la brancher sur votre propre script en une fonction.

**Le mode autonome fonctionne.** Sans framework, le téléphone se rabat sur l'identifiant de licence, et les applications qui ont besoin d'un métier ou d'une banque ne sont simplement pas proposées.

**Le téléphone possède son propre stockage.** Préférences, dispositions et listes de photos vivent dans `vphone_kv`, par personnage. Rien n'est écrit dans la colonne metadata de votre framework, donc une mise à jour de celui-ci ne peut pas casser le téléphone.

## Dépendances

**Obligatoire** - le téléphone ne démarre pas sans :

- [oxmysql](https://github.com/overextended/oxmysql) - la couche base de données.

**Optionnelles** - chacune débloque une fonctionnalité et est détectée à l'exécution ; le téléphone tourne très bien sans aucune :

| Ressource | Débloque | Lien |
|---|---|---|
| [screenshot-basic](https://github.com/citizenfx/screenshot-basic) | l'upload de photos de l'app Appareil photo, et l'image FaceTime en direct | citizenfx/screenshot-basic |
| [screencapture](https://github.com/itschip/screencapture) | photos et **clips vidéo** vers un CDN (Fivemanage) | itschip/screencapture |
| [pma-voice](https://github.com/AvarianKnight/pma-voice) | la voix des appels | AvarianKnight/pma-voice |
| [xsound](https://github.com/Xogy/xsound) | **la lecture réelle dans l'app Musique** - voir plus bas | Xogy/xsound |
| [ox_lib](https://github.com/overextended/ox_lib) | de plus belles notifications | overextended/ox_lib |
| [ox_target](https://github.com/overextended/ox_target) | le ciblage du terminal d'enquête police | overextended/ox_target |
| Un framework | métiers, argent, licences, noms de personnage | [qb-core](https://github.com/qbcore-framework/qb-core) · [qbx_core](https://github.com/Qbox-project/qbx_core) · [ox_core](https://github.com/overextended/ox_core) · [es_extended](https://github.com/esx-framework/esx_core) |

Les scripts d'inventaire, de banque, de garage et de logement sont aussi détectés - voir [COMPATIBILITY.md](COMPATIBILITY.md) pour la liste complète et les noms exacts.

### La musique a besoin d'un lecteur

Le téléphone n'a pas de moteur audio et ne peut pas en avoir : jouer une URL à voix haute dans
GTA suppose une page NUI qui la diffuse, et cette page appartient à une ressource. L'app
Musique garde donc la bibliothèque, les playlists, la file d'attente et les favoris - tout cela
fonctionne sans rien installer - et confie le son au lecteur que votre serveur fait tourner.

Installez [**xsound**](https://github.com/Xogy/xsound) (MIT, gratuit) et le téléphone joue les
titres lui-même, avec les trois sorties fonctionnelles :

```
ensure xsound
```

| Sortie | Ce qui se passe |
|---|---|
| Écouteurs | vous seul entendez |
| Haut-parleur du téléphone | tout le monde autour de vous entend, et le son vous suit quand vous marchez |
| Autoradio | positionné sur le véhicule, donc il se déplace avec la voiture |

`Config.Music.speakerRange` règle la portée du haut-parleur - 12 m par défaut, parce qu'un
haut-parleur de téléphone reste un haut-parleur de téléphone.

`rcore_radiocar` et `xdiskjockey` sont également détectés, mais aucun des deux ne se pilote de
l'extérieur : avec ceux-là le téléphone ouvre leur propre interface et copie le lien à coller.
Sans aucun lecteur, l'app fonctionne toujours comme bibliothèque et le dit à l'écran.

Les applications Banque, Garage, Logement, Portefeuille et Emplois n'ont besoin d'**aucune ressource compagnon** : elles lisent ce que votre framework et vos scripts conservent déjà, via le bridge.

## Installation

Rien ici n'est « optionnel mais en fait obligatoire ». L'étape 3 est la seule dont la plupart
des serveurs ont besoin.

### 1. oxmysql

La seule dépendance dure. [Installez-la](https://github.com/overextended/oxmysql) et vérifiez
que votre `mysql_connection_string` est renseignée : toutes les tables du téléphone sont créées
à travers elle au premier démarrage.

### 2. Déposez le dossier

`resources/[phone]/v-phone`, ou là où vous rangez vos ressources. Le nom du dossier **doit
rester `v-phone`** : la ressource se cherche elle-même par ce nom à plusieurs endroits.

### 3. server.cfg

L'ordre compte : après votre framework, après oxmysql.

```cfg
ensure oxmysql
ensure qb-core          # ou qbx_core, ox_core, es_extended - ce que vous faites tourner
ensure v-phone
```

### 4. Démarrez le serveur une fois

Toutes les tables sont créées automatiquement, et la console indique ce qui a été détecté :

```
[v-phone] framework: qb-core
```

Si cette ligne dit `standalone` alors que vous avez bien un framework, c'est qu'il a démarré
*après* le téléphone : remontez son `ensure`. (Mettez `Config.Log.boot = true` pour voir cette
ligne : elle est désactivée par défaut pour qu'une console de production reste lisible.)

### 5. Donnez un item téléphone aux joueurs

**Entièrement facultatif.** Mettez `Config.Settings.requireItem = false`, ou
`set phone_requireItem false` dans server.cfg, et tout le monde a un téléphone. C'est un choix
parfaitement valable et beaucoup de serveurs le font.

Si vous **voulez** l'item, voir [Créer l'item téléphone](#créer-litem-téléphone) plus bas : une
ligne de SQL ou une entrée de table, selon le framework.

### 6. Convars optionnels

```cfg
setr phone_locale "fr"        # ou en, ou tout fichier de langue que vous ajoutez
set phone_battery false       # n'importe quelle clé de Config.Settings, préfixée phone_
set phone_requireItem false   # tout le monde a un téléphone, sans item
set phone_camera true         # l'app Appareil photo (nécessite screenshot-basic ou screencapture)
set phone_media true          # l'hébergement des photos
setr phone_verbose true       # le résumé de démarrage
setr phone_debug true         # le traçage de la page dans F8. À laisser SUR OFF en production
```

`setr` quand le client doit le lire aussi, `set` quand seul le serveur en a besoin. Un convar
posé avec un simple `set` n'existe pas du tout côté client — une subtilité qu'il vaut mieux
connaître avant qu'elle ne vous coûte une après-midi.

### 7. Permissions du staff

```cfg
add_ace group.admin vphone.admin allow
```

Le `qbadmin.menu` de qb-core est aussi accepté, donc un staff existant fonctionne généralement
sans cette ligne. Voir [Commandes admin](#commandes-admin).

## Créer l'item téléphone

Nécessaire seulement si `Config.Settings.requireItem` est actif (c'est le cas par défaut). Le
nom d'item que le téléphone cherche est `Config.PhoneItem`, soit `phone` d'origine — et `phone`
et `iphone` sont acceptés dans tous les cas, donc un item que vous avez déjà fonctionne
généralement tel quel.

Le téléphone n'a **pas** besoin que l'item soit utilisable au clic : il s'ouvre avec la touche
dans tous les cas. Le rendre utilisable est plus agréable, donc les deux moitiés sont ci-dessous.

### qb-core

`qb-core/shared/items.lua` — ajoutez une entrée :

```lua
['phone'] = {
    ['name'] = 'phone',
    ['label'] = 'Téléphone',
    ['weight'] = 700,
    ['type'] = 'item',
    ['image'] = 'phone.png',
    ['unique'] = false,
    ['useable'] = true,
    ['shouldClose'] = true,
    ['combinable'] = nil,
    ['description'] = 'Pour appeler et envoyer des messages',
},
```

Les versions récentes de qb-core livrent déjà un item `phone` — vérifiez avant d'en ajouter un
second. Placez un `phone.png` dans `qb-inventory/html/images/` sinon la case reste vide.

Donner l'item à un joueur :

```
/giveitem 1 phone 1
```

### qbx_core (Qbox)

Les items vivent dans `ox_inventory/data/items.lua`, puisque Qbox utilise ox_inventory :

```lua
['phone'] = {
    label = 'Téléphone',
    weight = 700,
    stack = false,
    close = true,
    description = 'Pour appeler et envoyer des messages',
},
```

Pas de bloc `client` ni d'export : le téléphone écoute lui-même `ox_inventory:usedItem`, donc
déclarer l'item est tout ce qu'il y a à faire.

### ox_core / ox_inventory

Même fichier, même entrée que Qbox ci-dessus.

### ESX

ESX garde ses items en base. Une ligne :

```sql
INSERT INTO items (name, label, weight, rare, can_remove)
VALUES ('phone', 'Téléphone', 1, 0, 1);
```

Sur un serveur ESX qui utilise ox_inventory, prenez l'entrée ox ci-dessus à la place :
ox_inventory lit son propre fichier, pas la table `items`.

Donner l'item à un joueur :

```
/giveitem 1 phone 1
```

### N'importe quel inventaire : faire ouvrir le téléphone

Le téléphone enregistre lui-même un item utilisable pour chaque inventaire qu'il détecte :
`ox_inventory`, `qs-inventory`, `ps-inventory`, `qb-inventory`, `origen_inventory`,
`codem-inventory`. Sur qb-core et qbx il passe par `CreateUseableItem`, sur ESX par
`ESX.RegisterUsableItem`, et sur ox_inventory il écoute `ox_inventory:usedItem` — sur tous
ceux-là, déclarer l'item suffit.

Si le vôtre n'y est pas, faites-lui appeler l'export client :

```lua
exports['v-phone']:Open()
```

`Config.Compat.inventory` accepte aussi un nom de ressource au lieu de `'auto'`, pour un fork
dont le bridge ne connaît pas le nom.

## Commandes admin

Derrière `Config.Admin.ace` (`vphone.admin` par défaut), ou le `qbadmin.menu` de qb-core. Tapez
`/phoneadmin` dans le chat et l'autocomplétion liste toutes les sous-commandes avec leurs
arguments — réservé au staff, donc un joueur qui ne peut pas les lancer ne se les voit jamais
proposer.

Chacune a son interrupteur dans `Config.Admin.actions` : une action que vous préférez ne pas
donner au staff est **retirée**, pas seulement supposée jamais tapée.

### Lire un téléphone

```
/phoneadmin info     [id|cid|numéro]      numéro, batterie, non lus, en ligne
/phoneadmin who                            tous ceux qui ont leur téléphone ouvert
/phoneadmin number   [id|cid]              lire un numéro
/phoneadmin contacts [id|cid]              lire le répertoire
/phoneadmin apps     [id|cid]              ce qui est installé
/phoneadmin bricked                        quels téléphones sont hors service
/phoneadmin outages                        quelles pannes sont en cours, et pour combien de temps
/phoneadmin verified (snap)                qui a un badge de certification
```

### Agir sur un téléphone

```
/phoneadmin open     [id]                  ouvrir son téléphone sur son écran (support)
/phoneadmin battery  [id] [0-100]
/phoneadmin number   [id|cid] [numéro]     définir un numéro
/phoneadmin message  [id|cid] [texte]      un SMS, de la part du Staff
/phoneadmin notify   [id|cid] [texte]      une bannière — ne persiste pas, ne vient d'aucun numéro
/phoneadmin app      [id|cid] give|take [appid]
/phoneadmin brick    [id|cid] (minutes)    mettre un combiné hors service
/phoneadmin unbrick  [id|cid]
/phoneadmin wipe     [id|cid] confirm      EFFACER tout sur ce téléphone. Irréversible
```

### Tout le serveur

```
/phoneadmin announce   [texte]             une bannière sur tous les téléphones connectés
/phoneadmin batteryall [0-100]
/phoneadmin outage     [barres 0-4] (minutes)            tout le serveur
/phoneadmin outage here [rayon] [barres] (minutes)       un cercle autour de vous
/phoneadmin outage at [x] [y] [z] [rayon] [barres] (minutes)
/phoneadmin outage clear [id|all]
```

Une panne est un **plafond en barres**, pas un interrupteur : une barre est une panne bien plus
intéressante que pas de téléphone, parce que les appels coupent et que les joueurs doivent se
déplacer pour être entendus. Elle passe par le même chemin que les zones mortes de la carte et
le pire l'emporte : une panne globale ne se contourne pas en se plaçant là où la réception est
parfaite. `minutes = 0`, ou omis, signifie jusqu'à ce que quelqu'un la lève. **Rien n'est
persisté** — un redémarrage lève toutes les pannes, volontairement, pour qu'une panne que
personne ne se rappelle avoir posée ne survive jamais à un crash.

`brick` est l'autre moitié : le réseau va bien, ce combiné non. Pour un téléphone cassé ou
confisqué. Indexé par citizen id, donc cela survit à une reconnexion, et un téléphone hors
service refuse de **s'ouvrir** au lieu de s'ouvrir sur des fonctions qui échouent en silence.

### Réseaux sociaux

```
/phoneadmin verify [@handle] (off) (snap)   attribuer ou retirer le badge de certification
```

Par handle plutôt que par personnage, parce qu'un badge appartient à un compte et qu'un
signalement contient le @handle. C'est un **export, jamais un callback** : un client ne peut pas
demander à être certifié.

### Commandes de tout le monde

```
/refreshphone      réinitialiser votre propre téléphone bloqué : prop, animation, focus NUI
/phonediag         staff uniquement, et seulement avec le debug actif : ce que répond chaque callback
```

Chaque commande staff refusée est imprimée dans la console du serveur avec l'identité de qui a
essayé.


## Support

| Vous voulez... | Allez à |
| --- | --- |
| Signaler un dysfonctionnement | [Rapport de bug](https://github.com/laforetbrut/v-phone-fivem/issues/new?template=01-bug.yml) |
| Une app ne lit pas votre inventaire / banque / logement | [Rapport de compatibilité](https://github.com/laforetbrut/v-phone-fivem/issues/new?template=02-compatibility.yml) |
| Proposer une fonctionnalité | [Demande de fonctionnalité](https://github.com/laforetbrut/v-phone-fivem/issues/new?template=03-feature.yml) |
| Corriger la documentation | [Documentation](https://github.com/laforetbrut/v-phone-fivem/issues/new?template=04-docs.yml) |
| Poser une question, être aidé à l'installation | [Discussions](https://github.com/laforetbrut/v-phone-fivem/discussions) |
| Signaler une vulnérabilité | [En privé](https://github.com/laforetbrut/v-phone-fivem/security/advisories/new) — jamais une issue publique |

Un rapport de bug a besoin des **deux** consoles (serveur et client F8) et d'étapes depuis une connexion propre.
Lisez [CONTRIBUTING.md](CONTRIBUTING.md) avant d'ouvrir une pull request.

## Licence

[MIT avec obligation d'attribution](LICENSE). Utilisez-le, modifiez-le, vendez votre serveur avec.

La seule chose que vous ne pouvez pas faire, c'est retirer le crédit que le téléphone montre au joueur dans **Réglages > À propos**. Habillez-le, traduisez-le, mettez vos propres crédits à côté. Ne le supprimez pas.

## Credits

Author: vyrriox

Bleeter, Snapmatic et Hush sont des marques de Grand Theft Auto V.
