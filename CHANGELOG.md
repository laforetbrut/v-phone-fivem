# Changelog

All notable changes to v-phone are documented here.

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
