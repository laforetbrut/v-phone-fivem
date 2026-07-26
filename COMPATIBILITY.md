# Compatibility

Every app, what it needs, and what it does on your server. Nothing here has to be
installed: an app whose data has no source is **not offered at all** rather than shown
empty, so a small server sees a smaller phone instead of a broken one.

Everything is detected at boot. `Config.Compat` overrides any of it, and
`Config.Compat.hooks` replaces any of it with your own function.

## The frameworks

| | qb-core / qbx_core | ox_core | ESX Legacy | Standalone |
|---|---|---|---|---|
| Player object | qb-core: `GetCoreObject`. qbx: `GetPlayer` export | `GetPlayer` / `CallPlayer` | `getSharedObject` | licence identifier |
| Character id | `citizenid` | `charId` | `identifier` | licence identifier |
| Name | `charinfo` | `firstName` / `lastName` | `getName()` | Steam / player name |
| Job | `PlayerData.job`, qbx via `GetJobs` | groups, minus `ignoredGroups` | `getJob()` | none |
| Phone number | `charinfo.phone`, reused | `characters.phoneNumber`, reused | minted by the phone | minted by the phone |
| Usable item | `CreateUseableItem` (both) | `ox_inventory:usedItem` | `RegisterUsableItem` | none |
| Preferences | `vphone_kv` | `vphone_kv` | `vphone_kv` | `vphone_kv` |

**qbx_core** ships no shared object: it exposes `GetPlayer`, `CreateUseableItem` and
`GetJobs` as direct exports. The bridge detects it as a qb-family framework and reaches
it the right way, so it is not a separate configuration.

**Preferences are never written into your framework's metadata.** They live in
`vphone_kv`, a table this resource owns, so a framework update cannot break the phone and
uninstalling the phone leaves your character rows untouched.

## App by app

