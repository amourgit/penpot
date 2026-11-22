# @civitas/esm-penpot-app

Application **externe** d'EGEN qui affiche une instance [Penpot](https://penpot.app) dans la zone principale du Core
(route `penpot`), avec une option dans le rail gauche. C'est une enveloppe d'une centaine de lignes : Penpot reste une
application autonome, déployée à son adresse (`docker/egen/`), et embarquée par `iframe` via
[`@egen-civitas/esm-nextjs-utils`](https://www.npmjs.com/package/@egen-civitas/esm-nextjs-utils).

C'est le scénario **C3** du document `docs/integration-apps/15-scenarios-integration-externe.md` du Core.

## Ce que fait l'enveloppe

- lit sa configuration au montage (`penpotUrl`, `title`, `heightOffset`) et la **valide** : https obligatoire
  (http toléré pour `localhost`), pas d'identifiants dans l'URL ; sinon une alerte lisible remplace l'iframe ;
- délègue l'embarquement à `getEmbedLifecycle` : origine **explicite** (jamais `*`), bac à sable, messages vérifiés ;
- ne transmet **aucune donnée de session** à Penpot (`sessionFields: []`) : Penpot a sa propre authentification ;
- ajoute ce dont Penpot a besoin : droits de bac à sable (téléchargements, dialogues), permissions presse-papiers
  (`allow="clipboard-read; clipboard-write; fullscreen"`), hauteur = espace visible (Penpot occupe toute la fenêtre
  et n'annonce pas sa hauteur).

## Configuration (par instance de Core, sans reconstruire)

Dans la configuration du Core :

```json
{ "@civitas/esm-penpot-app": { "penpotUrl": "https://design.exemple.org", "title": "Penpot", "heightOffset": 0 } }
```

| Clé | Défaut | Rôle |
| --- | --- | --- |
| `penpotUrl` | _(obligatoire)_ | URL publique de l'instance Penpot |
| `title` | `Penpot` | titre accessible de l'iframe |
| `heightOffset` | `0` | pixels à laisser libres sous l'iframe (ex. pied de page fixe) |

## Développer, tester, construire

```bash
npm install --legacy-peer-deps
npm test          # 24 tests (configuration, bac à sable, hauteur, démontage, erreurs)
npx tsc           # types
npm run build     # dist/civitas-esm-penpot-app.js + dist/routes.json estampillé
npm run pack:tarball   # civitas-esm-penpot-app-<version>.tgz
```

## L'intégrer à un Core

1. Déployer Penpot (`docker/egen/README.md`) avec `PENPOT_FRAME_ANCESTORS` = origine du Core.
2. Diffuser le paquet : le workflow `.github/workflows/egen-penpot-app.yml` attache le tarball à une release GitHub
   (tag `egen-app-v<version>`), ou publier sur un registre npm.
3. Dans le Core, `external-apps.json` :
   ```json
   { "apps": { "@civitas/esm-penpot-app": "https://github.com/amourgit/penpot/releases/download/egen-app-v1.0.0/civitas-esm-penpot-app-1.0.0.tgz" } }
   ```
4. **À froid** : sur la machine ou dans l'étape de build du Core, `yarn external:sync --strict` (télécharge, valide,
   écrit le verrou), puis `node tools/precompress.mjs`, puis **redémarrer** le Core (`yarn start:prod`) ou le redéployer.
   Le Core lit le verrou au démarrage et revérifie l'empreinte SHA-256 du bundle.
5. Renseigner `penpotUrl` dans la configuration du Core.
