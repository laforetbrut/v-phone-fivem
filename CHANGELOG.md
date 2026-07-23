# Changelog

All notable changes to v-phone are documented here.

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
- **Storage the phone owns** - Preferences, layouts, health records and photo lists live in `phone_kv`, keyed by character. Nothing is written into a framework's metadata column, so a framework update cannot break the phone.
- **Character projection** - The phone keeps `phone_characters`, refreshed from whichever framework is running, so a dozen queries that need a name or a date of birth do not have to be written in four dialects.
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
- **Un stockage qui appartient au téléphone** - Préférences, dispositions, dossiers de santé et listes de photos vivent dans `phone_kv`, par personnage. Rien n'est écrit dans la colonne metadata d'un framework, donc une mise à jour de celui-ci ne peut pas casser le téléphone.
- **Projection des personnages** - Le téléphone tient `phone_characters`, rafraîchie depuis le framework qui tourne, pour qu'une douzaine de requêtes ayant besoin d'un nom ou d'une date de naissance n'aient pas à être écrites en quatre dialectes.
- **Intégrations, détectées et surchargeables** - Inventaire (ox_inventory, qs-inventory, ps-inventory, qb-inventory, origen_inventory, codem-inventory), banque (Renewed-Banking, qb-banking, okokBanking, qs-banking, esx_banking), voix (pma-voice, saltychat, mumble-voip) et notifications (ox_lib, qb, ESX, chat, personnalisé). Chacune est `auto` par défaut, accepte un nom de ressource explicite, ou `off`.
- **Points d'accroche** - `Config.Compat.hooks` branche n'importe quelle application sur votre propre script en une fonction, plutôt qu'en forkant la ressource.
- **Les numéros rejoignent le framework** - Un personnage qui a déjà un numéro venu de qb ou d'ox le conserve, pour que tout script sachant le joindre le puisse encore. Un numéro créé par le téléphone est réécrit de la même façon.
- **Réglages depuis server.cfg** - Chaque clé de `Config.Settings` peut être surchargée par un convar : `set phone_battery false`.
- **Le système de design est embarqué** - Le thème fait partie de la ressource, le téléphone n'a donc aucune dépendance d'interface.

### Modifications

- **oxmysql est la seule dépendance obligatoire.** Tout le reste est optionnel et détecté.
- **Les applications se masquent plutôt que de casser.** Une application dont le script n'est pas installé n'est pas proposée : ni sur l'écran d'accueil, ni dans le magasin, ni dans la recherche.

---
