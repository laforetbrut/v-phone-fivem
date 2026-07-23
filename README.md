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
- **Sound**: fourteen audio files ship with the phone, five ringtones, four alerts and five interface sounds. They are generated rather than sampled, so a melody is a table in `tools/make-sounds.py` and nothing is taken from anywhere.
- **In hand**: a prop, an animation, and a phone that keeps working while you walk and drive.
- **Battery** with charging in a vehicle, at a public charger, and inside a property you have a key to (Quasar housing and the rest). Power banks and a low battery warning.
- **Police forensics**: a warrant terminal at a map point where police read a suspect's texts, contacts, calls and social from the number. Cipher stays end-to-end encrypted, with an optional, deliberately hard lawful-intercept crack.
- **`/refreshphone`**: a get-out-of-jail command for a phone stuck to the hand or a frozen animation.
- **Media hosting**: photos and short video clips captured in game and uploaded to a CDN (Fivemanage), with a per-file auto-delete clock. Clips post to Bleeter and Snapmatic.
- **Front camera**: a selfie mode - a game camera in front of you - for photos and clips of yourself.
- **FaceTime**: a real video call. With `Config.FaceTime.videoFeed` on, the front camera goes up and a shrunk, cropped frame of each player is relayed to the other a few times a second, over the normal voice call. Needs [screenshot-basic](https://github.com/citizenfx/screenshot-basic); off by default.

### The apps
Phone, Messages, Contacts, Mail, Maps, Camera, Gallery, Music, Garage, Property, Wallet, Jobs, Health, Notes, Reminders, Calculator, MDT, FruitStore, Settings, plus four downloads: Bleeter, Snapmatic, Hush and Cipher.

- **Phone**: keypad, favourites, history, voicemail, speaker mode heard by nearby players.
- **Messages**: private and group threads, photos, GIFs, location sharing, reactions, forwarding and emoji.
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
| [ox_lib](https://github.com/overextended/ox_lib) | nicer notifications | overextended/ox_lib |
| [ox_target](https://github.com/overextended/ox_target) | targeting the police forensics terminal | overextended/ox_target |
| A framework | jobs, money, licences, character names | [qb-core](https://github.com/qbcore-framework/qb-core) · [qbx_core](https://github.com/Qbox-project/qbx_core) · [ox_core](https://github.com/overextended/ox_core) · [es_extended](https://github.com/esx-framework/esx_core) |

Inventory, banking, garage and housing scripts are detected too - see [COMPATIBILITY.md](COMPATIBILITY.md) for the full list and the exact resource names.

## Installation

1. Install [oxmysql](https://github.com/overextended/oxmysql). It is the only hard requirement.
2. Drop this folder into your `resources` directory.
3. Add it to your `server.cfg`, after your framework:

   ```
   ensure oxmysql
   ensure v-phone
   ```

4. Start the server once. Every table is created automatically.
5. Open `config.lua` and read the `COMPATIBILITY` section at the top. On most servers you will not need to change anything.

Optional, from `server.cfg`:

```
set phone_locale "en"        # or fr
set phone_battery false      # any Config.Settings key, prefixed with phone_
set phone_requireItem true   # the player must carry the phone item
```

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
- **Son** : quatorze fichiers audio sont livrés avec le téléphone, cinq sonneries, quatre alertes et cinq sons d'interface. Ils sont générés plutôt qu'échantillonnés : une mélodie est une table dans `tools/make-sounds.py` et rien n'est repris de nulle part.
- **En main** : un prop, une animation, et un téléphone qui continue de fonctionner en marchant et en conduisant.
- **Batterie** avec recharge dans un véhicule, à une borne publique, et à l'intérieur d'un logement dont vous avez la clé (Quasar housing et les autres). Batteries externes et alerte de batterie faible.
- **Enquête police** : un terminal d'analyse à un point de la carte où la police lit les SMS, contacts, appels et réseaux d'un suspect à partir du numéro. Cipher reste chiffré de bout en bout, avec une interception légale optionnelle et volontairement difficile.
- **`/refreshphone`** : une commande de secours quand le téléphone reste collé à la main ou qu'une animation se fige.
- **Hébergement média** : photos et courts clips vidéo capturés en jeu et envoyés vers un CDN (Fivemanage), avec une horloge de suppression automatique par fichier. Les clips se publient sur Bleeter et Snapmatic.
- **Caméra frontale** : un mode selfie - une caméra de jeu devant vous - pour se photographier et se filmer.
- **FaceTime** : un vrai appel vidéo. Avec `Config.FaceTime.videoFeed` activé, la caméra frontale se lève et une image réduite et recadrée de chaque joueur est relayée à l'autre plusieurs fois par seconde, par-dessus l'appel vocal normal. Nécessite [screenshot-basic](https://github.com/citizenfx/screenshot-basic) ; désactivé par défaut.

### Les applications
Téléphone, Messages, Contacts, Mail, Plans, Appareil photo, Galerie, Musique, Garage, Logement, Portefeuille, Emplois, Santé, Notes, Rappels, Calculatrice, MDT, FruitStore, Réglages, plus quatre téléchargements : Bleeter, Snapmatic, Hush et Cipher.

- **Téléphone** : clavier, favoris, historique, répondeur, haut-parleur entendu par les joueurs autour.
- **Messages** : conversations privées et groupées, photos, GIF, partage de position, réactions, transfert et emoji.
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
| [ox_lib](https://github.com/overextended/ox_lib) | de plus belles notifications | overextended/ox_lib |
| [ox_target](https://github.com/overextended/ox_target) | le ciblage du terminal d'enquête police | overextended/ox_target |
| Un framework | métiers, argent, licences, noms de personnage | [qb-core](https://github.com/qbcore-framework/qb-core) · [qbx_core](https://github.com/Qbox-project/qbx_core) · [ox_core](https://github.com/overextended/ox_core) · [es_extended](https://github.com/esx-framework/esx_core) |

Les scripts d'inventaire, de banque, de garage et de logement sont aussi détectés - voir [COMPATIBILITY.md](COMPATIBILITY.md) pour la liste complète et les noms exacts.

## Installation

1. Installez [oxmysql](https://github.com/overextended/oxmysql). C'est la seule dépendance obligatoire.
2. Déposez ce dossier dans votre répertoire `resources`.
3. Ajoutez-le à votre `server.cfg`, après votre framework :

   ```
   ensure oxmysql
   ensure v-phone
   ```

4. Démarrez le serveur une fois. Toutes les tables sont créées automatiquement.
5. Ouvrez `config.lua` et lisez la section `COMPATIBILITY` en haut. Sur la plupart des serveurs vous n'aurez rien à changer.

Optionnel, depuis `server.cfg` :

```
set phone_locale "fr"
set phone_battery false      # n'importe quelle clé de Config.Settings, préfixée par phone_
set phone_requireItem true   # le joueur doit porter l'objet téléphone
```

## Licence

[MIT avec obligation d'attribution](LICENSE). Utilisez-le, modifiez-le, vendez votre serveur avec.

La seule chose que vous ne pouvez pas faire, c'est retirer le crédit que le téléphone montre au joueur dans **Réglages > À propos**. Habillez-le, traduisez-le, mettez vos propres crédits à côté. Ne le supprimez pas.

## Credits

Author: vyrriox

Bleeter, Snapmatic et Hush sont des marques de Grand Theft Auto V.