| App | Needs | Sources it reads |
|---|---|---|
| **Phone** | nothing | Own tables. Voice through pma-voice or saltychat when present |
| **Messages** | nothing | Own tables |
| **Contacts** | nothing | Own tables |
| **Mail** | nothing | Own tables |
| **Notes** | nothing | Own tables |
| **Reminders** | nothing | Own tables |
| **Calculator** | nothing | none |
| **Camera** | `screenshot-basic` | Upload target from settings |
| **Gallery** | nothing | Own tables |
| **Settings** | nothing | Own tables |
| **FruitStore** | nothing | `Config.Apps` and `Config.Home` |
| **Bank** | a framework or a banking script | qs-banking `GetAccountBalance`, Renewed-Banking `getAccount`, qb `PlayerData.money`, ox accounts `GetCharacterAccount`, ESX accounts. Statements from qs-banking or Renewed-Banking |
| **Garage** | a garage script or its table | qs-advancedgarages `GetPlayerVehicles`, else `player_vehicles` (qb), `vehicles` (ox), `owned_vehicles` (ESX) |
| **Property** | a housing script | qs-housing `GetPlayerHouses`, ps-housing `properties`, esx_property `owned_properties`, or your configured table |
| **Wallet** | a framework | qb metadata `licences`/`licenses`, ox `character_licenses`, ESX `user_licenses` |
| **Jobs** | a framework | qb `Shared.Jobs`, ESX `jobs`, ox groups |
| **Health** | optional | Vitals from the game. Hunger and thirst from esx_status or state bags |
| **MDT** | a police job | `Config.Compat.policeJobs` |
| **Music** | [xsound](https://github.com/Xogy/xsound) (MIT), `rcore_radiocar`, `xdiskjockey`, or `Config.Music.hooks` | Always visible. With xsound the phone plays the track itself - headphones, speaker or car radio. With the other two it opens their interface and copies the link. With none, the library and playlists still work and the app says so. |
| **Bleeter / Snapmatic / Hush / Cipher** | nothing | Own tables. Downloads, not shipped |

## Battery charging

The phone charges in a vehicle, at a public charger from `Config.Chargers`, and inside a
property you have a key to. That last one only the housing script knows, so the client
works it out and reports it up a state bag the server reads.

| Housing | Read as |
|---|---|
| qs-housing (Quasar) | `getCurrentHouse()` is not nil |
| ps-housing | `state.currentApartment` / `state.property` |
| qb-houses | `state.inside` |
| ox_property | `state.inProperty` |
| loaf_housing | `state.inHouse` |
| anything else | `Config.Compat.hooks.atHome`, a client function of yours |

`Config.Compat.chargeAtProperty = false` leaves only vehicles and public chargers.

An external script can also charge the phone - an electric car, a solar pack - with
`exports['v-phone']:SetCharging(src, true, rate)`. See API.md.

## Admin

Staff actions on a player's phone, gated by `Config.Admin.ace` (default `vphone.admin`).
qb-core's own admin group and `command` aces are accepted too.

```
add_ace group.admin vphone.admin allow
```

`/phoneadmin info | open | battery | number | message | wipe`, and the same set as exports
(`AdminReadPhone`, `OpenPhoneFor`, `WipePhone`) for any framework's admin menu. On qb-core
the admin menu is detected and pointed at the command. `Config.Admin.actions` turns any
one off; `Config.Admin.confirmWipe` guards the destructive one.

## Police forensics

A warrant terminal at the points in `Config.Police.points`. Police in a job from
`Config.Police.jobs`, at or above `minGrade`, read a suspect's phone from the number:
texts, contacts, calls, social posts and DMs, all in the clear because that is how the
phone stores them. Every read is re-checked on the server and logged.

The terminal interaction uses a target script when one is running, otherwise a marker
and the E key:

| Target | How |
|---|---|
| ox_target | a box zone with a forensics option |
| qb-target / qtarget | a box zone with a forensics option |
| none | a blue marker, `[E]` to open |

**Cipher is end-to-end encrypted and the server holds no key**, so its content cannot be
read - by the police, or by the operator. The terminal shows the metadata that is
recoverable (who, when, key fingerprints). `Config.Police.cipher.intercept` (off by
default) changes that: the phone keeps a server-wrapped copy of each Cipher message so
the terminal can crack the content, slowly (`crackSeconds`) and not always
(`successChance`). Leaving it off keeps Cipher a true secret, which is the app's promise
to players.

## Media hosting

Off by default. Turn on `Config.Media.enabled` and install
[screencapture](https://github.com/itschip/screencapture) to capture photos and video
clips in game and upload them to a CDN. The upload runs on the server, so the API key
never reaches a client:

```
set phone_media_key "fm_xxxxxxxx"
```

| Setting | What |
|---|---|
| `provider` | `fivemanage` (wired), or `custom` for any multipart-file host |
| `endpoint` | the upload URL (Fivemanage v3 file API by default) |
| `video.maxSeconds` | clip length ceiling, 1..30 |
| `autoDeleteDays` | the phone drops each file after this many days, and deletes it from the host if `deleteEndpoint` is set |

**What FiveM can and cannot do, honestly:**

- **Photos** are real screen captures, uploaded and stored.
- **Video clips** are real WebM recordings through screencapture, capped and uploaded, and post to Bleeter and Snapmatic.
- **The front camera** (selfie) is a real game camera placed in front of the ped, so a photo or clip is of the player.
- **FaceTime** is a real voice call with an optional live picture. Turn on `Config.FaceTime.videoFeed` and, with [screenshot-basic](https://github.com/citizenfx/screenshot-basic) installed, each phone raises the front camera, captures a frame at `fps`, shrinks and crops it in the page to `width` x `height` at `quality`, and relays that thumbnail to the other participant only. It is bandwidth you are spending on every frame, so keep `fps` low and `maxFrameKb` tight; the feature is off by default and the call works without it.

## Integrations

| Kind | Detected, in order |
|---|---|
| Inventory | ox_inventory, qs-inventory, ps-inventory, qb-inventory, origen_inventory, codem-inventory |
| Banking | qs-banking, Renewed-Banking, qb-banking, okokBanking, esx_banking |
| Garage | qs-advancedgarages, jg-advancedgarages, qb-garages, cd_garage, okokGarage |
| Housing | qs-housing, ps-housing, qb-houses, ox_property, loaf_housing, esx_property |
| Voice | pma-voice, saltychat, mumble-voip |
| Notifications | ox_lib, qb-core, ESX, chat, or your own event |

Each is `auto`, an exact resource name, or `off`.

## Payphones

The call box props already on the map. There is **no coordinate list**: the client asks the
engine for the nearest booth prop, so `Config.Booth.models` is the only thing that decides
what counts as a booth, and a box in a new MLO works with no config change.

| Target | How |
|---|---|
| ox_target | `addModel` on every booth model, registered once, covering the whole map |
| qb-target / qtarget | `AddTargetModel` on the same list |
| none | a marker on the nearest box, `[E]` to use |

`Config.Booth.interact.target` overrides the detection: name a script to force it, or set it
to `off` to ignore target scripts entirely and always use the marker and key — which some
servers prefer even when they do run a target. The key, icon, label, marker type, colour,
scale, height and scan cadence are all configurable there too, and
`Config.Booth.blip` puts the boxes on the map (off by default: there are around a hundred
payphones in Los Santos).

A booth **places calls and never receives them**. That is enforced on the server three
independent ways, not left to the interface: a booth number never enters the online table,
is never written to `vphone_characters`, and both the call and the SMS paths refuse a
booth-shaped number outright. The number itself is derived from the prop's coordinates by a
pure function that the client and the server each compute for themselves, so a modified
client that forges its position gets a different booth number rather than a chosen one.

Calls run on the ordinary call machinery: the same `v-voice` channel, the same ring and
length limits, the same call-log row on the recipient's phone. The caller's phone item,
battery and signal are deliberately **not** checked - a payphone that only works when your
own phone does is pointless.

### The prepaid card

Talk time is held per character in `vphone_kv`, in seconds, and metered by the server one
second at a time. `Config.Booth.card.item` is an ordinary inventory item; declare it the way
your inventory declares any item.

**ox_inventory** — in `ox_inventory/data/items.lua`:

```lua
['prepaid_card'] = {
    label = 'Prepaid Calling Card',
    weight = 5,
    stack = true,
    close = true,
    description = 'Worth ten minutes at any payphone.',
},
```

**qb-core / qbx_core** — in `qb-core/shared/items.lua`:

```lua
prepaid_card = {
    name = 'prepaid_card', label = 'Prepaid Calling Card', weight = 5,
    type = 'item', image = 'prepaid_card.png', unique = false, useable = true,
    shouldClose = true, description = 'Worth ten minutes at any payphone.'
},
```

**ESX** — insert a row in the `items` table:

```sql
INSERT INTO items (name, label, weight, rare, can_remove) VALUES ('prepaid_card', 'Prepaid Calling Card', 1, 0, 1);
```

Set `Config.Booth.card.item = nil`, or `Config.Booth.costPerMinute = 0`, to run booths on
free calls with no item at all.

## Item checks

`Config.Settings.requireItem` decides whether a player must carry `Config.PhoneItem`. It is **on by default**, and `Config.Key = false` means the item is the only way in: the phone opens when you use it, like any other object. Mark the item `useable` in your framework's own catalogue as well.

| Inventory | Read as |
|---|---|
| ox_inventory | `GetItemCount(src, item)` |
| qs-inventory | `GetItemTotalAmount(src, item)` |
| ps / qb / origen / codem | `GetItemByName`, falling back to `GetItemCount` |
| none | the framework's own inventory, then "yes" rather than locking everyone out |

Using the item is registered with ox_inventory's `usedItem` event, qb's
`CreateUseableItem`, or ESX's `RegisterUsableItem`, whichever is there.

Consuming one - the power bank, a prepaid card - goes through `Bridge.RemoveItem`, which
covers the same inventories plus the qb and ESX player objects directly. It **fails closed**,
unlike the check above: a remove that cannot be confirmed grants nothing, so a card is never
paid out for an item that never left the inventory.

## The qb-phone drop-in

A stock qb-core server has eighteen resources that talk to `qb-phone`: job mail, police
dispatch, invoices, race results. Remove the stock phone, drop v-phone in, and every one of
them is talking to nobody. v-phone answers them itself — `Config.Compat.qbPhone`, on by
default, and it stands down automatically if the real qb-phone is running so the two never
double up.

One call cannot be covered from inside v-phone. A FiveM export belongs to a resource **name**,
and `exports['qb-phone']:sendNewMailToOffline(...)` is a hard call in qb-cityhall,
qb-vehiclesales and qb-weapons — it raises an error rather than passing quietly. So there is a
twenty-line resource in `compat/qb-phone` whose only job is to own the name and forward:

```
1. copy compat/qb-phone to your resources folder, e.g. resources/[phone]/qb-phone
2. in server.cfg:      ensure v-phone
                       ensure qb-phone
3. stop the stock qb-phone. Do not run both.
```

Order matters in the sense that `v-phone` must exist, but not in the sense you would expect:
the bridge decides who is in charge lazily, the first time it is asked, so `ensure v-phone`
before `ensure qb-phone` is correct and is what the snippet above does.

| qb-phone | v-phone does |
|---|---|
| `sendNewMailToOffline` / `sendNewEventMail` (export) | mail, via `compat/qb-phone` |
| `qb-phone:server:sendNewMail` | mail, addressed to the sender's own character |
| `qb-phone:client:addPoliceAlert` | dispatch banner + waypoint, gated on `Config.Compat.policeJobs` |
| `qb-phone:client:AcceptorDenyInvoice` | a banner stating the fine |
| `qb-phone:client:RemoveBankMoney` / `AddTransaction` | a bank banner |
| `qb-phone:client:CustomNotification` / `RaceNotify` / `NewMailNotify` | a banner |
| `qb-phone:client:GiveContactDetails` | both players get each other's number |
| `RefreshPhone`, `UpdateLapraces`, `UpdateMails`, `UpdateMessages`, `UpdateTweets` | nothing, deliberately — v-phone re-reads when an app opens |

qb writes mail bodies as small HTML; it is converted to text, so nobody reads `<br>` in their
inbox. v-phone addresses mail to a **mailbox**, so a character who has never opened the Mail
app has nowhere to receive one — those fall back to a service message instead of being
dropped.

**What is genuinely lost.** Mail buttons: qb-drugs uses one to hand over a delivery location,
and v-phone's Mail has no buttons. `Config.Compat.qbPhoneMailButtons` fires the event at the
recipient instead — off by default, because that payload arrives from a client. The invoice
accept/deny sheet becomes a notification. The crypto and racing histories the stock phone kept
are not carried over.

## Wiring your own

Any hook you fill is used instead of the detection above.

```lua
Config.Compat.hooks.balances = function(src)
    return { cash = exports['my-bank']:GetCash(src), bank = exports['my-bank']:GetBank(src) }
end
```

Available: `balances`, `transactions`, `vehicles`, `properties`, `licences`, `jobs`,
`status`.

---

# Compatibilité (Version Française)

Chaque application, ce dont elle a besoin, et ce qu'elle fait sur votre serveur. Rien
ici n'est obligatoire : une application dont la donnée n'a aucune source **n'est pas
proposée du tout** plutôt que montrée vide. Un petit serveur voit donc un téléphone plus
petit, pas un téléphone cassé.

Tout est détecté au démarrage. `Config.Compat` surcharge n'importe quoi, et
`Config.Compat.hooks` remplace n'importe quoi par votre propre fonction.

## Les frameworks

| | qb-core / qbx_core | ox_core | ESX Legacy | Autonome |
|---|---|---|---|---|
| Identifiant de personnage | `citizenid` | `charId` | `identifier` | identifiant de licence |
| Nom | `charinfo` | `firstName` / `lastName` | `getName()` | nom du joueur |
| Métier | `PlayerData.job` | groupes, moins `ignoredGroups` | `getJob()` | aucun |
| Numéro de téléphone | `charinfo.phone`, réutilisé | `characters.phoneNumber`, réutilisé | créé par le téléphone | créé par le téléphone |
| Préférences | `vphone_kv` | `vphone_kv` | `vphone_kv` | `vphone_kv` |

**Les préférences ne sont jamais écrites dans la metadata de votre framework.** Elles
vivent dans `vphone_kv`, une table que cette ressource possède : une mise à jour du
framework ne peut pas casser le téléphone, et désinstaller le téléphone laisse vos
lignes de personnage intactes.

## Application par application

| Application | Nécessite | Ce qu'elle lit |
|---|---|---|
| **Téléphone** | rien | Ses propres tables. Voix via pma-voice ou saltychat si présents |
| **Messages** | rien | Ses propres tables |
| **Contacts** | rien | Ses propres tables |
| **Mail** | rien | Ses propres tables |
| **Notes** | rien | Ses propres tables |
| **Rappels** | rien | Ses propres tables |
| **Calculatrice** | rien | aucune |
| **Appareil photo** | `screenshot-basic` | Cible d'upload définie dans les réglages |
| **Galerie** | rien | Ses propres tables |
| **Réglages** | rien | Ses propres tables |
| **FruitStore** | rien | `Config.Apps` et `Config.Home` |
| **Banque** | un framework ou un script bancaire | qs-banking `GetAccountBalance`, Renewed-Banking `getAccount`, qb `PlayerData.money`, comptes ox `GetCharacterAccount`, comptes ESX. Relevés depuis qs-banking ou Renewed-Banking |
| **Garage** | un script de garage ou sa table | qs-advancedgarages `GetPlayerVehicles`, sinon `player_vehicles` (qb), `vehicles` (ox), `owned_vehicles` (ESX) |
| **Logement** | un script de logement | qs-housing `GetPlayerHouses`, ps-housing `properties`, esx_property `owned_properties`, ou votre table configurée |
| **Portefeuille** | un framework | metadata qb `licences`/`licenses`, ox `character_licenses`, ESX `user_licenses` |
| **Emplois** | un framework | qb `Shared.Jobs`, ESX `jobs`, groupes ox |
| **Santé** | optionnel | Constantes depuis le jeu. Faim et soif via esx_status ou les state bags |
| **MDT** | un métier de police | `Config.Compat.policeJobs` |
| **Musique** | un script média | Masquée tant qu'aucun n'est branché via les hooks |
| **Bleeter / Snapmatic / Hush / Cipher** | rien | Leurs propres tables. Téléchargements, pas livrées |

## Intégrations

| Type | Détecté, dans cet ordre |
|---|---|
| Inventaire | ox_inventory, qs-inventory, ps-inventory, qb-inventory, origen_inventory, codem-inventory |
| Banque | qs-banking, Renewed-Banking, qb-banking, okokBanking, esx_banking |
| Garage | qs-advancedgarages, jg-advancedgarages, qb-garages, cd_garage, okokGarage |
| Logement | qs-housing, ps-housing, qb-houses, ox_property, loaf_housing, esx_property |
| Voix | pma-voice, saltychat, mumble-voip |
| Notifications | ox_lib, qb-core, ESX, chat, ou votre propre événement |

Chacune vaut `auto`, un nom de ressource exact, ou `off`.

## Cabines téléphoniques

Les props de cabine déjà présents sur la map. Il n'y a **aucune liste de coordonnées** : le
client demande au moteur le prop de cabine le plus proche, donc `Config.Booth.models` est la
seule chose qui décide ce qui compte comme une cabine, et une borne dans un nouvel MLO
fonctionne sans changer la config.

| Target | Comment |
|---|---|
| ox_target | `addModel` sur chaque modèle de cabine, enregistré une fois, couvrant toute la map |
| qb-target / qtarget | `AddTargetModel` sur la même liste |
| aucun | un marqueur sur la borne la plus proche, `[E]` pour utiliser |

`Config.Booth.interact.target` court-circuite la détection : nommez un script pour le forcer,
ou mettez `off` pour ignorer les target et toujours utiliser le marqueur et la touche — ce que
certains serveurs préfèrent même en faisant tourner un target. La touche, l'icône, le libellé,
le type de marqueur, sa couleur, son échelle, sa hauteur et la cadence de scan y sont aussi
configurables, et `Config.Booth.blip` place les bornes sur la carte (désactivé par défaut : il
y a une centaine de cabines à Los Santos).

Une cabine **passe des appels et n'en reçoit jamais**. C'est garanti côté serveur de trois
façons indépendantes, et non laissé à l'interface : un numéro de cabine n'entre jamais dans
la table des joueurs en ligne, n'est jamais écrit dans `vphone_characters`, et le chemin
d'appel comme le chemin SMS le refusent explicitement. Le numéro lui-même est dérivé des
coordonnées du prop par une fonction pure que le client et le serveur calculent chacun de
leur côté : un client modifié qui falsifie sa position obtient un autre numéro de cabine,
pas un numéro choisi.

Les appels utilisent la machinerie d'appel ordinaire : le même canal `v-voice`, les mêmes
limites de sonnerie et de durée, la même ligne de journal sur le téléphone du destinataire.
L'item téléphone, la batterie et le signal de l'appelant ne sont délibérément **pas**
vérifiés — une cabine qui ne fonctionne que quand votre propre téléphone fonctionne ne sert
à rien.

### La carte prépayée

Le temps de communication est conservé par personnage dans `vphone_kv`, en secondes, et
décompté par le serveur seconde par seconde. `Config.Booth.card.item` est un item
d'inventaire ordinaire ; déclarez-le comme votre inventaire déclare n'importe quel item.

**ox_inventory** — dans `ox_inventory/data/items.lua` :

```lua
['prepaid_card'] = {
    label = 'Carte telephonique prepayee',
    weight = 5,
    stack = true,
    close = true,
    description = 'Vaut dix minutes dans toute cabine.',
},
```

**qb-core / qbx_core** — dans `qb-core/shared/items.lua` :

```lua
prepaid_card = {
    name = 'prepaid_card', label = 'Carte telephonique prepayee', weight = 5,
    type = 'item', image = 'prepaid_card.png', unique = false, useable = true,
    shouldClose = true, description = 'Vaut dix minutes dans toute cabine.'
},
```

**ESX** — insérez une ligne dans la table `items` :

```sql
INSERT INTO items (name, label, weight, rare, can_remove) VALUES ('prepaid_card', 'Carte telephonique prepayee', 1, 0, 1);
```

Mettez `Config.Booth.card.item = nil`, ou `Config.Booth.costPerMinute = 0`, pour des cabines
en appels gratuits sans aucun item.

## Vérification de l'objet

`Config.Settings.requireItem` décide si un joueur doit porter `Config.PhoneItem`. Il est **activé par défaut**, et `Config.Key = false` fait de l'objet le seul accès : le téléphone s'ouvre quand on l'utilise, comme n'importe quel autre objet. Marquez aussi l'objet `useable` dans le catalogue de votre framework.

| Inventaire | Lu par |
|---|---|
| ox_inventory | `GetItemCount(src, item)` |
| qs-inventory | `GetItemTotalAmount(src, item)` |
| ps / qb / origen / codem | `GetItemByName`, avec repli sur `GetItemCount` |
| aucun | l'inventaire du framework, puis « oui » plutôt que de verrouiller tout le monde dehors |

L'utilisation de l'objet est enregistrée via l'événement `usedItem` d'ox_inventory, le
`CreateUseableItem` de qb, ou le `RegisterUsableItem` d'ESX, selon ce qui est présent.

La consommation d'un objet — la batterie externe, une carte prépayée — passe par
`Bridge.RemoveItem`, qui couvre les mêmes inventaires plus les objets joueur qb et ESX
directement. Contrairement à la vérification ci-dessus, elle **échoue en refusant** : un
retrait qui ne peut être confirmé n'accorde rien, donc aucune carte n'est payée pour un objet
qui n'a jamais quitté l'inventaire.

## Le remplacement de qb-phone

Un serveur qb-core standard a dix-huit ressources qui parlent à `qb-phone` : courriers de
métier, alertes police, factures, résultats de course. Retirez le téléphone d'origine, posez
v-phone, et toutes parlent dans le vide. v-phone y répond lui-même — `Config.Compat.qbPhone`,
activé par défaut, et il se retire automatiquement si le vrai qb-phone tourne, pour que les
deux ne fassent jamais double emploi.

Un appel ne peut pas être couvert depuis v-phone. Un export FiveM appartient à un **nom** de
ressource, et `exports['qb-phone']:sendNewMailToOffline(...)` est un appel dur dans
qb-cityhall, qb-vehiclesales et qb-weapons — il lève une erreur au lieu de passer en silence.
D'où une ressource de vingt lignes dans `compat/qb-phone` dont le seul rôle est de porter le
nom et de transmettre :

```
1. copiez compat/qb-phone dans vos ressources, ex. resources/[phone]/qb-phone
2. dans server.cfg :   ensure v-phone
                       ensure qb-phone
3. arrêtez le qb-phone d'origine. N'exécutez pas les deux.
```

L'ordre compte au sens où `v-phone` doit exister, mais pas au sens auquel on s'attend : le
pont décide qui commande paresseusement, à la première sollicitation. `ensure v-phone` avant
`ensure qb-phone` est donc correct, et c'est ce que fait l'extrait ci-dessus.

| qb-phone | ce que fait v-phone |
|---|---|
| `sendNewMailToOffline` / `sendNewEventMail` (export) | un courrier, via `compat/qb-phone` |
| `qb-phone:server:sendNewMail` | un courrier, adressé au personnage de l'expéditeur |
| `qb-phone:client:addPoliceAlert` | bannière + point GPS, filtré par `Config.Compat.policeJobs` |
| `qb-phone:client:AcceptorDenyInvoice` | une bannière annonçant l'amende |
| `qb-phone:client:RemoveBankMoney` / `AddTransaction` | une bannière bancaire |
| `qb-phone:client:CustomNotification` / `RaceNotify` / `NewMailNotify` | une bannière |
| `qb-phone:client:GiveContactDetails` | chacun reçoit le numéro de l'autre |
| `RefreshPhone`, `UpdateLapraces`, `UpdateMails`, `UpdateMessages`, `UpdateTweets` | rien, volontairement — v-phone relit à l'ouverture d'une app |

qb écrit ses courriers en petit HTML ; c'est converti en texte, pour que personne ne lise
`<br>` dans sa boîte. v-phone adresse le courrier à une **boîte aux lettres** : un personnage
qui n'a jamais ouvert l'app Mail n'a nulle part où le recevoir, et ces courriers-là basculent
en message de service plutôt que d'être perdus.

**Ce qui est réellement perdu.** Les boutons de courrier : qb-drugs s'en sert pour donner un
lieu de livraison, et le Mail de v-phone n'a pas de boutons. `Config.Compat.qbPhoneMailButtons`
déclenche l'événement chez le destinataire à la place — désactivé par défaut, parce que cette
charge utile vient d'un client. La feuille accepter/refuser d'une facture devient une
notification. Les historiques crypto et course que gardait le téléphone d'origine ne sont pas
repris.

## Brancher le vôtre

Tout hook que vous remplissez est utilisé à la place de la détection ci-dessus.

```lua
Config.Compat.hooks.balances = function(src)
    return { cash = exports['my-bank']:GetCash(src), bank = exports['my-bank']:GetBank(src) }
end
```

Disponibles : `balances`, `transactions`, `vehicles`, `properties`, `licences`, `jobs`,
`status`.
