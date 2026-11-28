# Fork EGEN de Penpot

Ce dépôt est un fork de [penpot/penpot](https://github.com/penpot/penpot), maintenu par CIVITAS pour être utilisé
comme **application externe du Core EGEN**. La branche `egen` part du tag stable **2.19.3** ; `develop` et `main`
restent alignées sur l'amont.

## Ce qui diffère d'upstream

| Chemin | Changement |
| --- | --- |
| `docker/images/files/nginx-entrypoint.sh` | `PENPOT_FRAME_ANCESTORS` : embarquement en iframe, opt-in, origines validées |
| `docker/images/files/nginx-security-headers.conf.template` | `X-Frame-Options` devient dynamique (`${PENPOT_FRAME_DIRECTIVE}`) |
| `docker/images/files/tests/test-frame-ancestors.sh` | 24 vérifications (entrypoint réel en bac à sable + nginx réel) |
| `docs/technical-guide/configuration.md` | section « Embedding Penpot in another application » |
| `docker/egen/` | déploiement : compose sur images officielles épinglées, `.env.example`, guide |
| `docker/egen/check-embedding.sh` | diagnostic de l'embarquement (+ `tests/test-check-embedding.sh`, 11 vérifications) ; `.env.local.example` : essai local |
| `docker/images/files/egen-config.json.template`, `nginx-entrypoint.sh`, `nginx.conf.template` | déclaration d'intégration pour le Core : `/egen-config.json` publié au démarrage (`PENPOT_FRAME_ANCESTORS` + `PENPOT_PUBLIC_URI`), 404 sinon |
| `docker/images/files/tests/test-egen-config.sh` | 38 vérifications (entrypoint réel en bac à sable + nginx réel) |
| `frontend/src/app/main/ui/dashboard*.{cljs,scss}`, `frontend/resources/styles/common/refactor/{basic-rules,common-dashboard}.scss`, `settings/{delete_account,change_email}.scss` | dashboard responsive (tiroir mobile, modales bornées à la largeur de l'écran) pour l'affichage en iframe |
| `docker/egen/Dockerfile.frontend-full`, `docker/egen/update-frontend.sh` | image frontend = image officielle + bundle compilé du fork ; mise à jour en une commande |

Sans `PENPOT_FRAME_ANCESTORS`, le comportement est **exactement** celui d'upstream. Le backend Clojure et l'exporter ne sont pas modifiés ; seul le frontend (dashboard) l'est, pour le responsive. Licence : MPL-2.0, comme upstream.

## Rester à jour avec l'amont

```bash
git remote add upstream https://github.com/penpot/penpot.git    # une seule fois
git fetch upstream --tags
git checkout egen && git rebase <nouveau-tag-stable>
bash docker/images/files/tests/test-frame-ancestors.sh
```

Puis suivre `docker/egen/README.md` (« Mettre à jour »).

## Par où commencer

1. `docker/egen/README.md` : déployer Penpot.
2. Core : une entrée `embed` dans `external-apps.json` (`"manifest": "<PENPOT_PUBLIC_URI>/egen-config.json"`) puis `yarn external:sync` — `docs/integration-apps/17 §7` du Core. Penpot n'embarque pas de client EGEN : la déclaration ne demande aucune capacité, le Core reste en protocole 1.1.
