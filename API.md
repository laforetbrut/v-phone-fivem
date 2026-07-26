# API

Everything another resource can call. The implementation is one file,
[`server/api.lua`](server/api.lua), plus the exports the phone's own modules publish.

Three rules hold throughout:

1. **A citizen id or a number identifies a person, never a source.** A source changes
   every time somebody reconnects, and an integration written against one breaks
   quietly. Where a source is genuinely what you have, the export takes one.
2. **Nothing trusts its caller with identity.** You may send a message *as* a service
   you name, because a script that pays wages has to. You may not read somebody's
   conversations, because nothing needs to.
3. **Every call returns something checkable.** Failure is `false, reason`, never a
   silent nil.

## Server exports

### People and numbers

```lua
local phone = exports['v-phone']

phone:GetNumber(citizenid)              --> '555-0182' | nil
phone:FindByNumber(number)              --> source | nil      (online only)
phone:CitizenOfNumber(number)           --> citizenid | nil   (offline included)
phone:IsOnline(number)                  --> boolean
phone:IsOnCall(src)                     --> boolean
phone:IsPhoneOpen(src)                  --> boolean
phone:GetOnlineNumbers()                --> { [citizenid] = number }
phone:SetNumber(citizenid, number)      --> true | false, 'taken' | 'args'
```

### Messages

```lua
-- From one character to a number, exactly as if they had typed it.
phone:SendMessage(fromCitizenid, toNumber, body)      --> true | false, reason

-- From a NAME rather than a number: a shop, a dispatch, a bank. Nobody can call back
-- a service that cannot answer.
phone:SendServiceMessage(toCitizenid, 'LS Customs', 'Your car is ready.')

phone:UnreadCount(citizenid)            --> number
```

### Contacts

```lua
phone:AddContact(citizenid, name, number, favourite)  --> true | false, 'exists'
phone:RemoveContact(citizenid, number)                --> boolean
phone:GetContacts(citizenid)                          --> { { name, number, favourite } }
```

### Mail

```lua
phone:SendMail(toCitizenid, 'hr@lscustoms.com', 'Your shift', 'You start at 18:00.')
--> true | false, 'nomailbox'
```

### Notifications

```lua
phone:Notify(src, app, title, body)                   --> boolean
phone:NotifyCitizen(citizenid, app, title, body)      --> true | false, 'offline'
phone:NotifyAll(app, title, body)                     --> true
```

`app` is an app id, which decides the icon: `phone`, `messages`, `mail`, `bank`,
`bleeter`, or your own registered app.

### Battery and signal

```lua
phone:GetBattery(src)                   --> 0..100
phone:SetBattery(src, percent)          --> boolean
phone:AddBattery(src, delta)            --> boolean
phone:GetSignal(src)                    --> 0..4
phone:HasSignal(src)                    --> boolean
phone:SetScreenOn(src, on)
```

### Apps

```lua
-- Ship an app from your own resource. The phone serves your page in an iframe and
-- gives it the SDK; see DEVELOPERS.md for the page side.
phone:RegisterApp('mycompany', {
    label    = 'My Company',
    icon     = 'briefcase',
    page     = 'https://cfx-nui-my-resource/html/app.html',
    category = 'work',
    job      = 'mycompany',      -- optional: only this job sees it
    optional = true,             -- a download rather than shipped
})
phone:UnregisterApp('mycompany')
phone:GetApps(src)               --> what this player may see

-- Put an optional app on somebody's phone without making them find it in the store.
phone:InstallApp(citizenid, 'mdt')      --> true | false, 'exists'
phone:UninstallApp(citizenid, 'mdt')    --> true | false, 'missing'
```

### Social

```lua
phone:SocialHandle(citizenid, 'bleeter')                 --> '@handle' | nil
phone:SocialPostAs(citizenid, 'text', 'Body', imageUrl)  --> boolean
```

### Diagnostics

```lua
phone:GetPhoneInfo()
--> {
--     version = '1.0.2', framework = 'qb', frameworkResource = 'qb-core',
--     inventory = 'ox_inventory', numberFormat = '555-####',
--     apps = { 'phone', 'messages', ... }, social = true,
--   }
```

Useful in a `/phonedebug` command: it says what the phone decided at boot, which is the
first question when an integration is not behaving.

### External charging

