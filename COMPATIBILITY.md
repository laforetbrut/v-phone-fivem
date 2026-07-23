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
| **Music** | a media script | Hidden unless one is wired through the hooks |
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

## Item checks

`Config.Settings.requireItem` decides whether a player must carry `Config.PhoneItem`.

| Inventory | Read as |
|---|---|
| ox_inventory | `GetItemCount(src, item)` |
| qs-inventory | `GetItemTotalAmount(src, item)` |
| ps / qb / origen / codem | `GetItemByName`, falling back to `GetItemCount` |
| none | the framework's own inventory, then "yes" rather than locking everyone out |

Using the item is registered with ox_inventory's `usedItem` event, qb's
`CreateUseableItem`, or ESX's `RegisterUsableItem`, whichever is there.

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

## Vérification de l'objet

`Config.Settings.requireItem` décide si un joueur doit porter `Config.PhoneItem`.

| Inventaire | Lu par |
|---|---|
| ox_inventory | `GetItemCount(src, item)` |
| qs-inventory | `GetItemTotalAmount(src, item)` |
| ps / qb / origen / codem | `GetItemByName`, avec repli sur `GetItemCount` |
| aucun | l'inventaire du framework, puis « oui » plutôt que de verrouiller tout le monde dehors |

L'utilisation de l'objet est enregistrée via l'événement `usedItem` d'ox_inventory, le
`CreateUseableItem` de qb, ou le `RegisterUsableItem` d'ESX, selon ce qui est présent.

## Brancher le vôtre

Tout hook que vous remplissez est utilisé à la place de la détection ci-dessus.

```lua
Config.Compat.hooks.balances = function(src)
    return { cash = exports['my-bank']:GetCash(src), bank = exports['my-bank']:GetBank(src) }
end
```

Disponibles : `balances`, `transactions`, `vehicles`, `properties`, `licences`, `jobs`,
`status`.
