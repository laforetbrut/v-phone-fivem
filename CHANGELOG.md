# Changelog

All notable changes to v-phone are documented here.

---

## [1.0.4] - 2026-07-23

### Added (English first)

- **The phone charges inside a property you have a key to** - detected per housing script and reported up a replicated state bag the server reads. qs-housing (Quasar) via `getCurrentHouse()`, ps-housing, qb-houses, ox_property and loaf_housing each read their own way, and `Config.Compat.hooks.atHome` handles anything else. `Config.Compat.chargeAtProperty = false` turns it off.
- **Chargers and dead zones read straight from the config** - `Config.Chargers` and `Config.DeadZones` are the content now, so charging at a public charger and losing signal in a dead zone work without the map editor this build does not ship.

### Changed

- **qbx_core is reached the way qbx wants.** It ships no shared object, so `GetCoreObject` returns nothing on it - the player, the usable item and the job list came back empty. The bridge now uses qbx's direct exports (`GetPlayer`, `CreateUseableItem`, `GetJobs`) and classic qb-core's shared object, decided in one place so nothing else has to know the difference.
- **Every qb access goes through two helpers** - `Bridge.QBGetPlayer` and `Bridge.QBUsable` - so a future qb variant is one edit, not a dozen.
- **The repository is `v-phone-fivem`** - keeps the `v-phone` name people look for, findable by the framework.

### Fixed

- **A leftover seed call against v-world's editor tables** at boot. There is no editor and no v-world here; the config lists are the content, read straight from `Config`.

---

## [1.0.4] - 2026-07-23

### Ajouts (miroir français)

- **Le téléphone se charge à l'intérieur d'un logement dont vous avez la clé** - détecté par script de logement et remonté via un state bag répliqué que le serveur lit. qs-housing (Quasar) via `getCurrentHouse()`, ps-housing, qb-houses, ox_property et loaf_housing lisent chacun à leur façon, et `Config.Compat.hooks.atHome` gère le reste. `Config.Compat.chargeAtProperty = false` le désactive.
- **Bornes et zones blanches lues directement depuis la config** - `Config.Chargers` et `Config.DeadZones` sont désormais le contenu : recharger à une borne publique et perdre le réseau dans une zone blanche fonctionnent sans l'éditeur de carte que cette version ne livre pas.

### Modifications

- **qbx_core est atteint comme qbx le veut.** Il ne livre aucun objet partagé, donc `GetCoreObject` ne renvoie rien dessus : le joueur, l'objet utilisable et la liste des métiers revenaient vides. Le pont utilise maintenant les exports directs de qbx (`GetPlayer`, `CreateUseableItem`, `GetJobs`) et l'objet partagé du qb-core classique, décidé en un seul endroit pour que rien d'autre n'ait à connaître la différence.
- **Tout accès qb passe par deux helpers** - `Bridge.QBGetPlayer` et `Bridge.QBUsable` - pour qu'une future variante qb soit une modification, pas une douzaine.
- **Le dépôt est `v-phone-fivem`** - il garde le nom `v-phone` que les gens cherchent, trouvable par le framework.

### Correctifs

- **Un appel de seed résiduel vers les tables d'éditeur de v-world** au démarrage. Il n'y a ni éditeur ni v-world ici ; les listes de config sont le contenu, lues directement depuis `Config`.

---

## [1.0.3] - 2026-07-23

### Changed (English first)

- **Every table this resource creates now starts with `vphone_`.** The twenty seven tables were named `phone_`, `social_` and `hush_`, any of which could in principle collide with a table another script on the server owns. They cannot now: the prefix is this resource's and nobody else's.
- **An automatic migration** moves an earlier build's data to the new names at boot, once. It renames a table only when the old name exists, the new name does not, and the old name is one this resource is known to have created, so it can never touch a table that is not ours. A fresh server does nothing; a server with data keeps every message and contact. Verified on a live server: a legacy `phone_contacts` row survived the rename intact.

### Fixed

- **A leftover query against `world_apps`** - the phone tried to seed an app catalogue into a table that belonged to the framework this build no longer runs. It threw once per app at boot. That whole mechanism is gone: `Config.Apps` and `Config.Home` are the catalogue, read fresh every boot, and the one table this resource did not own is no longer touched.

---

## [1.0.3] - 2026-07-23

### Modifications (miroir français)

