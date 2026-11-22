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
| `integrations/egen/esm-penpot-app/` | paquet d'application externe pour le Core (`@civitas/esm-penpot-app`) |
| `.github/workflows/egen-penpot-app.yml` | construit le paquet et l'attache à une release |

Sans `PENPOT_FRAME_ANCESTORS`, le comportement est **exactement** celui d'upstream. Aucun code de l'application
(backend Clojure, frontend ClojureScript, exporter) n'est modifié. Licence : MPL-2.0, comme upstream.

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
2. `integrations/egen/esm-penpot-app/README.md` : intégrer l'application au Core.
