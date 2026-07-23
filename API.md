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

## Client exports

```lua
local phone = exports['v-phone']

phone:IsOpen()          --> boolean
phone:Open()
phone:Close()
phone:GetNumber()       --> the local player's number
phone:OnCall()          --> boolean
```

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