- **Toute table créée par cette ressource commence désormais par `vphone_`.** Les vingt-sept tables s'appelaient `phone_`, `social_` et `hush_`, dont chacune pouvait en principe entrer en collision avec la table d'un autre script du serveur. Ce n'est plus possible : le préfixe appartient à cette ressource et à personne d'autre.
- **Une migration automatique** déplace au démarrage, une seule fois, les données d'une version antérieure vers les nouveaux noms. Elle ne renomme une table que si l'ancien nom existe, que le nouveau n'existe pas, et que l'ancien nom est bien l'un de ceux que cette ressource crée : elle ne peut donc jamais toucher une table qui n'est pas la sienne. Un serveur neuf ne fait rien ; un serveur avec des données conserve chaque message et chaque contact. Vérifié sur un serveur vivant : une ligne héritée de `phone_contacts` a survécu intacte au renommage.

### Correctifs

- **Une requête résiduelle contre `world_apps`** - le téléphone tentait d'écrire un catalogue d'applications dans une table qui appartenait au framework que cette version ne fait plus tourner. Elle levait une erreur par application au démarrage. Tout ce mécanisme est supprimé : `Config.Apps` et `Config.Home` sont le catalogue, relu à chaque démarrage, et la seule table que cette ressource ne possédait pas n'est plus touchée.

---

## [1.0.2] - 2026-07-23

### Added (English first)

- **A documented integration API** - `server/api.lua` gathers everything another resource is meant to call into one file, and [API.md](API.md) documents all of it in both languages. Fifteen new server exports on top of the seventeen that existed: `IsPhoneOpen`, `GetOnlineNumbers`, `CitizenOfNumber`, `SetNumber`, `SendServiceMessage`, `UnreadCount`, `AddContact`, `RemoveContact`, `GetContacts`, `SetBattery`, `InstallApp`, `UninstallApp`, `NotifyCitizen`, `NotifyAll`, `SendMail`, `GetPhoneInfo`.
- **Three server events** - `v-phone:messageSent`, `v-phone:phoneOpened` and `v-phone:phoneClosed`, all carrying citizen ids so a listener survives a reconnect. There are deliberately not more: an event nobody fires is worse than no event at all.
- **A replicated state bag** - `Player(src).state.phoneOpen`, so another resource can ask whether the phone is up without a round trip.
- **`GetPhoneInfo`** - What the phone decided at boot: version, framework, inventory, number format, the app list. The first question when an integration misbehaves.

### Changed

- **Every screenshot is the same size.** They were ten different shapes between 407x809 and 437x825, so the README tables stepped. All ten are now 420x816 on one canvas, scaled and never stretched.
- **Documentation split by job** - README to decide, [COMPATIBILITY.md](COMPATIBILITY.md) to install, [API.md](API.md) to integrate, [DEVELOPERS.md](DEVELOPERS.md) to write an app.

### Fixed

- **`SendMail` wrote to columns that do not exist** and threw instead of returning. Mail is addressed to an address and needs two rows, the letter and the recipient's box line, which is what it does now. Caught by calling all thirty two exports on a live server rather than by reading them.
- **Two owners for one state bag key** - The client and the server both wrote `phoneOpen` with different replication. The server owns it now.

---

## [1.0.2] - 2026-07-23

### Ajouts (miroir français)

- **Une API d'intégration documentée** - `server/api.lua` rassemble en un fichier tout ce qu'une autre ressource peut appeler, et [API.md](API.md) documente l'ensemble dans les deux langues. Quinze nouveaux exports serveur en plus des dix-sept existants : `IsPhoneOpen`, `GetOnlineNumbers`, `CitizenOfNumber`, `SetNumber`, `SendServiceMessage`, `UnreadCount`, `AddContact`, `RemoveContact`, `GetContacts`, `SetBattery`, `InstallApp`, `UninstallApp`, `NotifyCitizen`, `NotifyAll`, `SendMail`, `GetPhoneInfo`.
- **Trois événements serveur** - `v-phone:messageSent`, `v-phone:phoneOpened` et `v-phone:phoneClosed`, tous porteurs d'identifiants de personnage : une écoute survit à une reconnexion. Il n'y en a volontairement pas plus, un événement que personne n'émet est pire que pas d'événement.
- **Un state bag répliqué** - `Player(src).state.phoneOpen`, pour qu'une autre ressource sache si le téléphone est ouvert sans aller-retour.
- **`GetPhoneInfo`** - Ce que le téléphone a décidé au démarrage : version, framework, inventaire, format de numéro, liste des applications. La première question quand une intégration se comporte mal.

### Modifications