For a vehicle script (an electric car), a solar backpack, a wall socket prop. While it is
on, the phone charges as if at a charger. `rate` is a multiplier: 1.0 is a wall charger,
2.0 twice as fast, capped by `Config.ExternalCharging.maxRate`.

```lua
phone:SetCharging(src, true, 1.5)   -- plugged in
phone:SetCharging(src, false)       -- unplugged
phone:IsCharging(src)               --> boolean
```

### Payphones

Talk time is held per character, in seconds, and spent by the booth's own meter. Use these
for a shop that sells calling cards, a reward, or an admin command.

```lua
phone:GetBoothCredit(src)            --> seconds of talk time
phone:AddBoothCredit(src, 600)       --> new balance, after adding ten minutes
phone:AddBoothCredit(src, -120)      --> and a negative takes time away
```

`AddBoothCredit` clamps to `Config.Booth.card.maxCredit` and pushes the new balance to any
booth panel the player has open, so the meter never shows a figure the server has moved on
from.

A booth's number is a pure function of where the box stands, so anything that knows the
coordinates can name the box - a dispatch logging which payphone a tip came from, for
instance. And because a payphone can never be rung, `IsBoothNumber` is the test to run
before you try:

```lua
phone:BoothNumberAt(215.5, -810.2, 30.7)   --> '311-4827', always the same for that box
phone:IsBoothNumber('311-4827')            --> true
phone:IsBoothNumber('555-0142')            --> false
```

### Admin

Every action is also behind `/phoneadmin` and the qb-core admin menu, gated by
`Config.Admin.ace`. Call them from your own admin menu on any framework.

```lua
phone:AdminReadPhone(citizenid)     --> { name, number, battery, unread, online, open, handles }
phone:OpenPhoneFor(src)             --> true | false, 'offline'   (support: see their screen)
phone:WipePhone(citizenid)          --> true, rowsRemoved        (IRREVERSIBLE)
```

### Network outages

The phone decides signal from the player's real position, and the worst ceiling always
wins. An outage is a ceiling with an operator behind it instead of a map, so it obeys the
same rule: a global outage at zero bars cannot be escaped by standing somewhere the map
calls perfect reception.

Bars rather than on/off, because *one bar* is a more interesting outage than *no phone*:
calls drop, messages fail, and players have to move to be heard.

```lua
phone:AddOutage(bars, minutes, reason)                         --> id   (whole server)
phone:AddOutage(0, 20, 'heist', { x = 250.0, y = -1000.0, z = 30.0, radius = 120.0 })
phone:ClearOutage(id)     -- or 'all'                          --> how many went
phone:GetOutages()                                             --> a list, with seconds left
```

`minutes = 0` means *until somebody clears it*, which is what a heist jammer wants.
**Nothing is persisted**: a restart clears every outage, deliberately, so an outage nobody
remembers setting can never survive a crash.

### A handset out of service

Not an outage - the network is fine, this phone is not. A phone that was smashed, a phone
confiscated at booking, a phone that has to be dead for a scene. Keyed by citizen id, so it
survives the player reconnecting, which is the point of confiscating something.

```lua
phone:BrickPhone(citizenid, minutes, reason)   -- 0 minutes: until unbricked
phone:UnbrickPhone(citizenid)
phone:IsPhoneBricked(citizenid)                --> boolean
```

A bricked phone refuses to open at all rather than opening onto features that quietly fail:
a phone that answers nothing reads as a broken script, and the player reports it as a bug
instead of playing the scene.

### Import / export

For a character transfer, a backup, or a support restore. Export is a plain table; import
writes it back under a citizen id. Contacts, notes, app data, preferences and the mailbox
travel; the phone number does not, because a number belongs to the server that minted it.

```lua
local data = phone:ExportPhone(citizenid)          -- a table you can store as JSON
phone:ImportPhone(otherCitizenid, data, true)      -- true replaces existing rows first
```

## Client exports

```lua
local phone = exports['v-phone']

phone:IsOpen()          --> boolean
phone:Open()
phone:Close()
phone:GetNumber()       --> the local player's number
phone:OnCall()          --> boolean
```

## Commands

```
/refreshphone     tear down a stuck phone: prop, animation, NUI focus, control guard
/refresh-phone    same, the other spelling
/phoneadmin ...   staff actions, behind Config.Admin.ace
```

### /phoneadmin

