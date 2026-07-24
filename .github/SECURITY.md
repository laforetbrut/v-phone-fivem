# Security Policy

## Supported versions

Only the latest release receives fixes. Update before reporting.

| Version | Supported |
| ------- | --------- |
| 1.1.x   | ✅        |
| 1.0.x   | ❌        |

## Reporting a vulnerability

**Do not open a public issue for a security problem.** A phone resource sits on top of a server's
database, its players' private messages and, when media hosting is on, an API key. A public report is
an exploit handed to every server running it.

Use GitHub's private reporting instead:
**[Report a vulnerability](https://github.com/laforetbrut/v-phone-fivem/security/advisories/new)**

Please include the version, the framework, what an attacker can do, and the steps. A proof of concept
against your own test server is welcome; do not test against a server you do not own.

You will get a first answer within a few days. A fix ships in the next release, and the advisory is
published once servers have had time to update.

### What counts

- A client event that writes to the database without a server-side check.
- Reading another player's messages, contacts, calls or Cipher conversations without the police terminal's two gates.
- Escalating to a staff action without the admin permission.
- Leaking `phone_media_key`, the database credentials or another player's identifiers to a client.
- Any way to make the server run arbitrary SQL.

### What does not

- The police forensics terminal reading a player's data. That is the feature — it is gated behind the
  police job *and* a session started at a configured terminal, both re-checked server-side, and it is
  documented.
- A server that gave a player the admin permission or the police job on purpose.
- Cipher being readable by nobody, including the server. That is also the feature.
- The FaceTime live picture costing bandwidth. It is opt-in, capped and documented.

---

# Politique de sécurité

## Versions prises en charge

Seule la dernière version reçoit des correctifs. Mettez à jour avant de signaler.

| Version | Prise en charge |
| ------- | --------------- |
| 1.1.x   | ✅              |
| 1.0.x   | ❌              |

## Signaler une vulnérabilité

**N'ouvrez pas d'issue publique pour un problème de sécurité.** Une ressource téléphone est posée sur
la base de données d'un serveur, sur les messages privés de ses joueurs et, avec l'hébergement média
activé, sur une clé d'API. Un rapport public, c'est un exploit offert à tous les serveurs concernés.

Utilisez le signalement privé de GitHub :
**[Signaler une vulnérabilité](https://github.com/laforetbrut/v-phone-fivem/security/advisories/new)**

Indiquez la version, le framework, ce qu'un attaquant peut faire, et les étapes. Une preuve de concept
sur votre propre serveur de test est bienvenue ; ne testez pas sur un serveur qui ne vous appartient pas.

Vous aurez une première réponse sous quelques jours. Le correctif part dans la version suivante, et
l'avis est publié une fois que les serveurs ont eu le temps de mettre à jour.

### Ce qui compte

- Un event client qui écrit en base sans contrôle côté serveur.
- Lire les messages, contacts, appels ou conversations Cipher d'un autre joueur sans les deux verrous du terminal police.
- Obtenir une action de staff sans la permission admin.
- Fuiter `phone_media_key`, les identifiants de la base ou les identifiants d'un autre joueur vers un client.
- Tout moyen de faire exécuter du SQL arbitraire au serveur.

### Ce qui ne compte pas

- Le terminal d'enquête police lisant les données d'un joueur. C'est la fonctionnalité : elle est
  verrouillée derrière le métier police *et* une session ouverte à un terminal configuré, les deux
  revérifiés côté serveur, et c'est documenté.
- Un serveur qui a donné volontairement la permission admin ou le métier police à un joueur.
- Cipher illisible par tout le monde, serveur compris. C'est aussi la fonctionnalité.
- L'image FaceTime en direct qui coûte de la bande passante. Elle est optionnelle, plafonnée et documentée.