- **Toutes les captures font la même taille.** Elles avaient dix formats différents, de 407x809 à 437x825, et les tableaux du README marchaient en escalier. Les dix sont désormais en 420x816 sur un canevas commun, mises à l'échelle sans jamais être déformées.
- **Documentation séparée par usage** - README pour choisir, [COMPATIBILITY.md](COMPATIBILITY.md) pour installer, [API.md](API.md) pour intégrer, [DEVELOPERS.md](DEVELOPERS.md) pour écrire une application.

### Correctifs

- **`SendMail` écrivait dans des colonnes inexistantes** et levait une erreur au lieu de renvoyer un résultat. Un mail s'adresse à une adresse et demande deux lignes, la lettre et la ligne de boîte du destinataire : c'est ce qu'il fait maintenant. Trouvé en appelant les trente-deux exports sur un serveur vivant, pas en les relisant.
- **Deux propriétaires pour une clé de state bag** - Le client et le serveur écrivaient tous deux `phoneOpen` avec des réplications différentes. Le serveur en est désormais le seul propriétaire.

---

## [1.0.1] - 2026-07-23

### Added (English first)

- **Audio files ship with the phone** - Fourteen WAV files: five ringtones, four alerts and five interface sounds. They are **generated, not sampled**, by `tools/make-sounds.py`, which renders the same melodies with harmonics and a real envelope. Nothing is taken from anywhere, so they are safe to redistribute.
- **Two new tones** - `signal`, a low two note ringtone for a phone that should not sound like a phone, and `note` as an alert.
- **Quasar throughout** - qs-banking (`GetAccountBalance`, statements), qs-housing (`GetPlayerHouses`), qs-advancedgarages (`GetPlayerVehicles`) and the corrected qs-inventory export (`GetItemTotalAmount`, which is not the name the other inventories use).
- **Garage and housing become their own integrations** - `Config.Compat.garage` and `Config.Compat.housing`, each `auto`, a resource name, or `off`.
- **Table names resolve per framework** - `auto` reads `player_vehicles` on qb, `vehicles` on ox and `owned_vehicles` on ESX, rather than shipping one name that is wrong on two servers out of three.
- **COMPATIBILITY.md** - What every app needs, what it reads on each ecosystem, and how to wire your own script in one function. Bilingual.

### Fixed

- **ESX vehicle models** - ESX stores the model inside a JSON blob rather than a column, so the garage app showed nothing readable. It is decoded now.
- **ox licences** - Read from `character_licenses` joined to `ox_licenses` for the label, instead of a qb shaped metadata key that ox does not have.
- **qb licences** - Both spellings, `licences` and `licenses`, are accepted, and the map is turned into the list the app draws.

---

## [1.0.1] - 2026-07-23

### Ajouts (miroir français)

- **Les fichiers audio sont livrés avec le téléphone** - Quatorze fichiers WAV : cinq sonneries, quatre alertes et cinq sons d'interface. Ils sont **générés, pas échantillonnés**, par `tools/make-sounds.py`, qui rend les mêmes mélodies avec des harmoniques et une vraie enveloppe. Rien n'est repris de nulle part, ils sont donc sûrs à redistribuer.
- **Deux nouvelles tonalités** - `signal`, une sonnerie grave à deux notes pour un téléphone qui ne doit pas sonner comme un téléphone, et `note` comme alerte.
- **Quasar partout** - qs-banking (`GetAccountBalance`, relevés), qs-housing (`GetPlayerHouses`), qs-advancedgarages (`GetPlayerVehicles`) et l'export qs-inventory corrigé (`GetItemTotalAmount`, qui n'est pas le nom qu'utilisent les autres inventaires).
- **Garage et logement deviennent leurs propres intégrations** - `Config.Compat.garage` et `Config.Compat.housing`, chacune `auto`, un nom de ressource, ou `off`.
- **Les noms de tables se résolvent par framework** - `auto` lit `player_vehicles` sur qb, `vehicles` sur ox et `owned_vehicles` sur ESX, au lieu de livrer un nom faux sur deux serveurs sur trois.
- **COMPATIBILITY.md** - Ce dont chaque application a besoin, ce qu'elle lit sur chaque écosystème, et comment brancher votre propre script en une fonction. Bilingue.

### Correctifs

- **Modèles de véhicules ESX** - ESX range le modèle dans un blob JSON plutôt que dans une colonne, l'application Garage n'affichait donc rien de lisible. Il est décodé maintenant.
- **Licences ox** - Lues depuis `character_licenses` jointe à `ox_licenses` pour le libellé, au lieu d'une clé de metadata au format qb qu'ox n'a pas.
- **Licences qb** - Les deux orthographes, `licences` et `licenses`, sont acceptées, et la table est transformée en la liste que l'application dessine.