```
info     [id|cid|number]                     number, battery, unread, online
who                                          everybody with a phone open right now
number   [id|cid]                             read it
contacts [id|cid]                             read the contact book
apps     [id|cid]                             what is installed
open     [id]                                open their phone on their screen
battery  [id] [0-100]
batteryall [0-100]                            every phone online
number   [id|cid] [number]                    set it
message  [id|cid] [text]                     a text message, from Staff
notify   [id|cid] [text]                     a banner, which does not persist
announce [text]                               that banner, to everybody online
app      [id|cid] give|take [appid]

outage   [bars 0-4] (minutes)                the whole server
outage   here [radius] [bars] (minutes)      a circle around you
outage   at [x] [y] [z] [radius] [bars] (minutes)
outage   clear [id|all]
outages                                      what is in force, and for how long

brick    [id|cid] (minutes)                  take one handset out of service
unbrick  [id|cid]
bricked                                      who is out of service

verify   [@handle] (off) (snap)              the verified badge
verified (snap)
wipe     [id|cid] confirm                    IRREVERSIBLE
```

Each subcommand has its own switch in `Config.Admin.actions`, so an action you do not want
staff to have can be removed entirely rather than trusted not to be typed.

**Permission.** `Config.Admin.ace` (default `vphone.admin`), or qb-core's `qbadmin.menu`:

```
add_ace group.admin vphone.admin allow
```

The bare `command` ace used to be accepted as well and no longer is. It is true for anybody
granted *any* command at all, which on many servers includes moderators, trusted players
and donors - none of whom were meant to be able to wipe a character's phone or cut the
network. `Config.Admin.aceCommandFallback = true` puts it back if your staff genuinely have
no other ace. Every refusal is printed to the server console with who tried it.

`refreshphone` is safe for any player to run: it only resets their own phone, for when it
sticks to the hand or an animation freezes. The server can trigger the same reset on a
player with `TriggerClientEvent('v-phone:client:forceReset', src)`.

## Server events

Listen rather than poll. All three carry citizen ids, so a listener survives a
reconnect.

```lua
AddEventHandler('v-phone:messageSent', function(fromCid, toCid, body, kind) end)
AddEventHandler('v-phone:phoneOpened', function(src, citizenid) end)
AddEventHandler('v-phone:phoneClosed', function(src, citizenid) end)
```

There are deliberately not more: an event nobody fires is worse than no event at all.

## State bags

```lua
Player(src).state.phoneOpen     -- replicated, true while the phone is up
LocalPlayer.state.invBusy       -- set by the phone so inventories stay shut
```

## Integration hooks

Anything the phone reads from your ecosystem can be replaced by a function of yours, in
`config.lua`. Yours wins over every detection.

```lua
Config.Compat.hooks.balances = function(src)
    return { cash = exports['my-bank']:GetCash(src), bank = exports['my-bank']:GetBank(src) }
end

Config.Compat.hooks.vehicles = function(citizenid, src)
    return exports['my-garage']:ListOwned(citizenid)
end
```

| Hook | Signature | Returns |
|---|---|---|
| `balances` | `(src)` | `{ cash, bank }` |
| `transactions` | `(src, citizenid)` | `{ { label, amount, at } }` |
| `vehicles` | `(citizenid, src)` | `{ { plate, model, garage, state } }` |
| `properties` | `(citizenid, src)` | `{ { label, address } }` |
| `licences` | `(src, citizenid)` | `{ { type, label } }` |
| `jobs` | `()` | `{ { name, label, grades } }` |
| `status` | `(src)` | `{ hunger, thirst }` |

See [COMPATIBILITY.md](COMPATIBILITY.md) for what each app reads when you fill none of
them, and [DEVELOPERS.md](DEVELOPERS.md) for writing an app that lives inside the phone.

---

# API (Version Française)

Tout ce qu'une autre ressource peut appeler. L'implémentation tient dans un fichier,
[`server/api.lua`](server/api.lua), plus les exports que publient les modules du
téléphone.

Trois règles valent partout :

1. **Un identifiant de personnage ou un numéro désigne une personne, jamais un source.**
   Un source change à chaque reconnexion, et une intégration écrite dessus casse en
   silence. Là où un source est vraiment ce dont vous disposez, l'export en prend un.
2. **Rien ne fait confiance à l'appelant sur l'identité.** Vous pouvez envoyer un
   message *au nom* d'un service que vous nommez, parce qu'un script qui verse des
   salaires en a besoin. Vous ne pouvez pas lire les conversations de quelqu'un, parce
   que rien n'en a besoin.
