# Développer une application iFruit

iFruit AppKit permet d’ajouter une application complète sans modifier le téléphone, sans
bundler et sans framework JavaScript. Une application peut tenir dans un dossier, être
installable depuis le FruitStore et utiliser les mêmes composants Clear Glass que les
applications natives.

## Démarrage en 60 secondes

Le générateur crée un dossier propre avec manifeste et page AppKit :

```powershell
powershell -ExecutionPolicy Bypass -File tools/new-app.ps1 `
  -Id dispatch -Label "Dispatch" -Developer "Mon Studio" -Category duty
```

Ou manuellement :

1. Dupliquer `apps/example`.
2. Renommer le dossier avec l’identifiant de l’application.
3. Modifier `app.lua`.
4. Construire l’interface dans `index.html`.
5. Redémarrer `v-phone`. L’application apparaît automatiquement dans le FruitStore.

Il n’est pas nécessaire de modifier `fxmanifest.lua`, `config.lua`, le client ou le
serveur du téléphone. Les motifs `apps/*` chargent automatiquement le nouveau dossier.

```text
apps/
  mon_app/
    app.lua       obligatoire : manifeste de l’application
    index.html    obligatoire : interface
    client.lua    facultatif : logique FiveM côté client
    server.lua    facultatif : logique serveur et callbacks
    app.css       facultatif
    app.js        facultatif
```

## Manifeste complet

```lua
PhoneApp {
    id        = 'mon_app',
    label     = 'Mon application',
    icon      = 'note',
    category  = 'utilities',
    desc      = 'Une phrase claire pour la page FruitStore.',
    developer = 'Mon Studio',
    version   = '1.2.0',
    accent    = '#0A84FF',

    optional  = true,  -- installée par le joueur depuis le FruitStore
    required  = false, -- ne peut pas être désinstallée
    dock      = false,
    slot      = 100,

    -- Ces informations sont affichées dans le FruitStore et deviennent une liste
    -- d’autorisation dès qu’au moins une permission est déclarée.
    permissions = {
        'storage', 'contacts', 'photos', 'location', 'notifications',
        'messages', 'calls', 'apps', 'sharing',
    },
    features = {
        'Recherche instantanée',
        'Favoris synchronisés',
        'Notifications en direct',
    },
    keywords = { 'recherche', 'favoris', 'roleplay' },

    -- Restrictions facultatives.
    job      = 'police',
    jobGrade = 2,
    gang     = 'ballas',
}
```

Les identifiants acceptent les lettres, chiffres, `_` et `-`. Le développeur, les
fonctionnalités, mots-clés, accès et version enrichissent automatiquement la présentation
FruitStore. La recherche du store examine aussi ces métadonnées.

Les métadonnées des applications natives sont regroupées dans `Config.AppMetadata`, ce
qui permet à un serveur d’adapter les textes du catalogue sans toucher à l’interface.

## Page minimale

```html
<!doctype html>
<html lang="fr">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="stylesheet" href="../../html/style.css">
  <script src="../../html/sdk.js"></script>
</head>
<body>
  <main id="app"></main>
  <script>
    Phone.ready(function (me) {
      Phone.title('Mon application');
      PhoneUI.render(
        PhoneUI.hero({
          appicon: 'note',
          title: 'Bonjour',
          subtitle: me.deviceName
        })
      );
    });
  </script>
</body>
</html>
```

Le cadre est isolé du téléphone. Il ne peut ni lire son DOM ni usurper l’identifiant
d’une autre application. Le téléphone ajoute lui-même l’identifiant actif aux callbacks
et événements serveur.

## Le mode AppKit recommandé

`Phone.mount()` gère le contexte, l’état, les rendus, les erreurs, le chargement et les
clics `data-action`. Il reste en JavaScript natif.

```js
Phone.mount({
  host: 'app',
  title: 'Tâches',
  state: { tasks: [] },

  async load() {
    return { tasks: await Phone.storage.getJSON('tasks', []) };
  },

  render({ state, ui }) {
    return ui.group(state.tasks.map((task, index) => ui.row({
      title: task.title,
      toggle: task.done,
      data: { action: 'toggle', index }
    }))) + ui.button('Ajouter', 'add');
  },

  actions: {
    toggle: async ({ target, app, state }) => {
      const tasks = state.tasks.slice();
      const index = Number(target.dataset.index);
      tasks[index] = { ...tasks[index], done: !tasks[index].done };
      await Phone.storage.setJSON('tasks', tasks);
      app.setState({ tasks });
    }
  }
});
```

L’objet donné au rendu contient :

- `state` : état courant ;
- `context` : joueur, téléphone, applications et thème ;
- `ui` : tous les composants `PhoneUI` ;
- `busy` : `true` pendant une tâche lancée avec `app.run()`.

Le contrôleur retourné par `Phone.mount()` expose `getState()`, `setState()`, `render()`
et `run()`.

## Composants Clear Glass

Tous les composants échappent leurs textes et suivent automatiquement le mode clair,
sombre, la couleur d’accent et le niveau de transparence du joueur.

```js
const UI = PhoneUI;

UI.hero({ appicon: 'heart', eyebrow: 'Aujourd’hui', value: '82', subtitle: 'Excellent' });
UI.group([UI.row({ title: 'Profil', chevron: true })], { header: 'Compte' });
UI.card('<p>Contenu libre</p>', { title: 'Carte', subtitle: 'Clear Glass' });
UI.grid([
  UI.tile({ icon: 'star', title: 'Favoris', value: '12', data: { action: 'favorites' } }),
  UI.tile({ icon: 'bell', title: 'Alertes', value: '3', data: { action: 'alerts' } })
], { columns: 2 });
UI.tabs([{ id: 'all', label: 'Tout' }, { id: 'saved', label: 'Enregistrés' }], 'all');
UI.search('query', 'Rechercher');
UI.field('name', 'Nom');
UI.textarea('body', 'Votre texte', '', 'maxlength="500"');
UI.progress(64, 100, 'Progression');
UI.chip('En ligne', 'positive');
UI.notice({ icon: 'check', tone: 'success', title: 'Terminé', body: 'Tout est enregistré.' });
UI.spinner('Chargement');
UI.skeleton(4);
UI.empty('Aucun résultat', 'search');
UI.button('Continuer', 'continue', 'tinted');
```

Les styles `bigbtn` disponibles sont `tinted`, `plain` et `destructive`.

## API du téléphone

Toutes les opérations asynchrones retournent une `Promise`.

### Contexte et cycle de vie

```js
Phone.ready((context) => console.log(context.number, context.deviceName));
Phone.context();
Phone.can('photos');

Phone.on('resume', () => reload());
Phone.on('pause', () => saveDraft());
Phone.on('theme', ({ dark }) => updateChart(dark));
Phone.on('launch', (payload) => openDeepLink(payload));
Phone.once('refresh', () => reload());
```

`context` contient le numéro, le nom de l’iFruit, la langue, le thème, le manifeste de
l’application active, ses permissions et la liste des applications installées.

### Barre de navigation

```js
Phone.title('Commandes');
Phone.navigation.action('Ajouter', 'add', () => createOrder());
Phone.navigation.clear();
Phone.close();
```

### Retour utilisateur

```js
Phone.toast('Enregistré');
Phone.notify('Nouvelle commande', 'La commande #42 est prête');
Phone.badge(3);          // 0 retire le badge
Phone.haptic('success'); // light, medium, success, warning, error
```

### Stockage persistant

Le stockage est séparé par application et par personnage. Une petite application n’a
besoin d’aucune table SQL.

```js
await Phone.storage.set('draft', 'Bonjour');
const result = await Phone.storage.get('draft'); // result.value
const all = await Phone.storage.all();           // all.values
await Phone.storage.remove('draft');
await Phone.storage.clear();

await Phone.storage.setJSON('filters', { online: true });
const filters = await Phone.storage.getJSON('filters', { online: false });
```

Une valeur est limitée à 4 000 caractères, une clé à 60 caractères.

### Sélecteurs iFruit

```js
const pickedContact = await Phone.pick.contact();
const pickedPhoto = await Phone.pick.photo();
const contacts = await Phone.contacts();
const photos = await Phone.photos();
```

Les sélecteurs sont des feuilles natives : l’application n’a pas à recréer la galerie ou
la liste des contacts.

### Position et carte

```js
const location = await Phone.location();
await Phone.waypoint(location.x, location.y, 'Rendez-vous');
await Phone.open('maps', location);
```

La position provient directement du ped côté client. Une iframe ne peut pas falsifier la
position renvoyée.

### Appels, messages, partage et ouverture d’apps

```js
await Phone.call('555-0123');
await Phone.message('555-0123', 'Bonjour');
await Phone.open('messages', { number: '555-0123', draft: 'Texte à vérifier' });
await Phone.share({ title: 'Partager', text: 'Mon contenu' });
await Phone.share({ kind: 'photo', url: photoUrl });
```

Le partage propose Messages, copie et AirDrop lorsque le type le permet.

### Feuilles d’actions et confirmation

```js
const choice = await Phone.actions({
  title: 'Trier',
  actions: [
    { id: 'date', label: 'Par date', icon: 'timer' },
    { id: 'name', label: 'Par nom', icon: 'contacts' }
  ]
});

const answer = await Phone.confirm({
  title: 'Supprimer ?',
  message: 'Cette action est définitive.',
  confirmLabel: 'Supprimer',
  destructive: true
});
if (answer.confirmed) removeItem();
```

### Serveur de l’application

Une requête SDK `save` devient automatiquement `<id>:save`. L’iframe ne peut pas appeler
le callback d’une autre ressource.

```js
const result = await Phone.request('save', { title: 'Test' });
Phone.emit('typing', { active: true });
```

Dans `server.lua` :

```lua
V.Callback('mon_app:save', function(src, resolve, data)
    -- Toujours valider data et les droits côté serveur.
    resolve({ ok = true, id = 42 })
end)

RegisterNetEvent('mon_app:typing', function(data)
    local src = source
    -- événement limité à cette application
end)
```

## Application fournie par une autre ressource

Une ressource séparée peut utiliser l’export historique :

```lua
exports['v-phone']:RegisterApp('dispatch', {
    label = 'Dispatch',
    icon = 'shield',
    page = 'https://cfx-nui-ma-resource/html/index.html',
    category = 'duty',
    developer = 'Mon Studio',
    version = '1.0.0',
    permissions = { 'storage', 'location', 'notifications' },
    features = { 'Alertes temps réel', 'Position des unités' },
    optional = true,
    job = 'police',
})
```

À l’arrêt de la ressource :

```lua
exports['v-phone']:UnregisterApp('dispatch')
```

Dans la page HTML de cette ressource, charger le kit avec les URLs NUI absolues :

```html
<link rel="stylesheet" href="https://cfx-nui-v-phone/html/style.css">
<script src="https://cfx-nui-v-phone/html/sdk.js"></script>
```

Le propriétaire est mémorisé automatiquement. Si sa ressource est arrêtée, l’application
n’est pas proposée au joueur.

## Choisir l'écran d'accueil par défaut (administrateurs)

`Config.Apps` est le **catalogue** : tout ce qui existe. `Config.Home` est la
**disposition** : ce qu'un téléphone ouvert pour la première fois contient réellement, et
dans quel ordre. Les deux questions sont séparées, et `Config.Home` gagne toujours sur les
champs `slot`, `dock`, `optional` et `required` du catalogue.

```lua
Config.Home = {
    -- Le dock, de gauche à droite. Toujours installées.
    dock = { 'phone', 'messages', 'contacts', 'settings' },

    -- Installées sur un téléphone neuf, dans cet ordre.
    -- Tout ce qui est dans le catalogue et ABSENT d'ici doit être téléchargé
    -- depuis le FruitStore.
    installed = { 'bank', 'mail', 'maps', 'camera', 'gallery', 'music', 'store' },

    -- Ne peuvent pas être supprimées par le joueur.
    required = { 'phone', 'messages', 'contacts', 'store', 'settings' },

    -- Jamais proposées : ni écran d'accueil, ni magasin, ni recherche.
    hidden = {},
}
```

Trois gestes couvrent presque tous les besoins :

- **Retirer une ligne de `installed`** transforme l'application en téléchargement.
- **Ajouter une ligne à `installed`** la livre avec le téléphone.
- **Ajouter un identifiant à `hidden`** la supprime entièrement sans perdre ses
  traductions ni ses métadonnées de magasin.

Bleeter, Snapmatic, Hush et Cipher sont volontairement absents de `installed` : un compte
sur un réseau social est quelque chose qu'un personnage choisit d'ouvrir, pas quelque
chose que son téléphone contient à la sortie du carton.

L'ordre de `installed` est l'ordre de l'écran d'accueil, après le dock. Un joueur qui
réorganise ses applications remplace cette disposition ; elle n'est que le point de départ.

## Règles de qualité

- Garder la source de vérité dans le module qui possède réellement la donnée.
- Vérifier au serveur l’argent, le métier, la distance et les droits.
- Déclarer les permissions utilisées : elles sont visibles dans le FruitStore.
- Utiliser les sélecteurs, feuilles, toasts et composants du SDK pour rester cohérent.
- Prévoir les états chargement, vide, erreur et hors-ligne.
- Écouter `pause` pour sauvegarder les brouillons et `resume` pour rafraîchir.
- Ne pas faire confiance à une valeur envoyée par l’HTML.
- Tester le tactile, le glissement depuis le bord gauche et le thème sombre.

Le dossier `apps/example` est l’exemple exécutable de toutes les fonctions principales.
