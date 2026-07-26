# Changelog

All notable changes to v-phone are documented here.

---

## [1.2.0] - 2026-07-25

### Added (English first)

- **The phone tells you when money arrives.** A salary, a society payout, a shop refund or a transfer raises a notification with the bank's icon on it. It listens to the framework's own money events rather than polling, so it is instant and it knows the REASON - which is how a paycheck is labelled as a salary rather than as a bare deposit. Wired for qb-core and qbx_core (`QBCore:Server:OnMoneyChange`, plus qbx's own `onPaycheck`) and ESX (`esx:addAccountMoney` / `esx:removeAccountMoney`); ox_core has no equivalent event, so `Config.Bank.notify.pollSeconds` samples the balance instead when you turn it on. `Config.Bank.notify` also sets a minimum amount so a one dollar tip is not an alert, and whether money LEAVING is announced too - off by default, because a phone that buzzes at every purchase gets muted. `exports['v-phone']:NotifyMoney(src, amount, label)` lets any resource raise one.
- **One notification per payment.** A received transfer used to raise a framework toast and send a text as well: two alerts for one payment. It is now a single notification on the bank when the recipient is connected, and a text - which persists - only when they are not, since a banner would be long gone before they logged in.
- **A statement, transfers and saved beneficiaries in the Bank app.** The balance is still the framework's - the number on the phone is the number at the ATM - but the phone now keeps what no framework has: its own statement lines merged with your banking script's, transfers to another character by phone number, and a beneficiary list. `Config.Bank` sets the per-transfer bounds, an optional percentage fee shown live as the amount is typed, a daily ceiling counted from the ledger so a restart does not reset it, and whether paying somebody offline is allowed.
- **Money that cannot go missing.** A transfer debits through `Bridge.RemoveMoney`, which fails closed, and credits through the new `Bridge.AddMoney` (qb-core, qbx, ESX, ox, plus a `Config.Compat.hooks.addMoney` escape hatch). A credit that fails is refunded; a refund that also fails is escrowed back to the sender. Paying an offline character holds the money in its own table and pays it out **exactly once** on their next read - claimed by deleting the row and only then credited, so a retry cannot pay twice. The recipient is resolved from a phone number to a citizen id on the server: the client never names an account. Fifty-one assertions run the real module under a real Lua, including that the statement lines sum to the movement on both sides.
- **Reshape a photograph to portrait.** The Gallery can now recrop a photo: **Portrait**, **Square** or **Tall** — the last one being the shape of the phone screen, so a photograph makes a wallpaper. A screenshot is the game window, so every photograph arrives 16:9 however it was framed; a slider says which band of it survives the crop, because a wide shot squeezed into portrait and centred usually loses the head with the sides. Like the filters, this stores a shape rather than re-encoding an image: the file is untouched, nothing is re-uploaded, and the choice follows the photo into the grid.
- **Your own apps in FruitStore, free or paid.** `Config.StoreApps` lists an app and it appears in the store beside the built-in ones — no resource to write. Give it a `page` and the phone frames that URL as the app; give it a `price` and it is charged for once. **What a character buys is remembered**, so removing a paid app and installing it again later is free: you pay for the app, not for the download. A `job` gate restricts it to one job or a list of them.
- **`Bridge.RemoveMoney`.** New, because charging for something needs it: qb-core and qbx through `Player.Functions.RemoveMoney`, ESX through `removeAccountMoney` / `removeMoney`, ox through its money item, and `Config.Compat.hooks.removeMoney` for anything else. Like `Bridge.RemoveItem` it **fails closed** — a debit that cannot be confirmed grants nothing, so a paid app is never handed out for free.
- **Default playlists with real links.** Two royalty-free lists built on [NoCopyrightSounds](https://ncs.io), which is free to stream as long as the artist, track and NCS are credited, and one of the in-game stations. All five URLs were checked and resolve. The licence-free ones are first on purpose: a rip of a commercial station is taken down sooner or later and the entry quietly stops working.
- **A qb-phone drop-in, so v-phone is ready to use on a stock qb-core server.** A stock qb-core install has eighteen resources that talk to `qb-phone` — job mail, police dispatch, invoices, race results. Removing the stock phone left every one of them talking to nobody. v-phone now answers them itself, and `compat/qb-phone` carries the one call that cannot be answered from inside v-phone: `exports['qb-phone']:sendNewMailToOffline`, a hard call in qb-cityhall, qb-vehiclesales and qb-weapons that raises rather than passing quietly. An export belongs to a resource **name**, which is the whole reason that file exists. `Config.Compat.qbPhone` stands down automatically when the real qb-phone is running, so the two never double up. See COMPATIBILITY.md.
- **Verification codes copy in one tap, and fill in one more.** A code arrives to be typed somewhere else, which is the small daily annoyance iOS solved years ago. A message carrying one now shows a **Copy code** button under the bubble, and the code fields in sign-up and password reset offer the newest code the phone has been sent, ready to drop in. The detector wants 4–8 digits *and* a word saying what they are, so a house number or a price never sprouts a button — checked against both, and against both shipped languages.
- **The Camera is a viewfinder now.** Opening it puts the player in first person and holds them there, hides the HUD and the minimap every frame, and makes the phone's screen see-through so the game is visible *through* the handset — which is the preview of the shot, produced with no capture loop at all. The corner marks and grid that were already drawn now frame something. The view mode is remembered per surface, on foot and in a vehicle, and restored on the way out — including if the phone is simply closed mid-shot.
- **Photos zoom.** The wheel zooms about the cursor, so the detail under the pointer stays under it; a drag pans once there is anything to pan to, and a double-click resets. The maths is checked rather than eyeballed: the anchored point holds to within a pixel and a half over six steps, no gap can open at any zoom, and panning clamps to the picture's edge.

### Fixed

- **The apps stopped guessing which backend exists.** Each app decided whether to ask a companion resource or the bridge by checking `GetResourceState`, which is a PREDICTION - and a wrong one produced an app reporting that nothing was loaded while the callback it needed was registered and answering. The phone now uses whichever backend actually replies: the companion resource is still asked first and still wins when it is really there, but an answer of 'nobody is listening' falls through to the bridge instead of becoming an error on screen. A genuine error from a backend is shown as itself and never retried.
- **`/phonediag` is now staff-only, and only with debug on.** It names the framework, the loaded server files and what each provider returns, which is operator information rather than a player feature: it needs `set phone_debug true` and the `vphone.admin` ace (or qb-core staff), and says which of the two is missing when refused. Its balance probe also stopped reporting a perfectly good answer as '0 rows' - counting an array's length on a map gives zero.
- **"Something went wrong" now says what went wrong.** A request that failed answered `nil`, and every app turned that into the same four words - for a callback that was never registered, a query that threw, and a server that never replied. Three different problems, one useless message, and the real reason printed only on the server console while the console anybody pastes is F8. Each of the three now names itself, travels back to the phone, and is logged client-side with its Lua error attached. **`/phonediag`** prints the two facts that decide it: whether each server file loaded and registered its callback, and whether the bridge provider behind it returns anything on this server.
- **Garage, Property, Wallet and Jobs did not work on any server either.** The same fault as the Bank app, three more times: each was a view over a companion resource (`v-vehicles`, `v-housing`, `v-licenses`, `v-cityhall`) that exists only in the author's own suite, while the providers they needed sat finished in the bridge, covering qb-core, qbx, ESX, ox, Quasar's garage and housing, and the rest - called by nothing. All four now read the bridge. **Garage** normalises the four different meanings of "stored": qb's `state` (0 out, 1 garaged, 2 impounded), ox's `stored` garage name, ESX's boolean, and Quasar's own export keys, which are read defensively rather than assumed. A car the phone cannot place is shown as parked, because claiming it is out sends a player looking for it. **Jobs** builds the employment card from the framework and takes the pay from the grade actually held rather than from the first rung, with the ladder sorted and openings advertised at their entry wage. **Wallet** and **Property** accept the several spellings the scripts use for the same field.
- **These apps now say what is actually wrong.** "No garage script here the phone can read" and "you own no cars" are different sentences and used to be the same one. An empty list is a success, an unreadable provider is its own message, a character the framework has not loaded yet is another, and any provider that throws names its reason on the server console instead of leaving four words on the phone.
- **The Bank app said 'something went wrong' on a server that had already run it once.** `CREATE TABLE IF NOT EXISTS` does nothing to a table that already exists, so the `counterparty` column added to the escrow table one commit after the table itself never appeared - and every read of it failed with 'Unknown column', which took the whole app down. The column is now added idempotently at boot, the same way the messages table has always done it. Beyond the fix, the app no longer fails as one piece: the escrow settlement, the statement, the daily total and the beneficiary list each survive their own failure and leave a usable screen, and each names its reason in the server console instead of leaving four words on the phone. A framework that cannot say who you are has its own message too, rather than sharing the catch-all.
- **The Bank app worked on no server at all.** It required a companion `v-banking` resource that exists only in the author's own suite, so on qb-core, qbx, ESX and ox alike it answered "not available on this server" - while the bridge underneath already had `Bridge.Banking.Balances` and `.Transactions` written, tested and called by nothing. The app now reads the bridge, and `v-banking` is preferred only when it is genuinely running. Any app can now name a bridge fallback the same way, which is what shipping a bridge was for.
- **The key hints are no longer in the photograph.** The viewfinder draws its instructions every frame, and a capture lands several frames after the shutter — so clearing the help box on the shutter frame alone did nothing: the loop had already drawn it again by the time the frame was grabbed. The hints are now suppressed for the whole capture and restored when the photograph is actually finished, which is a signal the page already sent.
- **The key hints no longer stay on screen after the photograph.** They were drawn with the game's `loop` flag set, which keeps a help box up on its own after whatever drew it has stopped. Drawn every frame anyway, so letting each one expire costs nothing and the box cannot outlive the camera.
- **A photograph can no longer kill camera mode while it is being taken.** The shutter waited a fixed 1200ms; the watchdog that rescues a stuck camera fires after 1500ms without a tick. Two hundred milliseconds of margin was enough for a slow capture to be mistaken for a hang. The shutter now waits for the capture itself, feeding the watchdog while it does, and gives up after fifteen seconds rather than stranding the player in the viewfinder.
- **The black band under a previewed photograph.** The 12px gap below the picture was the image's own margin, so it sat inside the frame's black background instead of below it. It belongs to the frame.
- **The vehicle remote's ownership check, confirmed end to end.** `requireOwnership` is on by default and enforced on the server, and `Bridge.Vehicles.Owned` covers every supported stack: the operator's own hook, Quasar's `GetPlayerVehicles`, ox's `vehicles` table, ESX's `owned_vehicles` and qb's `player_vehicles`. The plate is read from the **entity that is actually there** rather than from the client's message, and the check **fails closed** — if the vehicle list cannot be read, every command is refused rather than allowed.
- **Your car, from your pocket.** A remote in the Garage app: lock and unlock, flash the lights, change the underglow, pop a door, sound the horn, start the engine. **It needs no dependency at all** — neons, lights, doors and locks are engine natives, so it behaves identically on qb-core, qbx_core, ox_core, ESX and standalone, with any garage or inventory script. The framework only decides which vehicles are yours, read through the same bridge the Garage app already uses.
- **Every command is decided on the server.** The distance is measured from the vehicle entity's own coordinates to the player's ped, so a modified client cannot open its car from across the city; the plate is read from the **entity that is actually there**, not from the message, so ownership is checked against the real car; a control an operator disabled is refused as well as hidden, because hiding a button is not a permission check; and the command is applied through the vehicle's state bag, so every player nearby sees the same lights rather than only the one who pressed.
- **`Config.VehicleRemote`.** `distance` (the reach, in metres — the whole point), `requireOwnership`, `refuseWhileDriven`, `cooldownSeconds`, a per-control `controls` table, a `neonColours` palette, and `persist`. Engine start and the alarm are **off by default**: they are the two strongest of these. Plus a `VehicleRemote` export so a key-fob item or an admin tool can drive the same thing.
- **jim-mechanic.** It publishes no exports — its Neon Controller is an inventory item, not an API — so there is nothing to call into, and nothing to fight over either: both write the same engine state and the last write wins, exactly as it would if two players used the item. Leave `persist` off and the phone stays a remote while jim-mechanic remains the thing that saves a build.
- **The Music app works.** It was hidden on every server: `stubIsLive('v-music')` returned a hardcoded `false`, and the two NUI relays behind it asked for `v-music:play` and `v-music:list` — server callbacks that do not exist in this resource. A complete app, a library, a player, a queue and a search, all unreachable. It is now wired to real music resources and appears whenever there is one to talk to.
- **rcore integration.** [rcore_radiocar](https://store.rcore.cz/package/4342933) in a vehicle and [xDiskJockey](https://store.rcore.cz/package/4357520) on foot, chosen automatically by where the player is standing, or forced with `Config.Music.provider`. **Be clear about what this can do:** both scripts publish UI-only APIs — `OpenPlayerUI` for the car radio, `OpenDiskjockeyUI` / `HideDiskjockeyUI` for the deck — and neither documents an export that takes a URL and plays it. So the phone opens the right deck and puts the track's link on the clipboard, ready to paste. That is the whole of what those scripts expose, and inventing an export they do not have would only fail at runtime.
- **`Config.Music.hooks` for a script that CAN be driven.** Fill `hooks.play` and the phone drives your music resource directly — no deck, no paste, the track just plays. The hook wins over any deck, and its presence alone is enough to make the app appear.
- **Playlists.** A new tab in the app. A player builds their own from their library; they live in the same per-character phone storage as the library, so there is no new table and nothing to migrate. `Config.Music.maxPlaylists` and `maxTracksPerPlaylist` bound them.
- **Playlists shipped by the server.** `Config.Music.defaultPlaylists` gives every character a set of station playlists — three empty ones to fill are included as a starting point. They are **read-only**: a player can play them and copy a track out, but not edit or delete them, so a server's own selections survive contact with its players.
- **New music configuration.** `provider`, `copyUrl`, `hooks`, `maxLibrary`, `maxPlaylists`, `maxTracksPerPlaylist`, `allowCustomUrl` and a `hosts` allowlist for track URLs — the same idea as the wallpaper hosts, an operator decision rather than a player one.
- **`requireItem` was a landmine, not a setting.** Turning it on called `inv.GetItemCount`, a key no inventory provider registers — neither `bridge/server/integrations.lua` nor the compat stub has it. Every check raised instead of answering, the open callback never resolved, and the phone died silently until the client's ten-second guard gave up. It now uses `HasItem`, which both providers register and which fails open on a server with no inventory v-phone recognises.
- **`Config.PhoneItem` was dead code.** The item check hardcoded `phone` and `iphone` and never read the setting, so a server that renamed the handset was silently ignored.
- **Escape opened the GTA menu with the phone in your hand.** The page already treated Escape as “go back” — close a sheet, then the app, then the phone — but the game acted on the same keypress, so one press did both. Controls 199 and 200 are blocked while the phone is out and restored the moment it goes away.
- **The phone went blurry at any size but 100%.** The size setting scales the handset with a transform, and `.device` also carried a `drop-shadow` filter. A filter gives an element its own render surface, rasterised **before** the transform — so the phone was drawn at 372px and then stretched, and every glyph softened. The filter is gone; `.bezel`’s existing box-shadow is the same silhouette and rasterises at the final scale, so it stays sharp.
- **The camera refused on a server that had it switched on.** `set phone_media true` is resolved by the server, but the CLIENT decided whether to use server-side capture by reading `Config.Media.enabled` out of the file itself — so the operator's switch applied to the server and not to the phone taking the photograph. It fell through to screenshot-basic, found no upload target, and refused. The server reports the state with the open payload now, because it is the only side that knows it.
- **The Camera app has never opened for anybody.** The page decides from `state.camera`, and the server never put `camera` in the open payload at all — so it read undefined, and reported “the camera is disabled on this server” however the operator had configured it. Sent now. The same table also carried `media` twice, one of them redundant.
- **The app switcher can be scrolled.** `overflow-x: auto` is enough on a touchscreen and useless with a mouse — no horizontal wheel, no drag — so every card past the second one was unreachable. A vertical wheel now pans sideways and the strip can be dragged, with a moved strip no longer counting as a tap on the card the drag started from. Checked both ways in a browser: eight cards across 1618px in a 300px window, wheel and drag both move it, a drag leaves the switcher up and a clean tap still opens the app.
- **Photographs never reached the gallery.** A shot taken through media hosting was added by sending its URL back through the same path a player's pasted link takes — which runs it past the WALLPAPER host allowlist. That list exists to stop somebody pasting an arbitrary link and naturally does not name whichever CDN the operator uploads to, so every photo the phone took was refused as `badhost` and the gallery stayed empty. The server stores it directly now: it made the URL, from this player's own capture, seconds earlier. Nothing is taken on trust. A file the phone uploaded is also accepted as a wallpaper for the same reason.

### Changed

- **The phone item is now required by default, and there is no key.** `Config.Settings.requireItem` is on and `Config.Key` is `false`: the phone opens by using the item, the way any other object does. A phone every character owns for free is not an item, it is a menu. Put a key name back in `Config.Key` to also offer a binding, or `set phone_requireItem false` to give everybody one again. Mark the item `useable` in your framework's own catalogue — on qb-core that is `qb-core/shared/items.lua`. It cuts both ways: a character with no handset cannot be called either, and messages sent to them wait until they hold one.
- **A phone lasts a real day now.** The battery emptied in eight hours idle and under three with the screen on, which reads as a broken phone rather than as a mechanic. It is 48 hours in a pocket and 24 with the screen on — a long session ends with charge left, and somebody who never puts it away still has to find a charger.
- **The phone is locked at 100% and the size slider is gone.** It was the honest fix rather than the clever one: the handset is laid out in pixels at 372x784, so every size but 100% was a `transform: scale()` over an already-drawn image and each glyph went soft. A stored 80% is ignored rather than clamped, so nobody is left with a permanently fuzzy phone and no control to fix it. `Config.DeviceSize` remains for an operator who wants a different fixed size and accepts the softness.
- **The battery lasts about two days of use.** 48 hours idle at 2x for the screen worked out to exactly 24 hours of use, which is the number to clear rather than land on. It is 72 hours idle at 1.5x — 1.39% an hour closed, 2.08% with the screen on, so 72 and 48 hours to empty. The arithmetic is written next to the setting so it can be checked instead of trusted.
- **F2 opens the phone, and every player can change that.** The keybind is registered with `RegisterKeyMapping`, so it appears in the game's own Settings → Key Bindings → FiveM list as “iFruit” and whatever a player binds there wins over the config and survives a restart — there is nothing for the phone to store or sync. F2 rather than F1, which more resources claim than any other key. Holding the item is still required, so the key opens a phone you own and says so plainly when you do not; `Config.Key = false` removes the binding entirely and leaves only the item.


---

## [1.2.0] - 2026-07-25

### Ajouts (miroir français)

- **Le téléphone prévient quand de l'argent arrive.** Un salaire, un versement de société, un remboursement de boutique ou un virement déclenche une notification portant l'icône de la banque. Elle écoute les événements monétaires du framework plutôt que de sonder : c'est immédiat et elle connaît le MOTIF — c'est ainsi qu'une paie est étiquetée comme salaire et non comme un simple dépôt. Câblée pour qb-core et qbx_core (`QBCore:Server:OnMoneyChange`, plus le `onPaycheck` propre à qbx) et ESX (`esx:addAccountMoney` / `esx:removeAccountMoney`) ; ox_core n'a pas d'événement équivalent, donc `Config.Bank.notify.pollSeconds` échantillonne le solde à la place si vous l'activez. `Config.Bank.notify` règle aussi un montant plancher pour qu'un pourboire d'un dollar ne soit pas une alerte, et l'annonce de l'argent qui SORT — désactivée par défaut, car un téléphone qui vibre à chaque achat finit en silencieux. `exports['v-phone']:NotifyMoney(src, amount, label)` permet à n'importe quelle ressource d'en déclencher une.
- **Une seule notification par paiement.** Un virement reçu déclenchait un toast du framework *et* un SMS : deux alertes pour un paiement. C'est désormais une notification unique sur la banque quand le destinataire est connecté, et un SMS — qui persiste — seulement quand il ne l'est pas, un bandeau ayant disparu bien avant sa connexion.
- **Un relevé, des virements et des bénéficiaires enregistrés dans la Banque.** Le solde reste celui du framework — le montant sur le téléphone est celui au distributeur — mais le téléphone tient maintenant ce qu'aucun framework n'a : ses propres lignes de relevé fusionnées avec celles de votre script bancaire, des virements vers un autre personnage par numéro de téléphone, et une liste de bénéficiaires. `Config.Bank` règle les bornes par virement, des frais en pourcentage optionnels affichés en direct pendant la saisie, un plafond quotidien compté sur le registre pour qu'un redémarrage ne le remette pas à zéro, et l'autorisation de payer quelqu'un hors ligne.
- **De l'argent qui ne peut pas disparaître.** Un virement débite via `Bridge.RemoveMoney`, qui échoue en refusant, et crédite via le nouveau `Bridge.AddMoney` (qb-core, qbx, ESX, ox, plus une échappatoire `Config.Compat.hooks.addMoney`). Un crédit qui échoue est remboursé ; un remboursement qui échoue aussi est mis en séquestre au profit de l'expéditeur. Payer un personnage hors ligne conserve la somme dans sa propre table et la verse **exactement une fois** à sa prochaine consultation — la ligne est réclamée par sa suppression avant tout crédit, donc une reprise ne peut pas payer deux fois. Le destinataire est résolu d'un numéro vers un citizen id sur le serveur : le client ne nomme jamais un compte. Cinquante et une assertions exécutent le vrai module sous un vrai Lua, dont le fait que les lignes du relevé somment au mouvement des deux côtés.
- **Redimensionner une photo en portrait.** La Galerie peut désormais recadrer une photo : **Portrait**, **Carré** ou **Plein écran** — ce dernier étant le format de l'écran du téléphone, de quoi faire un fond d'écran d'une photo. Une capture est la fenêtre du jeu : toute photo arrive donc en 16:9 quel que fût le cadrage souhaité ; un curseur indique quelle bande survit au recadrage, car une photo large comprimée en portrait et centrée y laisse généralement la tête en même temps que les côtés. Comme les filtres, cela mémorise un format sans réencoder l'image : le fichier est intact, rien n'est réenvoyé, et le choix suit la photo jusque dans la grille.
- **Vos propres applications dans le FruitStore, gratuites ou payantes.** `Config.StoreApps` déclare une application et elle apparaît dans le store à côté des intégrées — aucune ressource à écrire. Donnez-lui une `page` et le téléphone affiche cette URL comme l'application ; donnez-lui un `price` et elle est facturée une fois. **Ce qu'un personnage achète est mémorisé** : retirer une application payante puis la réinstaller plus tard est gratuit — on paie l'application, pas le téléchargement. Un filtre `job` la réserve à un métier ou à une liste.
- **`Bridge.RemoveMoney`.** Nouveau, car facturer l'exige : qb-core et qbx via `Player.Functions.RemoveMoney`, ESX via `removeAccountMoney` / `removeMoney`, ox via son item monnaie, et `Config.Compat.hooks.removeMoney` pour tout le reste. Comme `Bridge.RemoveItem`, il **échoue en refusant** — un débit non confirmé n'accorde rien, donc une application payante n'est jamais offerte.
- **Playlists par défaut avec de vrais liens.** Deux listes libres de droits basées sur [NoCopyrightSounds](https://ncs.io), libre en streaming à condition de créditer l'artiste, le titre et NCS, et une des stations du jeu. Les cinq URL ont été vérifiées et répondent. Les libres de droits sont en premier volontairement : un rip de station commerciale finit toujours par être retiré et l'entrée cesse silencieusement de fonctionner.
- **Un remplacement de qb-phone, pour que v-phone soit prêt à l'emploi sur un serveur qb-core standard.** Une installation qb-core standard compte dix-huit ressources qui parlent à `qb-phone` — courriers de métier, alertes police, factures, résultats de course. Retirer le téléphone d'origine les laissait toutes parler dans le vide. v-phone y répond désormais lui-même, et `compat/qb-phone` porte le seul appel impossible à traiter depuis v-phone : `exports['qb-phone']:sendNewMailToOffline`, appel dur dans qb-cityhall, qb-vehiclesales et qb-weapons, qui lève une erreur au lieu de passer en silence. Un export appartient à un **nom** de ressource, et c'est toute la raison d'être de ce fichier. `Config.Compat.qbPhone` se retire automatiquement si le vrai qb-phone tourne. Voir COMPATIBILITY.md.
- **Les codes de vérification se copient d'un geste, et se remplissent d'un autre.** Un code arrive pour être tapé ailleurs, c'est la petite corvée quotidienne que iOS a résolue depuis longtemps. Un message qui en porte un affiche désormais un bouton **Copier le code** sous la bulle, et les champs de code — inscription et réinitialisation — proposent le dernier code reçu, prêt à être posé. Le détecteur exige 4 à 8 chiffres *et* un mot qui dit ce qu'ils sont : un numéro de rue ou un prix ne déclenche jamais de bouton — vérifié sur les deux, et dans les deux langues livrées.
- **L'appareil photo est un viseur.** L'ouvrir passe le joueur en vue subjective et l'y maintient, masque l'ATH et la minicarte à chaque frame, et rend l'écran du téléphone transparent pour qu'on voie le jeu *à travers* le combiné — c'est là l'aperçu du cliché, obtenu sans aucune boucle de capture. Les repères d'angle et la grille déjà dessinés encadrent enfin quelque chose. Le mode de vue est mémorisé séparément à pied et en véhicule, et restauré en sortant — y compris si on ferme simplement le téléphone en pleine prise.
- **Les photos se zooment.** La molette zoome autour du curseur, donc le détail sous le pointeur y reste ; un glissement déplace dès qu'il y a de quoi, un double-clic remet à zéro. Les calculs sont vérifiés et pas estimés : le point ancré tient à un pixel et demi près sur six crans, aucun vide ne peut s'ouvrir, et le panoramique se borne au bord de l'image.

### Correctifs

- **Les applications ne devinent plus quel backend existe.** Chacune décidait d'interroger une ressource compagnon ou le bridge en consultant `GetResourceState`, qui est une PRÉDICTION — et une prédiction fausse produisait une application annonçant que rien n'était chargé alors que le callback nécessaire était enregistré et répondait. Le téléphone utilise désormais celui qui répond réellement : la ressource compagnon est toujours interrogée d'abord et gagne toujours quand elle est vraiment là, mais une réponse « personne n'écoute » se rabat sur le bridge au lieu de devenir une erreur à l'écran. Une vraie erreur d'un backend est affichée telle quelle et jamais réessayée.
- **`/phonediag` est désormais réservé au staff, et uniquement avec le debug actif.** Il nomme le framework, les fichiers serveur chargés et ce que renvoie chaque fournisseur : c'est une information d'opérateur, pas une fonctionnalité joueur. Il exige `set phone_debug true` et l'ace `vphone.admin` (ou le staff qb-core), et indique lequel des deux manque en cas de refus. Sa sonde de solde ne rapporte plus « 0 ligne » pour une réponse parfaitement valide — compter la longueur d'un tableau sur une table indexée par clés donne zéro.
- **« Quelque chose s est mal passé » dit maintenant ce qui s est mal passé.** Une requête en échec répondait `nil`, et chaque application en faisait les mêmes quatre mots — pour un callback jamais enregistré, une requête qui échoue, et un serveur qui ne répond jamais. Trois problèmes différents, un message inutile, et la vraie raison imprimée uniquement dans la console serveur alors que la console que tout le monde copie est F8. Chacun des trois se nomme désormais, remonte jusqu au téléphone, et est journalisé côté client avec son erreur Lua. **`/phonediag`** affiche les deux faits qui tranchent : si chaque fichier serveur a chargé et enregistré son callback, et si le fournisseur du bridge derrière lui renvoie quelque chose sur ce serveur.
- **Garage, Logement, Portefeuille et Emplois ne fonctionnaient sur aucun serveur non plus.** Le même défaut que la Banque, trois fois de plus : chacune était une vue sur une ressource compagnon (`v-vehicles`, `v-housing`, `v-licenses`, `v-cityhall`) qui n'existe que dans la suite de l'auteur, alors que les fournisseurs nécessaires attendaient, terminés, dans le bridge — couvrant qb-core, qbx, ESX, ox, le garage et le logement de Quasar, et le reste — appelés par personne. Les quatre lisent désormais le bridge. Le **Garage** normalise les quatre sens différents de « rangé » : le `state` de qb (0 dehors, 1 au garage, 2 en fourrière), le nom de garage dans `stored` d'ox, le booléen d'ESX, et les clés propres à l'export Quasar, lues avec prudence plutôt que supposées. Une voiture que le téléphone ne sait pas situer est affichée comme garée, car la déclarer dehors envoie le joueur la chercher. **Emplois** construit la fiche d'emploi depuis le framework et prend la paie du grade réellement détenu plutôt que du premier échelon, avec l'échelle triée et les postes annoncés à leur salaire d'entrée. **Portefeuille** et **Logement** acceptent les différentes orthographes que les scripts donnent au même champ.
- **Ces applications disent maintenant ce qui ne va pas.** « Aucun script de garage lisible sur ce serveur » et « vous ne possédez aucune voiture » sont deux phrases différentes et n'en faisaient qu'une. Une liste vide est un succès, un fournisseur illisible a son propre message, un personnage que le framework n'a pas encore chargé en a un autre, et tout fournisseur qui échoue nomme sa raison dans la console serveur au lieu de laisser quatre mots sur le téléphone.
- **L'application Banque affichait « quelque chose s'est mal passé » sur un serveur l'ayant déjà lancée une fois.** `CREATE TABLE IF NOT EXISTS` ne fait rien sur une table existante : la colonne `counterparty` ajoutée à la table de séquestre un commit après la table elle-même n'apparaissait donc jamais — et chaque lecture échouait sur « Unknown column », emportant toute l'application. La colonne est désormais ajoutée de façon idempotente au démarrage, comme la table des messages le fait depuis toujours. Au-delà du correctif, l'application ne tombe plus d'un bloc : le règlement du séquestre, le relevé, le total quotidien et la liste des bénéficiaires survivent chacun à sa propre panne en laissant un écran utilisable, et chacun nomme sa raison dans la console serveur au lieu de laisser quatre mots sur le téléphone. Un framework incapable de dire qui vous êtes a aussi son propre message, au lieu de partager le fourre-tout.
- **L'application Banque ne fonctionnait sur aucun serveur.** Elle exigeait une ressource compagnon `v-banking` qui n'existe que dans la suite de l'auteur : sur qb-core, qbx, ESX comme ox, elle répondait « indisponible sur ce serveur » — alors que le bridge en dessous contenait déjà `Bridge.Banking.Balances` et `.Transactions`, écrites, testées et appelées par personne. L'application lit maintenant le bridge, et `v-banking` n'est privilégié que s'il tourne réellement. N'importe quelle application peut désormais déclarer un repli sur le bridge de la même façon — c'est à cela que sert un bridge.
- **Les aides aux touches ne sont plus dans la photo.** Le viseur dessine ses instructions à chaque frame, et une capture arrive plusieurs frames après le déclencheur — effacer l'aide sur la seule frame du déclencheur ne servait donc à rien : la boucle l'avait déjà redessinée quand la frame était saisie. Les aides sont maintenant supprimées pendant toute la capture et rétablies quand la photo est réellement terminée, un signal que la page envoyait déjà.
- **Les aides aux touches ne restent plus affichées après la photo.** Elles étaient dessinées avec le drapeau `loop` du jeu, qui maintient une aide à l'écran de lui-même après que ce qui la dessinait s'est arrêté. Redessinée à chaque frame de toute façon : laisser chacune expirer ne coûte rien et la boîte ne peut plus survivre à la caméra.
- **Une photo ne peut plus tuer le mode caméra pendant sa prise.** Le déclencheur attendait 1200 ms fixes ; le watchdog qui rattrape une caméra bloquée se déclenche après 1500 ms sans signe de vie. Deux cents millisecondes de marge suffisaient pour qu'une capture lente passe pour un blocage. Le déclencheur attend désormais la capture elle-même en nourrissant le watchdog, et abandonne au bout de quinze secondes plutôt que de laisser le joueur coincé dans le viseur.
- **La bande noire sous une photo en aperçu.** Les 12 px d'écart sous l'image étaient la marge de l'image elle-même : ils tombaient donc dans le fond noir du cadre au lieu d'être dessous. Ils appartiennent au cadre.
- **La vérification de propriété de la télécommande, confirmée de bout en bout.** `requireOwnership` est actif par défaut et appliqué côté serveur, et `Bridge.Vehicles.Owned` couvre toutes les stacks supportées : le hook de l'opérateur, `GetPlayerVehicles` de Quasar, la table `vehicles` d'ox, `owned_vehicles` d'ESX et `player_vehicles` de qb. La plaque est lue sur **l'entité réellement présente** et non dans le message du client, et la vérification **échoue en refusant** — si la liste des véhicules ne peut être lue, toute commande est refusée plutôt qu'autorisée.
- **Votre voiture, depuis votre poche.** Une télécommande dans l'application Garage : verrouiller et déverrouiller, faire un appel de phares, changer les néons, ouvrir une porte, klaxonner, démarrer le moteur. **Aucune dépendance n'est nécessaire** — néons, feux, portes et verrous sont des natives du moteur : le comportement est donc identique sur qb-core, qbx_core, ox_core, ESX et standalone, avec n'importe quel script de garage ou d'inventaire. Le framework ne décide que de la liste de vos véhicules, lue via le même bridge que l'application Garage utilise déjà.
- **Chaque commande est décidée côté serveur.** La distance est mesurée depuis les coordonnées réelles du véhicule jusqu'au ped du joueur : un client modifié ne peut pas ouvrir sa voiture à l'autre bout de la ville. La plaque est lue sur **l'entité réellement présente**, pas dans le message, donc la propriété est vérifiée contre la vraie voiture. Une commande désactivée par l'opérateur est refusée en plus d'être masquée, car masquer un bouton n'est pas un contrôle d'accès. Et la commande est appliquée via le state bag du véhicule : tous les joueurs proches voient les mêmes feux, pas seulement celui qui a appuyé.
- **`Config.VehicleRemote`.** `distance` (la portée en mètres — l'essentiel), `requireOwnership`, `refuseWhileDriven`, `cooldownSeconds`, une table `controls` par commande, une palette `neonColours`, et `persist`. Le démarrage moteur et l'alarme sont **désactivés par défaut** : ce sont les deux plus puissantes. Plus un export `VehicleRemote` pour qu'un item porte-clés ou un outil admin pilote la même chose.
- **jim-mechanic.** Il ne publie aucun export — son Neon Controller est un item d'inventaire, pas une API — il n'y a donc rien à appeler, et rien à se disputer non plus : les deux écrivent le même état moteur et la dernière écriture gagne, exactement comme si deux joueurs utilisaient l'item. Laissez `persist` désactivé et le téléphone reste une télécommande, jim-mechanic restant ce qui sauvegarde une configuration.
- **L'application Musique fonctionne.** Elle était masquée sur tous les serveurs : `stubIsLive('v-music')` renvoyait `false` en dur, et les deux relais NUI derrière elle demandaient `v-music:play` et `v-music:list` — des callbacks serveur qui n'existent pas dans cette ressource. Une application complète, une bibliothèque, un lecteur, une file d'attente et une recherche, le tout injoignable. Elle est désormais câblée à de vraies ressources musicales et apparaît dès qu'il y en a une.
- **Intégration rcore.** [rcore_radiocar](https://store.rcore.cz/package/4342933) en véhicule et [xDiskJockey](https://store.rcore.cz/package/4357520) à pied, choisis automatiquement selon l'endroit où se trouve le joueur, ou forcés via `Config.Music.provider`. **Soyons clairs sur ce que cela permet :** les deux scripts ne publient qu'une API d'interface — `OpenPlayerUI` pour l'autoradio, `OpenDiskjockeyUI` / `HideDiskjockeyUI` pour le deck — et aucun ne documente d'export prenant une URL pour la jouer. Le téléphone ouvre donc le bon deck et place le lien du titre dans le presse-papier, prêt à coller. C'est tout ce que ces scripts exposent, et inventer un export qu'ils n'ont pas ne ferait qu'échouer à l'exécution.
- **`Config.Music.hooks` pour un script pilotable.** Remplissez `hooks.play` et le téléphone pilote directement votre ressource musicale — pas de deck, pas de collage, le titre se lance. Le hook prime sur tout deck, et sa seule présence suffit à faire apparaître l'application.
- **Playlists.** Un nouvel onglet dans l'application. Le joueur compose les siennes depuis sa bibliothèque ; elles vivent dans le même stockage par personnage que la bibliothèque, donc aucune nouvelle table ni migration. `Config.Music.maxPlaylists` et `maxTracksPerPlaylist` les bornent.
- **Playlists fournies par le serveur.** `Config.Music.defaultPlaylists` donne à chaque personnage un jeu de playlists de la station — trois vides à remplir sont incluses comme point de départ. Elles sont **en lecture seule** : un joueur peut les écouter et en copier un titre, mais ni les modifier ni les supprimer, afin que les sélections du serveur survivent au contact de ses joueurs.
- **Nouvelle configuration musique.** `provider`, `copyUrl`, `hooks`, `maxLibrary`, `maxPlaylists`, `maxTracksPerPlaylist`, `allowCustomUrl` et une liste blanche `hosts` pour les URL de titres — la même idée que les hôtes de fonds d'écran : une décision d'opérateur, pas de joueur.
- **`requireItem` était une mine, pas un réglage.** L'activer appelait `inv.GetItemCount`, une clé qu'aucun fournisseur d'inventaire n'enregistre — ni `bridge/server/integrations.lua`, ni le stub de compatibilité. Chaque vérification levait au lieu de répondre, le callback d'ouverture ne se résolvait jamais, et le téléphone mourait en silence jusqu'à ce que le garde de dix secondes du client abandonne. Il utilise maintenant `HasItem`, présent dans les deux fournisseurs, qui échoue en mode ouvert sur un serveur dont l'inventaire n'est pas reconnu.
- **`Config.PhoneItem` était du code mort.** La vérification codait en dur `phone` et `iphone` sans jamais lire le réglage : un serveur ayant renommé le combiné était ignoré en silence.
- **Échap ouvrait le menu GTA avec le téléphone en main.** La page traitait déjà Échap comme un retour — fermer une feuille, puis l’app, puis le téléphone — mais le jeu agissait sur la même touche, donc une pression faisait les deux. Les contrôles 199 et 200 sont bloqués tant que le téléphone est sorti, et rendus dès qu’il disparaît.
- **Le téléphone devenait flou à toute taille autre que 100 %.** Le réglage de taille met le combiné à l’échelle par un `transform`, et `.device` portait en plus un filtre `drop-shadow`. Un filtre donne à l’élément sa propre surface de rendu, rastérisée **avant** le transform : le téléphone était dessiné à 372px puis étiré, et chaque glyphe s’adoucissait. Le filtre est retiré ; le box-shadow déjà présent sur `.bezel` donne la même silhouette et se rastérise à l’échelle finale, donc il reste net.
- **L'appareil photo refusait sur un serveur où il était activé.** `set phone_media true` est résolu par le serveur, mais le CLIENT décidait d'utiliser la capture côté serveur en lisant `Config.Media.enabled` dans le fichier — donc l'interrupteur de l'opérateur s'appliquait au serveur et pas au téléphone qui prend la photo. Il retombait sur screenshot-basic, ne trouvait aucune destination d'envoi, et refusait. Le serveur transmet désormais l'état avec la charge d'ouverture, puisqu'il est le seul à le connaître.
- **L'application Appareil photo ne s'est jamais ouverte pour personne.** La page décide d'après `state.camera`, et le serveur ne mettait jamais `camera` dans la charge d'ouverture — elle lisait donc `undefined` et annonçait « l'appareil photo est désactivé sur ce serveur » quelle que soit la configuration. C'est envoyé. La même table portait aussi `media` en double, dont un redondant.
- **Le multitâche défile.** `overflow-x: auto` suffit sur un écran tactile et ne sert à rien à la souris — pas de molette horizontale, pas de glissement — donc toute carte au-delà de la deuxième était inaccessible. Une molette verticale déplace latéralement, la bande se glisse, et un glissement ne compte plus comme un tap sur la carte d'où il part. Vérifié dans un navigateur : huit cartes sur 1618px dans une fenêtre de 300px, molette et glissement déplacent bien, un glissement laisse le multitâche ouvert et un tap propre ouvre toujours l'app.
- **Les photographies n'arrivaient jamais dans la galerie.** Un cliché pris via l'hébergement média était ajouté en renvoyant son URL par le même chemin qu'un lien collé par un joueur — lequel la confronte à la liste blanche des hôtes de FOND D'ÉCRAN. Cette liste existe pour empêchîr qu'on colle n'importe quel lien et ne nomme évidemment pas le CDN de l'opérateur : chaque photo prise par le téléphone était donc refusée en `badhost` et la galerie restait vide. Le serveur la stocke directement désormais : c'est lui qui a fabriqué cette URL, depuis la capture de ce joueur, quelques secondes plus tôt. Rien n'est pris pour acquis. Un fichier envoyé par le téléphone est aussi accepté comme fond d'écran, pour la même raison.

### Modifications

- **L'objet téléphone est désormais requis par défaut, et il n'y a plus de touche.** `Config.Settings.requireItem` est activé et `Config.Key` vaut `false` : le téléphone s'ouvre en utilisant l'objet, comme n'importe quel autre. Un téléphone que chaque personnage possède gratuitement n'est pas un objet, c'est un menu. Remettez un nom de touche dans `Config.Key` pour proposer aussi un raccourci, ou `set phone_requireItem false` pour en redonner un à tout le monde. Marquez l'objet `useable` dans le catalogue de votre framework — sur qb-core, c'est `qb-core/shared/items.lua`. Cela vaut dans les deux sens : un personnage sans combiné ne peut pas non plus être appelé, et les messages qu'on lui envoie attendent qu'il en tienne un.
- **Le téléphone tient une vraie journée.** La batterie se vidait en huit heures au repos et en moins de trois écran allumé, ce qui se lit comme un téléphone cassé plutôt que comme une mécanique. C'est 48 heures en poche et 24 écran allumé — une longue session se termine avec de la charge, et qui ne le range jamais doit quand même trouver un chargeur.
- **Le téléphone est verrouillé à 100 % et le curseur de taille disparaît.** C'est le correctif honnête plutôt que l'astucieux : le combiné est mis en page en pixels à 372x784, donc toute taille autre que 100 % était un `transform: scale()` sur une image déjà dessinée, et chaque glyphe s'adoucissait. Une valeur stockée à 80 % est ignorée plutôt que bornée, pour que personne ne reste avec un téléphone flou sans moyen d'y revenir. `Config.DeviceSize` reste pour un opérateur qui veut une autre taille fixe et accepte le flou.
- **La batterie tient environ deux jours d'utilisation.** 48 heures au repos avec un facteur 2 pour l'écran donnait exactement 24 heures d'usage, or 24 est le seuil à dépasser et non à atteindre. C'est 72 heures au repos avec un facteur 1,5 — 1,39 % par heure fermé, 2,08 % écran allumé, soit 72 et 48 heures pour se vider. Le calcul est écrit à côté du réglage pour être vérifié plutôt que cru.
- **F2 ouvre le téléphone, et chaque joueur peut la changer.** Le raccourci passe par `RegisterKeyMapping`, donc il apparaît dans les Paramètres → Touches → FiveM du jeu sous « iFruit », et ce qu'un joueur y assigne l'emporte sur la config et survit à un redémarrage — le téléphone n'a rien à stocker ni à synchroniser. F2 plutôt que F1, revendiquée par plus de ressources que n'importe quelle autre touche. L'objet reste requis : la touche ouvre un téléphone qu'on possède et le dit clairement sinon. `Config.Key = false` retire le raccourci et ne laisse que l'objet.


---

## [1.1.4] - 2026-07-25

### Added (English first)

- **Payphones, on the boxes already standing in Los Santos.** Every phone box prop in the game now works. There is **no coordinate list to maintain**: the client looks for the booth props themselves (`prop_phonebox_01` through `04` and `prop_ld_phonebox`, plus anything you add to `Config.Booth.models`), so a booth in a new MLO works the moment the MLO loads, and one a map edit moved moves with it. With `ox_target`, `qb-target` or `qtarget` running the interaction is registered **once per model** and covers every box on the map at once; without one, the nearest box gets a marker and an `E` prompt.
- **A booth places calls and can never receive them.** This is enforced three independent ways rather than assumed: a booth number is never entered in the online table, never written to `vphone_characters`, and both the call path and the SMS path refuse a booth-shaped number outright with a message that says why. Dialling a box you read off the street tells you it cannot be called back instead of lying that the number does not exist.
- **A booth's number is derived from where it stands.** `bridge/shared/booth.lua` turns the prop's coordinates into a stable number through a pure function both the client and the server compute independently, so the box outside the Vanilla Unicorn always shows the same digits and no database row is needed. It also means a modified client that forges its position buys a *different* payphone number, not a chosen one.
- **Prepaid calling cards.** A `prepaid_card` inventory item, worth `Config.Booth.card.seconds` of talk time. Feed it into the box with the on-screen slot, or use it straight from the inventory anywhere - both go through the same server path. Talk time is held per character in `vphone_kv`, so it survives a reconnect, and it is billed by a **server-side ticker one second at a time**: a client that stops reporting is a client that stops talking.
- **Emergency numbers are free.** Anything in `Config.Booth.freeNumbers` (911, 112, 999 by default) connects with no card and no credit, because a payphone that will not call an ambulance is a prop rather than a phone.
- **Walk away and it hangs up.** The handset is on a cord: past `Config.Booth.leashDistance` the call drops, watched on the client and re-checked by the server's own ticker.
- **New exports.** `GetBoothCredit`, `AddBoothCredit`, `BoothNumberAt` and `IsBoothNumber`, for a shop that sells talk time or a dispatch that wants to name the box a call came from. See `API.md`.
- **Twelve new payphone options for server owners.** The box was the least configurable thing in the resource; now nothing in it is hardcoded. `interact.target` forces or disables the target script (`off` uses the marker even when ox_target is running), and the key, icon, label, marker type, colour, scale, height, bob and scan cadence all move to config. `blip` puts the boxes on the map, off by default because Los Santos has around a hundred of them. `allowInVehicle`, `maxDialLength` (enforced on the **server**, so a modified page cannot bypass it), `cooldownSeconds` against redial spam, `anonymous` to withhold the box's number, and `reachTolerance` to tighten or loosen the server's own proximity check.
- **Player settings for calls, privacy and notifications.** Four new switches in Settings, in the phone's own idiom. **Hide my number** withholds your caller ID — the server has always supported anonymous calls and nothing in the interface ever reached it, so the feature existed and was unusable; the row appears only when `Config.Settings.anonymous` allows it. **Silence unknown callers** takes calls from numbers not in your contacts without ringing or opening the handset; they still land in your missed calls, which is the point. **Show previews** off means a notification says who it is from and not what it says — the body is stripped on the client before it is ever sent to the page, so it is not merely hidden. **Raise to show** turns off the handset rising out of your pocket while keeping the buzz.
- **Payphone blips can be culled by distance.** `Config.Booth.blip.distance` removes a box's blip once the player is more than that many metres from it, and brings it back on the next approach. `0` keeps every box ever walked past. This is a real cull and not the same thing as `shortRange`, which is a GTA flag that only hides a blip from the paused map.
- **The panel is a real call box faceplate.** Built from the anatomy of an actual payphone rather than styled as a dark card: brushed stainless with screw heads at the corners, the operator's **orange identification plate** carrying the number of the box, a chrome coin slot, a recessed amber readout behind glass, milled chrome keys, a card reader with a milled mouth, an engraved instruction placard, and the coin return cup at the bottom. The handset hangs in a cradle on a short armored cord. The keypad carries the **old letter groups** — PRS and WXY, no Q and no Z, and 0 is OPER — which is what dates a box of this age. `Config.Booth.brand` names the operator on the plate; Los Santos has two, Badger and Whiz.
- **The payphone keypad sounds like chrome on steel.** A sine wave cannot sound metallic however you tune it, so the keys are synthesised properly: a few milliseconds of broadband noise for the mechanical impact, then **inharmonic** partials at the free-bar ratios 1 : 2.76 : 5.40, each mode decaying faster than the one below it. That inharmonicity is the whole thing — a harmonic stack is a chord, an off-grid one is struck metal. Rendered to `sounds/ui_boothkey.wav` and `ui_boothkeyback.wav` by `tools/make-sounds.py`, from a fixed seed so a rebuild is byte-identical, with an inharmonic oscillator fallback for servers running with sound files off. The delete key is lower and duller than a digit.
- **And the keys put real DTMF on the line.** Every digit plays its actual tone pair from the standard table — rows 697/770/852/941 against columns 1209/1336/1477 — sitting under the clack the way it does on a real box. The delete key stays silent on the wire, because it was never on it.
- **`Bridge.RemoveItem` and `Bridge.ItemCount`.** Item consumption across `ox_inventory`, `qs-inventory`, `ps-inventory`, `qb-inventory`, `origen_inventory`, `codem-inventory`, and the qb and ESX player objects directly. Unlike `Bridge.HasItem`, these **fail closed**: a remove that cannot be confirmed grants nothing, so credit is never paid out for an item that never left the inventory.

### Fixed

- **Usable items were never registered on qb-core.** `CreateUseableItem` is **not** an export of qb-core — its entire export list is `SetMethod`, `SetField`, the job/gang/item-registry helpers, `GetCoreVersion` and `ExploitBan`. The call raised inside a pcall, the pcall swallowed it, and the item was never registered, so the **power bank and the prepaid calling card did nothing when used**. qbx_core *does* export it, which is why this went unnoticed. The shared object is now tried first and the export second, covering both forks.
- **Item reads crashed on modern qb-core.** `Bridge.HasItem` and `Bridge.RemoveItem` fell back to `Player.Functions.GetItemByName` and `Player.Functions.RemoveItem`. Item handling moved out to qb-inventory — `GetItemByName` does not appear anywhere in the qb-core repository any more — so both raised `attempt to call a nil value`. Reads now sum `PlayerData.items`, the one thing every qb build still has, and a removal with no inventory to ask fails closed.
- **The phone number reverted on logout on qb-core.** `Bridge.Numbers.Set` wrote `players.charinfo` with a direct `UPDATE`, but qb-core keeps charinfo on the player object and writes it back over the row on every save (`charinfo = json.encode(PlayerData.charinfo)` in `Player:Save`). The number the phone minted was undone the moment the character logged out. The live copy is now updated through `SetPlayerData` as well as the row, so qb-core persists it itself.
- **Phone calls went through pma-voice's RADIO, not its call channel.** The single worst bug in the resource, and it broke four things at once. pma-voice only adds radio targets to your voice while the radio key is **held** — `(radioPressed and isRadioEnabled()) and radioData or {}` — so a phone call needed push-to-talk to be heard, while call targets are always live. Taking a call also **kicked the player off the job radio** they were on, and hanging up (`setRadioChannel(0)`) left them off it. A server with `voice_enableRadios 0` got silent calls, and `voice_enableCalls` was ignored. Worst of all, calls occupied *radio* channels 700–724, so a server using a radio channel in that range could have a phone call and a radio merge and let strangers hear each other. Calls now use `setCallChannel`, exactly as pma-voice documents, and radio is left untouched.
- **The Jobs app was broken on every server.** `V.Use('v-cityhall').OpenPositions()` had no stub behind it, yet `stubIsLive` reported v-cityhall as started, so the lookup fell through to the real exports of a resource nobody runs. The call errored, took the whole `v-phone:jobs` callback down with it, and the app never answered. There is now a `v-cityhall` stub that lists every job the framework knows, at its entry rank and starting pay.
- **`Core.Notify` did not exist.** `server/main.lua` calls it, and the bridge never defined it, so using a power bank raised `attempt to call a nil value (field 'Notify')` instead of telling the player their phone had charged. It now forwards to the same notifier as `V.Notify`.
- **`v-inventory` had no `RemoveItem`.** The power bank tried to consume itself through the compatibility shim, which only published `RegisterUsableItem` and `HasItem`. The shim now offers `RemoveItem` and `ItemCount`, wired to the bridge.
- **A character could in principle be minted a booth-shaped number.** Only reachable by configuring `Config.NumberFormat` and `Config.Booth.numberFormat` to overlap, but the holder would have been unreachable by call or text. The minter now skips any candidate that reads as a payphone.

### Changed

- **Booth calls reuse the call machinery whole.** The same `v-voice` channels, the same ring and length limits, the same call-log row on the recipient's phone. What is deliberately *not* checked on the caller's side is the phone item, the battery and the signal - the point of a payphone is that it works when your own phone does not.
- **A call flagged as coming from a booth no longer touches the player's handset.** No phone opens, no prop is attached, and no voicemail is offered on no-answer, since there is no phone open to record into. State survives a resource restart: a resynced booth call is handed back to the box rather than drawn on the handset.

---

## [1.1.4] - 2026-07-25

### Ajouts (miroir français)

- **Des cabines téléphoniques, sur les bornes déjà présentes à Los Santos.** Toutes les cabines du jeu fonctionnent désormais. Il n'y a **aucune liste de coordonnées à maintenir** : le client cherche les props de cabine eux-mêmes (`prop_phonebox_01` à `04` et `prop_ld_phonebox`, plus tout ce que vous ajoutez à `Config.Booth.models`), donc une cabine dans un nouvel MLO fonctionne dès que l'MLO charge, et une cabine déplacée par une édition de map se déplace avec elle. Avec `ox_target`, `qb-target` ou `qtarget`, l'interaction est enregistrée **une fois par modèle** et couvre toutes les cabines de la map d'un coup ; sans eux, la cabine la plus proche reçoit un marqueur et une invite `E`.
- **Une cabine passe des appels et ne peut jamais en recevoir.** C'est garanti de trois façons indépendantes plutôt que supposé : un numéro de cabine n'entre jamais dans la table des joueurs en ligne, n'est jamais écrit dans `vphone_characters`, et le chemin d'appel comme le chemin SMS refusent explicitement un numéro en forme de cabine avec un message qui l'explique. Composer le numéro lu sur une borne dans la rue vous dit qu'on ne peut pas la rappeler, au lieu de prétendre que le numéro n'existe pas.
- **Le numéro d'une cabine est dérivé de sa position.** `bridge/shared/booth.lua` transforme les coordonnées du prop en un numéro stable via une fonction pure que le client et le serveur calculent indépendamment : la borne devant le Vanilla Unicorn affiche toujours les mêmes chiffres, et aucune ligne en base n'est nécessaire. Cela signifie aussi qu'un client modifié qui falsifie sa position obtient un *autre* numéro de cabine, pas un numéro choisi.
- **Cartes prépayées.** Un item d'inventaire `prepaid_card`, valant `Config.Booth.card.seconds` de temps de communication. Insérez-la dans la fente à l'écran, ou utilisez-la directement depuis l'inventaire n'importe où : les deux passent par le même chemin serveur. Le crédit est conservé par personnage dans `vphone_kv`, il survit donc à une reconnexion, et il est décompté par un **compteur serveur seconde par seconde** : un client qui cesse de répondre est un client qui cesse de parler.
- **Les numéros d'urgence sont gratuits.** Tout ce qui figure dans `Config.Booth.freeNumbers` (911, 112, 999 par défaut) est joignable sans carte et sans crédit, car une cabine qui n'appelle pas une ambulance est un décor, pas un téléphone.
- **Éloignez-vous et ça raccroche.** Le combiné est au bout d'un fil : au-delà de `Config.Booth.leashDistance`, l'appel tombe, surveillé côté client et revérifié par le compteur du serveur.
- **Nouveaux exports.** `GetBoothCredit`, `AddBoothCredit`, `BoothNumberAt` et `IsBoothNumber`, pour une boutique qui vend du temps de communication ou un dispatch qui veut nommer la borne d'où vient un appel. Voir `API.md`.
- **Douze nouvelles options de cabine pour les administrateurs.** La borne était l'élément le moins configurable de la ressource ; plus rien n'y est en dur. `interact.target` force ou désactive le script de target (`off` utilise le marqueur même si ox_target tourne), et la touche, l'icône, le libellé, le type de marqueur, sa couleur, son échelle, sa hauteur, son flottement et la cadence de scan passent en config. `blip` place les bornes sur la carte, désactivé par défaut car Los Santos en compte une centaine. `allowInVehicle`, `maxDialLength` (contrôlé côté **serveur**, donc une page modifiée ne peut pas le contourner), `cooldownSeconds` contre le spam de rappel, `anonymous` pour masquer le numéro de la borne, et `reachTolerance` pour resserrer ou relâcher la vérification de proximité du serveur.
- **Réglages joueur pour les appels, la confidentialité et les notifications.** Quatre nouveaux interrupteurs dans les Réglages, dans l'idiome du téléphone. **Masquer mon numéro** cache votre identifiant d'appelant — le serveur a toujours su gérer les appels anonymes et rien dans l'interface n'y accédait : la fonctionnalité existait et était inutilisable ; la ligne n'apparaît que si `Config.Settings.anonymous` l'autorise. **Silence pour les inconnus** reçoit les appels des numéros absents de vos contacts sans sonnerie et sans ouvrir le combiné ; ils arrivent quand même dans vos appels manqués, ce qui est tout l'intérêt. **Afficher les aperçus** désactivé fait qu'une notification indique de qui elle vient et non ce qu'elle dit — le corps est retiré côté client avant même d'être envoyé à la page, il n'est donc pas simplement masqué. **Sortir le téléphone** désactive la remontée du combiné hors de la poche tout en conservant la vibration.
- **Les blips de cabine peuvent être limités par distance.** `Config.Booth.blip.distance` retire le blip d'une borne dès que le joueur s'en éloigne de plus de tant de mètres, et le rétablit à la prochaine approche. `0` conserve toutes les bornes déjà croisées. C'est un vrai retrait, à ne pas confondre avec `shortRange`, un drapeau GTA qui masque seulement le blip de la carte en pause.
- **Le panneau est une vraie façade de cabine.** Construit à partir de l'anatomie d'une cabine réelle plutôt que stylisé en carte sombre : inox brossé avec têtes de vis aux angles, **plaque d'identification orange** de l'opérateur portant le numéro de la borne, fente à pièces chromée, afficheur ambre encastré derrière verre, touches en chrome fraisé, lecteur de carte à bouche fraisée, plaque d'instructions gravée, et le godet de retour de pièces en bas. Le combiné pend dans son support au bout d'un court cordon blindé. Le clavier porte les **anciens groupes de lettres** — PRS et WXY, ni Q ni Z, et 0 = OPER — ce qui date une borne de cette époque. `Config.Booth.brand` nomme l'opérateur sur la plaque ; Los Santos en compte deux, Badger et Whiz.
- **Le clavier de la cabine sonne comme du chrome sur de l'acier.** Un sinus ne peut pas sonner métallique, quel que soit l'accord : les touches sont donc synthétisées correctement — quelques millisecondes de bruit large bande pour l'impact mécanique, puis des partiels **inharmoniques** aux rapports de barre libre 1 : 2,76 : 5,40, chaque mode s'éteignant plus vite que celui du dessous. C'est cette inharmonicité qui fait tout : une pile harmonique est un accord, une pile hors grille est du métal frappé. Rendus dans `sounds/ui_boothkey.wav` et `ui_boothkeyback.wav` par `tools/make-sounds.py`, depuis un seed fixe pour qu'une reconstruction soit bit-à-bit identique, avec un repli par oscillateurs inharmoniques pour les serveurs sans fichiers son. La touche d'effacement est plus basse et plus sourde qu'un chiffre.
- **Et les touches émettent du vrai DTMF.** Chaque chiffre joue sa paire de tonalités de la table standard — lignes 697/770/852/941 contre colonnes 1209/1336/1477 — placée sous le clac comme sur une vraie borne. La touche d'effacement reste muette sur la ligne, puisqu'elle n'y a jamais été.
- **`Bridge.RemoveItem` et `Bridge.ItemCount`.** Consommation d'items sur `ox_inventory`, `qs-inventory`, `ps-inventory`, `qb-inventory`, `origen_inventory`, `codem-inventory`, et directement sur les objets joueur qb et ESX. Contrairement à `Bridge.HasItem`, ces fonctions **échouent en refusant** : un retrait qui ne peut être confirmé n'accorde rien, donc aucun crédit n'est payé pour un item qui n'a jamais quitté l'inventaire.

### Correctifs

- **Les items utilisables n'étaient jamais enregistrés sur qb-core.** `CreateUseableItem` n'est **pas** un export de qb-core — sa liste complète d'exports est `SetMethod`, `SetField`, les utilitaires métiers/gangs/registre d'items, `GetCoreVersion` et `ExploitBan`. L'appel levait une erreur à l'intérieur d'un pcall, le pcall l'avalait, et l'item n'était jamais enregistré : **la batterie externe et la carte prépayée ne faisaient rien quand on les utilisait**. qbx_core, lui, l'exporte — d'où le fait que ça soit passé inaperçu. L'objet partagé est désormais essayé en premier et l'export en second, ce qui couvre les deux forks.
- **Les lectures d'inventaire plantaient sur qb-core moderne.** `Bridge.HasItem` et `Bridge.RemoveItem` retombaient sur `Player.Functions.GetItemByName` et `Player.Functions.RemoveItem`. La gestion d'items a migré vers qb-inventory — `GetItemByName` n'apparaît plus nulle part dans le dépôt qb-core — donc les deux levaient `attempt to call a nil value`. Les lectures somment maintenant `PlayerData.items`, la seule chose que tous les builds qb possèdent encore, et une suppression sans inventaire disponible échoue en refusant.
- **Le numéro de téléphone revenait en arrière à la déconnexion sur qb-core.** `Bridge.Numbers.Set` écrivait `players.charinfo` par un `UPDATE` direct, mais qb-core garde charinfo sur l'objet joueur et le réécrit par-dessus la ligne à chaque sauvegarde (`charinfo = json.encode(PlayerData.charinfo)` dans `Player:Save`). Le numéro généré par le téléphone était annulé dès la déconnexion du personnage. La copie vivante est maintenant mise à jour via `SetPlayerData` en plus de la ligne, et qb-core la persiste lui-même.
- **Les appels passaient par la RADIO de pma-voice, pas par son canal d'appel.** Le pire bug de la ressource, et il cassait quatre choses à la fois. pma-voice n'ajoute les cibles radio à votre voix que tant que la touche radio est **maintenue** — `(radioPressed and isRadioEnabled()) and radioData or {}` — un appel téléphonique exigeait donc le push-to-talk pour être entendu, alors que les cibles d'appel sont toujours actives. Prendre un appel **éjectait aussi le joueur de la radio de service** sur laquelle il était, et raccrocher (`setRadioChannel(0)`) l'y laissait déconnecté. Un serveur avec `voice_enableRadios 0` avait des appels muets, et `voice_enableCalls` était ignoré. Pire encore, les appels occupaient les canaux *radio* 700 à 724 : un serveur utilisant un canal radio dans cette plage pouvait voir un appel et une radio fusionner et laisser des inconnus s'entendre. Les appels utilisent maintenant `setCallChannel`, exactement comme pma-voice le documente, et la radio n'est plus touchée.
- **L'app Emplois était cassée sur tous les serveurs.** `V.Use('v-cityhall').OpenPositions()` n'avait aucun stub derrière lui, alors que `stubIsLive` déclarait v-cityhall démarré : la résolution tombait sur les exports réels d'une ressource que personne ne fait tourner. L'appel levait une erreur, emportait tout le callback `v-phone:jobs` avec lui, et l'app ne répondait jamais. Un stub `v-cityhall` liste désormais chaque métier connu du framework, à son rang d'entrée et son salaire de départ.
- **`Core.Notify` n'existait pas.** `server/main.lua` l'appelle et le bridge ne l'a jamais défini : utiliser une batterie externe levait `attempt to call a nil value (field 'Notify')` au lieu d'annoncer au joueur que son téléphone était rechargé. Elle est désormais redirigée vers le même notificateur que `V.Notify`.
- **`v-inventory` n'avait pas de `RemoveItem`.** La batterie externe tentait de se consommer via le shim de compatibilité, qui ne publiait que `RegisterUsableItem` et `HasItem`. Le shim expose maintenant `RemoveItem` et `ItemCount`, câblés sur le bridge.
- **Un personnage pouvait en principe recevoir un numéro en forme de cabine.** Atteignable seulement en configurant `Config.NumberFormat` et `Config.Booth.numberFormat` de façon à se recouvrir, mais le porteur aurait été injoignable par appel comme par SMS. Le générateur écarte désormais tout candidat qui se lit comme une cabine.

### Modifications

- **Les appels de cabine réutilisent la machinerie d'appel entière.** Les mêmes canaux `v-voice`, les mêmes limites de sonnerie et de durée, la même ligne de journal d'appel sur le téléphone du destinataire. Ce qui n'est délibérément *pas* vérifié côté appelant : l'item téléphone, la batterie et le signal — l'intérêt d'une cabine est justement de fonctionner quand votre propre téléphone ne le fait pas.
- **Un appel marqué comme venant d'une cabine ne touche plus au combiné du joueur.** Aucun téléphone ne s'ouvre, aucun prop n'est attaché, et aucune messagerie vocale n'est proposée en cas de non-réponse, puisqu'aucun téléphone n'est ouvert pour enregistrer. L'état survit à un redémarrage de ressource : un appel de cabine resynchronisé est rendu à la borne plutôt que dessiné sur le combiné.

---

## [1.1.3] - 2026-07-23

### Added (English first)

- **A live FaceTime picture.** Opt in with `Config.FaceTime.videoFeed = true` and a video call carries a real moving picture of the other player, not just the layout. The front camera is raised for the duration of the call, [screenshot-basic](https://github.com/citizenfx/screenshot-basic) grabs a frame a few times a second, and the **page shrinks and crops it to a thumbnail before anything is sent** - only that few-kilobyte frame is relayed, to the one other participant. Off by default, and honestly experimental: `fps`, `width`, `height`, `quality` and `maxFrameKb` are all yours to tune.
- **A guarded relay.** `v-phone:server:faceFrame` accepts a frame only from a player who is in an *active* call flagged as video, rate-limits per source against the configured fps, drops anything over `maxFrameKb`, and forwards it to the other participant alone. Frame state is cleared on disconnect.

### Changed

- **The selfie camera is shared.** The camera app's flip and a video call now go through one code path, so a FaceTime call raises the front camera and lowers it on hang-up without fighting the camera app.
- **The 1.1.2 note that FiveM "cannot stream a live face" is retired.** It cannot stream video the way a browser can - but relayed thumbnails do the job, and that is what this release ships.

---

## [1.1.3] - 2026-07-23

### Ajouts (miroir français)

- **Une image FaceTime en direct.** Activez `Config.FaceTime.videoFeed = true` et un appel vidéo transporte une vraie image animée de l'autre joueur, pas seulement la mise en page. La caméra frontale est levée pendant tout l'appel, [screenshot-basic](https://github.com/citizenfx/screenshot-basic) capture une image plusieurs fois par seconde, et **la page la réduit et la recadre en vignette avant tout envoi** : seule cette image de quelques kilo-octets est relayée, au seul autre participant. Désactivé par défaut, et honnêtement expérimental : `fps`, `width`, `height`, `quality` et `maxFrameKb` sont à régler.
- **Un relais protégé.** `v-phone:server:faceFrame` n'accepte une image que d'un joueur en appel *actif* marqué vidéo, limite le débit par source selon les fps configurés, rejette tout ce qui dépasse `maxFrameKb`, et transmet au seul autre participant. L'état est nettoyé à la déconnexion.

### Modifications

- **La caméra selfie est mutualisée.** Le retournement de l'appareil photo et un appel vidéo passent par le même chemin : un appel FaceTime lève la caméra frontale et la baisse au raccrochage sans entrer en conflit avec l'appareil photo.
- **La note de la 1.1.2 disant que FiveM « ne peut pas diffuser un visage en direct » est retirée.** Il ne peut pas diffuser de la vidéo comme un navigateur - mais des vignettes relayées font le travail, et c'est ce que livre cette version.

---

## [1.1.2] - 2026-07-23

### Added (English first)

- **Media hosting on a CDN.** With `Config.Media` on and [screencapture](https://github.com/itschip/screencapture) installed, the camera's photos and the social apps' video clips are captured in game and uploaded to Fivemanage (or any host, via `provider = 'custom'`). The upload runs on the server, so the API key never reaches a client - set it with `set phone_media_key`. Every file is tracked in `vphone_media` and **auto-deleted after `autoDeleteDays`**, dropped from the host too when `deleteEndpoint` is set.
- **Video clips.** A Video mode in the camera records a real WebM clip, capped at `Config.Media.video.maxSeconds` (1..30), and posts it to Bleeter or Snapmatic. Video posts play inline in the feed.
- **Front camera (selfie).** A flip control puts a game camera in front of the ped, so a photo or a clip is of the player. It is torn down when the camera or the phone closes.
- **FaceTime.** A FaceTime button on a contact starts a real voice call presented as a video call on both phones. FiveM cannot stream a live face, so there is no video feed - the layout is the difference, and it is documented as such.
- **A fivemanage/screencapture dependency row** in the README, with the git link.

### Changed

- **The home indicator is fixed.** It answered to a bare click on a thin pill, which missed when a swipe started a little off it or moved as it landed. It now tracks a pointer across a tall, wide hit area and fires on a quick upward flick or a clean tap, without double-firing.

---

## [1.1.2] - 2026-07-23

### Ajouts (miroir français)

- **Hébergement média sur un CDN.** Avec `Config.Media` activé et [screencapture](https://github.com/itschip/screencapture) installé, les photos de l'appareil photo et les clips vidéo des réseaux sociaux sont capturés en jeu et envoyés vers Fivemanage (ou n'importe quel hôte, via `provider = 'custom'`). L'upload tourne sur le serveur, la clé d'API n'atteint jamais un client - définissez-la avec `set phone_media_key`. Chaque fichier est suivi dans `vphone_media` et **supprimé automatiquement après `autoDeleteDays`**, retiré de l'hôte aussi quand `deleteEndpoint` est défini.
- **Clips vidéo.** Un mode Vidéo dans l'appareil photo enregistre un vrai clip WebM, plafonné à `Config.Media.video.maxSeconds` (1..30), et le publie sur Bleeter ou Snapmatic. Les posts vidéo se lisent dans le fil.
- **Caméra frontale (selfie).** Un bouton place une caméra de jeu devant le ped, pour se photographier ou se filmer. Elle est démontée quand l'appareil photo ou le téléphone se ferme.
- **FaceTime.** Un bouton FaceTime sur un contact démarre un vrai appel vocal présenté comme un appel vidéo sur les deux téléphones. FiveM ne peut pas diffuser un visage en direct : il n'y a pas de flux vidéo, la mise en page fait la différence, et c'est documenté ainsi.
- **Une ligne de dépendance fivemanage/screencapture** dans le README, avec le lien git.

### Modifications

- **La barre d'accueil est corrigée.** Elle ne répondait qu'à un clic sur une pastille fine, qui ratait quand un swipe démarrait un peu à côté ou bougeait à l'arrivée. Elle suit maintenant un pointeur sur une grande zone de détection et se déclenche sur un coup vers le haut ou un tap net, sans double déclenchement.

---

## [1.1.1] - 2026-07-23

### Added (English first)

- **Police forensics.** A warrant terminal at the points in `Config.Police.points`. An officer in a police job, at a terminal, reads a suspect's phone from the number: texts, contacts, calls, social posts and DMs, all in the clear. Every read is re-checked on the server and logged. The terminal uses ox_target / qb-target when present, otherwise a marker and the E key.
- **Cipher, honestly.** Cipher is end-to-end encrypted and the server holds no key, so its content cannot be read by anyone - including the police. The terminal shows the recoverable metadata (who, when, key fingerprints). `Config.Police.cipher.intercept`, off by default, opts into lawful intercept: the phone keeps a server-wrapped copy so the terminal can crack the content, slowly and not always. Left off, Cipher stays a true secret.
- **`/refreshphone`** (and `/refresh-phone`) - a get-out-of-jail command that tears down a stuck phone: the prop, the animation, the NUI focus, the control guard. For when the phone sticks to the hand. The server can trigger the same on a player with `TriggerClientEvent('v-phone:client:forceReset', src)`.
- **A Dependencies section in the README** with the git link of every optional resource: screenshot-basic for the camera, pma-voice for calls, ox_lib, ox_target, and each framework.

### Changed

- Documentation covers the police terminal and the forensic Cipher model in [COMPATIBILITY.md](COMPATIBILITY.md), and the new commands in [API.md](API.md).

---

## [1.1.1] - 2026-07-23

### Ajouts (miroir français)

- **Enquête police.** Un terminal d'analyse aux points de `Config.Police.points`. Un agent d'un métier de police, à un terminal, lit le téléphone d'un suspect à partir du numéro : SMS, contacts, appels, publications et messages privés, tout en clair. Chaque lecture est revérifiée sur le serveur et journalisée. Le terminal utilise ox_target / qb-target si présents, sinon un marqueur et la touche E.
- **Cipher, honnêtement.** Cipher est chiffré de bout en bout et le serveur ne détient aucune clé : son contenu ne peut être lu par personne, police comprise. Le terminal montre les métadonnées récupérables (qui, quand, empreintes de clés). `Config.Police.cipher.intercept`, désactivé par défaut, active l'interception légale : le téléphone garde une copie enveloppée côté serveur pour que le terminal casse le contenu, lentement et pas toujours. Laissé désactivé, Cipher reste un vrai secret.
- **`/refreshphone`** (et `/refresh-phone`) - une commande de secours qui démonte un téléphone bloqué : le prop, l'animation, le focus NUI, le garde des contrôles. Pour quand le téléphone reste collé à la main. Le serveur peut déclencher la même chose sur un joueur avec `TriggerClientEvent('v-phone:client:forceReset', src)`.
- **Une section Dépendances dans le README** avec le lien git de chaque ressource optionnelle : screenshot-basic pour l'appareil photo, pma-voice pour les appels, ox_lib, ox_target, et chaque framework.

### Modifications

- La documentation couvre le terminal police et le modèle Cipher forensique dans [COMPATIBILITY.md](COMPATIBILITY.md), et les nouvelles commandes dans [API.md](API.md).

---

## [1.1.0] - 2026-07-23

### Added (English first)

- **Import / export a character's whole phone** - `ExportPhone(citizenid)` returns a plain table of contacts, notes, app data, preferences and the mailbox; `ImportPhone(citizenid, data, replace)` writes it back. For a character transfer, a backup, or a support restore. The number is not carried: it belongs to the server that minted it.
- **An admin toolkit** - `/phoneadmin info | open | battery | number | message | wipe`, gated by `Config.Admin.ace`, plus a matching set of exports (`AdminReadPhone`, `OpenPhoneFor`, `WipePhone`) so an admin menu of any framework can drive them. `WipePhone` deletes every trace of a character across all twenty seven tables. The qb-core admin menu is detected and pointed at the command.
- **External charging** - `SetCharging(src, on, rate)` lets an electric car, a solar pack or a socket prop charge the phone. It wins over the built-in charger detection while it is on, capped by `Config.ExternalCharging.maxRate`.
- **A lot more config** - `Config.Admin` (permission, which actions staff may take, wipe confirmation, the qb-core menu), `Config.ExternalCharging`, and `Config.MigrateLegacyTables`.

### Changed

- **Table migration is off by default and verifies the schema before it touches anything.** A fresh install never rewrites its database on first boot. When turned on (config or `set phone_migrate auto`), a legacy table is renamed only if its columns match this resource's own - so another script's table that merely shares a name is left completely alone. Verified live: a foreign `social_posts` with different columns survived untouched while a genuine `phone_contacts` migrated.

### Fixed

- **`WipePhone` ran a `citizenid` delete against `vphone_messages`**, which is keyed by from_cid / to_cid and has no such column, so it threw. The conversation tables are cleared by their own keys now. Found by calling the export on a live server.

---

## [1.1.0] - 2026-07-23

### Ajouts (miroir français)

- **Import / export du téléphone entier d'un personnage** - `ExportPhone(citizenid)` renvoie une table simple des contacts, notes, données d'app, préférences et boîte mail ; `ImportPhone(citizenid, data, replace)` la réécrit. Pour un transfert de personnage, une sauvegarde, une restauration. Le numéro n'est pas emporté : il appartient au serveur qui l'a créé.
- **Une boîte à outils admin** - `/phoneadmin info | open | battery | number | message | wipe`, protégée par `Config.Admin.ace`, plus les exports correspondants (`AdminReadPhone`, `OpenPhoneFor`, `WipePhone`) pour qu'un menu admin de n'importe quel framework les pilote. `WipePhone` supprime toute trace d'un personnage sur les vingt-sept tables. Le menu admin qb-core est détecté et pointé sur la commande.
- **Recharge externe** - `SetCharging(src, on, rate)` permet à une voiture électrique, un sac solaire ou une prise de recharger le téléphone. Elle l'emporte sur la détection de borne intégrée tant qu'elle est active, plafonnée par `Config.ExternalCharging.maxRate`.
- **Beaucoup plus de config** - `Config.Admin` (permission, actions permises, confirmation du wipe, menu qb-core), `Config.ExternalCharging`, et `Config.MigrateLegacyTables`.

### Modifications

- **La migration des tables est désactivée par défaut et vérifie le schéma avant de toucher quoi que ce soit.** Une installation neuve ne réécrit jamais sa base au premier démarrage. Une fois activée (config ou `set phone_migrate auto`), une table héritée n'est renommée que si ses colonnes correspondent à celles de cette ressource - la table d'un autre script qui partage simplement un nom est laissée totalement intacte. Vérifié en réel : une `social_posts` étrangère aux colonnes différentes a survécu sans être touchée pendant qu'une vraie `phone_contacts` migrait.

### Correctifs

- **`WipePhone` lançait une suppression par `citizenid` sur `vphone_messages`**, qui est clé par from_cid / to_cid et n'a pas cette colonne : il levait une erreur. Les tables de conversation sont maintenant nettoyées par leurs propres clés. Trouvé en appelant l'export sur un serveur vivant.

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