3. **Chaque appel renvoie quelque chose de vérifiable.** Un échec est `false, raison`,
   jamais un nil silencieux.

## Exports serveur

### Personnes et numéros

```lua
local phone = exports['v-phone']

phone:GetNumber(citizenid)              --> '555-0182' | nil
phone:FindByNumber(number)              --> source | nil      (en ligne uniquement)
phone:CitizenOfNumber(number)           --> citizenid | nil   (hors ligne compris)
phone:IsOnline(number)                  --> booleen
phone:IsOnCall(src)                     --> booleen
phone:IsPhoneOpen(src)                  --> booleen
phone:GetOnlineNumbers()                --> { [citizenid] = numero }
phone:SetNumber(citizenid, number)      --> true | false, 'taken' | 'args'
```

### Messages

```lua
-- D'un personnage vers un numero, exactement comme s'il l'avait tape.
phone:SendMessage(fromCitizenid, toNumber, body)      --> true | false, raison

-- Depuis un NOM plutot qu'un numero : une boutique, un dispatch, une banque. Personne
-- ne peut rappeler un service incapable de repondre.
phone:SendServiceMessage(toCitizenid, 'LS Customs', 'Votre voiture est prete.')

phone:UnreadCount(citizenid)            --> nombre
```

### Contacts

```lua
phone:AddContact(citizenid, name, number, favourite)  --> true | false, 'exists'
phone:RemoveContact(citizenid, number)                --> booleen
phone:GetContacts(citizenid)                          --> { { name, number, favourite } }
```

### Mail

```lua
phone:SendMail(toCitizenid, 'rh@lscustoms.com', 'Votre service', 'Vous commencez a 18h.')
--> true | false, 'nomailbox'
```

### Notifications

```lua
phone:Notify(src, app, title, body)                   --> booleen
phone:NotifyCitizen(citizenid, app, title, body)      --> true | false, 'offline'
phone:NotifyAll(app, title, body)                     --> true
```

`app` est un identifiant d'application, qui decide de l'icone : `phone`, `messages`,
`mail`, `bank`, `bleeter`, ou votre propre application enregistree.

### Batterie et reseau

```lua
phone:GetBattery(src)                   --> 0..100
phone:SetBattery(src, percent)          --> booleen
phone:AddBattery(src, delta)            --> booleen
phone:GetSignal(src)                    --> 0..4
phone:HasSignal(src)                    --> booleen
phone:SetScreenOn(src, on)
```

### Applications

```lua
-- Livrez une application depuis votre propre ressource. Le telephone sert votre page
-- dans une iframe et lui donne le SDK ; voir DEVELOPERS.md pour le cote page.
phone:RegisterApp('mycompany', {
    label    = 'Mon Entreprise',
    icon     = 'briefcase',
    page     = 'https://cfx-nui-my-resource/html/app.html',
    category = 'work',
    job      = 'mycompany',      -- optionnel : seul ce metier la voit
    optional = true,             -- un telechargement plutot qu'une app livree
})
phone:UnregisterApp('mycompany')
phone:GetApps(src)               --> ce que ce joueur peut voir

-- Poser une application optionnelle sur le telephone de quelqu'un sans qu'il ait a la
-- chercher dans le magasin.
phone:InstallApp(citizenid, 'mdt')      --> true | false, 'exists'
phone:UninstallApp(citizenid, 'mdt')    --> true | false, 'missing'
```

### Social

```lua
phone:SocialHandle(citizenid, 'bleeter')                 --> '@pseudo' | nil
phone:SocialPostAs(citizenid, 'text', 'Contenu', imageUrl)  --> booleen
```

### Diagnostic

```lua
phone:GetPhoneInfo()
```

Utile dans une commande `/phonedebug` : il dit ce que le telephone a decide au
demarrage, ce qui est la premiere question quand une integration se comporte mal.

### Recharge externe

Pour un script de vehicule (voiture electrique), un sac solaire, une prise murale. Tant
que c'est actif, le telephone se recharge comme a une borne. `rate` est un multiplicateur :
1.0 est une borne murale, 2.0 deux fois plus vite, plafonne par `Config.ExternalCharging.maxRate`.

```lua
phone:SetCharging(src, true, 1.5)   -- branche
phone:SetCharging(src, false)       -- debranche
phone:IsCharging(src)               --> booleen
```

### Cabines telephoniques