---

## [1.0.0] - 2026-07-23

### Added (English first)

- **Framework agnostic** - The phone detects qb-core, qbx_core, ox_core or es_extended at boot and adapts. With none of them it runs standalone on the licence identifier. `Config.Framework` names one explicitly when the detection is not what you want.
- **One player object** - A bridge turns every framework's idea of a character into the same four things the phone reads: a stable id, a name, a job and a place to keep preferences.
- **Storage the phone owns** - Preferences, layouts, health records and photo lists live in `vphone_kv`, keyed by character. Nothing is written into a framework's metadata column, so a framework update cannot break the phone.
- **Character projection** - The phone keeps `vphone_characters`, refreshed from whichever framework is running, so a dozen queries that need a name or a date of birth do not have to be written in four dialects.
- **Integrations, detected and overridable** - Inventory (ox_inventory, qs-inventory, ps-inventory, qb-inventory, origen_inventory, codem-inventory), banking (Renewed-Banking, qb-banking, okokBanking, qs-banking, esx_banking), voice (pma-voice, saltychat, mumble-voip) and notifications (ox_lib, qb, ESX, chat, custom). Each is `auto` by default, takes an explicit resource name, or `off`.
- **Integration hooks** - `Config.Compat.hooks` points any app at your own script in one function, rather than forking the resource.
- **Numbers meet the framework halfway** - A character who already has a number from qb or ox keeps it, so every script that knows how to reach them still can. A number the phone mints is written back the same way.
- **Settings from server.cfg** - Every key in `Config.Settings` can be overridden with a convar: `set phone_battery false`.
- **The design system ships inside** - The theme is part of the resource, so the phone has no UI dependency.

### Changed

- **oxmysql is the only hard dependency.** Everything else is optional and detected.
- **Apps hide rather than break.** An app whose script is not installed is not offered: not on the home screen, not in the store, not in search.

---

## [1.0.0] - 2026-07-23

### Ajouts (miroir français)

- **Indépendant du framework** - Le téléphone détecte qb-core, qbx_core, ox_core ou es_extended au démarrage et s'y adapte. Sans aucun d'eux il tourne en autonome sur l'identifiant de licence. `Config.Framework` en nomme un explicitement quand la détection ne convient pas.
- **Un seul objet joueur** - Un pont transforme l'idée qu'a chaque framework d'un personnage en les quatre mêmes choses que lit le téléphone : un identifiant stable, un nom, un métier et un endroit où garder les préférences.
- **Un stockage qui appartient au téléphone** - Préférences, dispositions, dossiers de santé et listes de photos vivent dans `vphone_kv`, par personnage. Rien n'est écrit dans la colonne metadata d'un framework, donc une mise à jour de celui-ci ne peut pas casser le téléphone.
- **Projection des personnages** - Le téléphone tient `vphone_characters`, rafraîchie depuis le framework qui tourne, pour qu'une douzaine de requêtes ayant besoin d'un nom ou d'une date de naissance n'aient pas à être écrites en quatre dialectes.
- **Intégrations, détectées et surchargeables** - Inventaire (ox_inventory, qs-inventory, ps-inventory, qb-inventory, origen_inventory, codem-inventory), banque (Renewed-Banking, qb-banking, okokBanking, qs-banking, esx_banking), voix (pma-voice, saltychat, mumble-voip) et notifications (ox_lib, qb, ESX, chat, personnalisé). Chacune est `auto` par défaut, accepte un nom de ressource explicite, ou `off`.
- **Points d'accroche** - `Config.Compat.hooks` branche n'importe quelle application sur votre propre script en une fonction, plutôt qu'en forkant la ressource.
- **Les numéros rejoignent le framework** - Un personnage qui a déjà un numéro venu de qb ou d'ox le conserve, pour que tout script sachant le joindre le puisse encore. Un numéro créé par le téléphone est réécrit de la même façon.
- **Réglages depuis server.cfg** - Chaque clé de `Config.Settings` peut être surchargée par un convar : `set phone_battery false`.
- **Le système de design est embarqué** - Le thème fait partie de la ressource, le téléphone n'a donc aucune dépendance d'interface.

### Modifications

- **oxmysql est la seule dépendance obligatoire.** Tout le reste est optionnel et détecté.
- **Les applications se masquent plutôt que de casser.** Une application dont le script n'est pas installé n'est pas proposée : ni sur l'écran d'accueil, ni dans le magasin, ni dans la recherche.

---
