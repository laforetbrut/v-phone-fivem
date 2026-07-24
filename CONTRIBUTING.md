# Contributing to v-phone

Thanks for taking the time. This page is short on purpose — read it once and you know how the project works.

## Where to go

| You want to... | Go to |
| --- | --- |
| Report something broken | [Bug report](https://github.com/laforetbrut/v-phone-fivem/issues/new?template=01-bug.yml) |
| An app doesn't read your inventory / banking / housing script | [Compatibility report](https://github.com/laforetbrut/v-phone-fivem/issues/new?template=02-compatibility.yml) |
| Suggest a feature | [Feature request](https://github.com/laforetbrut/v-phone-fivem/issues/new?template=03-feature.yml) |
| Fix the docs | [Documentation](https://github.com/laforetbrut/v-phone-fivem/issues/new?template=04-docs.yml) |
| Ask a question, get setup help | [Discussions](https://github.com/laforetbrut/v-phone-fivem/discussions) |
| Report a vulnerability | [Privately](https://github.com/laforetbrut/v-phone-fivem/security/advisories/new) — never a public issue |

## Before you build your own thing

A lot of what people request is already possible without touching this repository:

- **Apps are drop-in folders.** `apps/<name>/app.lua` plus optional `client.lua`, `server.lua` and a page.
  The manifest globs them, so adding an app is adding a folder. See [DEVELOPERS.md](DEVELOPERS.md).
- **Other resources can drive the phone.** 32 exports, plus events and callbacks. See [API.md](API.md).
- **An unsupported script can be wired in from your own config** with `Config.Compat.hooks`, without a
  code change here. See [COMPATIBILITY.md](COMPATIBILITY.md).

If you build one of those and it would help everybody, a pull request is very welcome.

## Filing a good bug

The two things that decide whether a bug gets fixed:

1. **Both consoles.** The server console *and* the client F8 console. Lua errors and NUI errors live in
   different places, and a screenshot of the phone shows neither.
2. **Steps from a fresh connection.** "It breaks sometimes" cannot be reproduced; a numbered list can.

Never paste your `phone_media_key`, your database connection string or your license key.

## Pull requests

Branch off `main`, one topic per pull request.

**Conventions this project holds to:**

- **Code, comments, variable names and logs are English.** The documentation is bilingual EN/FR; the code is not.
- **User-facing text goes in both locales.** A string added to `locales/en.lua` and missing from
  `locales/fr.lua` is a bug.
- **Database tables are prefixed `vphone_`.** No exception — the prefix is what keeps this resource from
  colliding with the rest of a server.
- **Framework-agnostic or it doesn't merge.** Anything that reads a framework goes through `bridge/`, and
  degrades cleanly when the dependency is absent rather than erroring.
- **Configurable over hardcoded.** If a server owner might reasonably want it different, it belongs in `config.lua`.
- **GTA V lore.** Real in-game brands. Do not invent companies.
- **Don't bump the version.** Releases are cut by the maintainer; a version bump in a pull request just
  creates a conflict.
- **`CHANGELOG.md` gets an entry**, English first, French mirror below.
- **Keep the attribution.** The [LICENSE](LICENSE) is MIT with one condition: the author credit stays visible
  in Settings > About. Removing it is the one change that will never be merged.

Test before you open it: boot a server, watch both consoles, and play the path you changed. Say what you
ran in the pull request. "It should work" is not a test.

---

# Contribuer à v-phone

Merci d'y consacrer du temps. Cette page est volontairement courte : lisez-la une fois et vous savez comment
le projet fonctionne.

## Où aller

| Vous voulez... | Allez à |
| --- | --- |
| Signaler un dysfonctionnement | [Rapport de bug](https://github.com/laforetbrut/v-phone-fivem/issues/new?template=01-bug.yml) |
| Une app ne lit pas votre inventaire / banque / logement | [Rapport de compatibilité](https://github.com/laforetbrut/v-phone-fivem/issues/new?template=02-compatibility.yml) |
| Proposer une fonctionnalité | [Demande de fonctionnalité](https://github.com/laforetbrut/v-phone-fivem/issues/new?template=03-feature.yml) |
| Corriger la documentation | [Documentation](https://github.com/laforetbrut/v-phone-fivem/issues/new?template=04-docs.yml) |
| Poser une question, être aidé à l'installation | [Discussions](https://github.com/laforetbrut/v-phone-fivem/discussions) |
| Signaler une vulnérabilité | [En privé](https://github.com/laforetbrut/v-phone-fivem/security/advisories/new) — jamais une issue publique |

## Avant de construire votre propre chose

Beaucoup de demandes sont déjà réalisables sans toucher à ce dépôt :

- **Les apps sont des dossiers autonomes.** `apps/<nom>/app.lua` plus, en option, `client.lua`, `server.lua`
  et une page. Le manifest les récupère par glob : ajouter une app, c'est ajouter un dossier.
  Voir [DEVELOPERS.md](DEVELOPERS.md).
- **D'autres ressources peuvent piloter le téléphone.** 32 exports, plus des events et des callbacks.
  Voir [API.md](API.md).
- **Un script non pris en charge se branche depuis votre propre config** avec `Config.Compat.hooks`, sans
  modification de code ici. Voir [COMPATIBILITY.md](COMPATIBILITY.md).

Si vous construisez l'un de ces éléments et qu'il peut servir à tous, une pull request est la bienvenue.

## Faire un bon rapport de bug

Les deux éléments qui décident si un bug sera corrigé :

1. **Les deux consoles.** La console serveur *et* la console client F8. Les erreurs Lua et les erreurs NUI
   vivent à des endroits différents, et une capture du téléphone ne montre ni l'une ni l'autre.
2. **Des étapes depuis une connexion propre.** « Ça casse parfois » n'est pas reproductible ; une liste
   numérotée l'est.

Ne collez jamais votre `phone_media_key`, votre chaîne de connexion à la base ni votre clé de licence.

## Pull requests

Partez de `main`, un sujet par pull request.

**Les conventions du projet :**

- **Code, commentaires, noms de variables et logs en anglais.** La documentation est bilingue EN/FR ; le code non.
- **Le texte visible par le joueur va dans les deux locales.** Une chaîne ajoutée à `locales/en.lua` et
  absente de `locales/fr.lua` est un bug.
- **Les tables de base sont préfixées `vphone_`.** Sans exception — ce préfixe est ce qui empêche la
  ressource d'entrer en collision avec le reste d'un serveur.
- **Agnostique du framework, sinon ça ne fusionne pas.** Tout ce qui lit un framework passe par `bridge/`,
  et se dégrade proprement en l'absence de la dépendance plutôt que de lever une erreur.
- **Configurable plutôt qu'en dur.** Si un propriétaire de serveur peut raisonnablement le vouloir autrement,
  cela appartient à `config.lua`.
- **Lore GTA V.** De vraies marques du jeu. N'inventez pas d'entreprises.
- **Ne changez pas la version.** Les releases sont faites par le mainteneur ; un bump dans une pull request
  ne crée qu'un conflit.
- **`CHANGELOG.md` reçoit une entrée**, anglais d'abord, miroir français en dessous.
- **Conservez l'attribution.** La [LICENCE](LICENSE) est MIT avec une condition : le crédit auteur reste
  visible dans Réglages > À propos. Le retirer est le seul changement qui ne sera jamais fusionné.

Testez avant d'ouvrir : démarrez un serveur, surveillez les deux consoles, et jouez le parcours modifié.
Dites ce que vous avez lancé dans la pull request. « Ça devrait marcher » n'est pas un test.