Le temps de communication est conserve par personnage, en secondes, et depense par le
compteur de la cabine. Utilisez ces exports pour une boutique qui vend des cartes, une
recompense, ou une commande admin.

```lua
phone:GetBoothCredit(src)            --> secondes de credit
phone:AddBoothCredit(src, 600)       --> nouveau solde, apres dix minutes ajoutees
phone:AddBoothCredit(src, -120)      --> et un negatif retire du temps
```

`AddBoothCredit` plafonne a `Config.Booth.card.maxCredit` et pousse le nouveau solde vers
toute cabine ouverte par le joueur : le compteur n'affiche donc jamais une valeur que le
serveur a deja depassee.

Le numero d'une cabine est une fonction pure de sa position : tout ce qui connait les
coordonnees peut nommer la borne - un dispatch qui journalise de quelle cabine vient un
tuyau, par exemple. Et comme une cabine ne peut jamais etre appelee, `IsBoothNumber` est le
test a lancer avant d'essayer :

```lua
phone:BoothNumberAt(215.5, -810.2, 30.7)   --> '311-4827', toujours le meme pour cette borne
phone:IsBoothNumber('311-4827')            --> true
phone:IsBoothNumber('555-0142')            --> false
```

### Admin

Chaque action est aussi derriere `/phoneadmin` et le menu admin qb-core, protegee par
`Config.Admin.ace`. Appelez-les depuis votre propre menu admin sur n'importe quel framework.

```lua
phone:AdminReadPhone(citizenid)     --> { name, number, battery, unread, online, open, handles }
phone:OpenPhoneFor(src)             --> true | false, 'offline'   (support : voir son ecran)
phone:WipePhone(citizenid)          --> true, rowsRemoved        (IRREVERSIBLE)
```

### Import / export

Pour un transfert de personnage, une sauvegarde, une restauration. L'export est une table
simple ; l'import la reecrit sous un citizen id. Contacts, notes, donnees d'app, preferences
et boite mail voyagent ; le numero non, car un numero appartient au serveur qui l'a cree.

```lua
local data = phone:ExportPhone(citizenid)          -- une table stockable en JSON
phone:ImportPhone(autreCitizenid, data, true)      -- true remplace les lignes existantes
```

## Exports client

```lua
local phone = exports['v-phone']

phone:IsOpen()          --> booleen
phone:Open()
phone:Close()
phone:GetNumber()       --> le numero du joueur local
phone:OnCall()          --> booleen
```

## Evenements serveur

Ecoutez plutot que d'interroger. Les trois portent des identifiants de personnage, une
ecoute survit donc a une reconnexion.

```lua
AddEventHandler('v-phone:messageSent', function(fromCid, toCid, body, kind) end)
AddEventHandler('v-phone:phoneOpened', function(src, citizenid) end)
AddEventHandler('v-phone:phoneClosed', function(src, citizenid) end)
```

Il n'y en a volontairement pas plus : un evenement que personne n'emet est pire que pas
d'evenement du tout.

## State bags

```lua
Player(src).state.phoneOpen     -- replique, vrai tant que le telephone est ouvert
LocalPlayer.state.invBusy       -- pose par le telephone pour que les inventaires restent fermes
```

## Points d'accroche

Tout ce que le telephone lit dans votre ecosysteme peut etre remplace par une fonction a
vous, dans `config.lua`. La votre l'emporte sur toute detection.

```lua
Config.Compat.hooks.balances = function(src)
    return { cash = exports['my-bank']:GetCash(src), bank = exports['my-bank']:GetBank(src) }
end
```

| Hook | Signature | Renvoie |
|---|---|---|
| `balances` | `(src)` | `{ cash, bank }` |
| `transactions` | `(src, citizenid)` | `{ { label, amount, at } }` |
| `vehicles` | `(citizenid, src)` | `{ { plate, model, garage, state } }` |
| `properties` | `(citizenid, src)` | `{ { label, address } }` |
| `licences` | `(src, citizenid)` | `{ { type, label } }` |
| `jobs` | `()` | `{ { name, label, grades } }` |
| `status` | `(src)` | `{ hunger, thirst }` |

Voir [COMPATIBILITY.md](COMPATIBILITY.md) pour ce que lit chaque application quand vous
n'en remplissez aucun, et [DEVELOPERS.md](DEVELOPERS.md) pour ecrire une application qui
vit dans le telephone.
