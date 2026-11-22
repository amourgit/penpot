# Déployer Penpot pour EGEN

Penpot (version **2.19.3**) à déployer à une adresse propre, pour être embarqué dans le Core par
`integrations/egen/esm-penpot-app`. On utilise les **images officielles** `penpotapp/*` ; ce fork n'ajoute que
`PENPOT_FRAME_ANCESTORS` (embarquement en iframe), apporté par deux fichiers nginx montés dans l'image frontend.
Détail du pourquoi : `docs/technical-guide/configuration.md` (section « Embedding Penpot in another application »).

## Avant de commencer

- Docker + Docker Compose v2 ; un nom de domaine pour Penpot, **sous-domaine du même site que le Core**
  (`design.exemple.org` à côté de `core.exemple.org`) : le cookie de session fonctionne alors normalement dans l'iframe.
  Autre site : voir « Cas d'un autre site » plus bas.
- Un reverse proxy TLS devant `PENPOT_BIND` (`127.0.0.1:9001` par défaut) ; il doit laisser passer les WebSocket
  (en-têtes `Upgrade`/`Connection`) et accepter de gros corps de requête (imports : 350 Mo).

## Installation

```bash
cd docker/egen
cp .env.example .env
# Renseigner dans .env : PENPOT_PUBLIC_URI, PENPOT_FRAME_ANCESTORS (origine du Core), POSTGRES_PASSWORD,
# PENPOT_SECRET_KEY (openssl rand -base64 64). En HTTPS, retirer `disable-secure-session-cookies` de PENPOT_FLAGS.
docker compose up -d
docker compose exec penpot-backend python3 manage.py create-profile    # premier utilisateur
```

Le démarrage **échoue avec un message explicite** si `PENPOT_PUBLIC_URI`, `PENPOT_FRAME_ANCESTORS`, `PENPOT_SECRET_KEY`
ou `POSTGRES_PASSWORD` manque. Courrier : renseigner `PENPOT_SMTP_*` (ou `docker compose --profile dev up -d` pour un
Mailpit local).

## Essai en local (Core sur `http://localhost:8080`)

```bash
cd docker/egen
cp .env.local.example .env        # valeurs d'essai : origines du Core déjà renseignées
docker compose up -d
docker compose exec penpot-backend python3 manage.py create-profile
```

Penpot est alors sur `http://localhost:9001`. Côté Core : `"penpotUrl": "http://localhost:9001"`.
`localhost` des deux côtés est le même *site* (le port ne compte pas) : la session fonctionne dans l'iframe.
Ce sont en revanche deux *origines* : `PENPOT_FRAME_ANCESTORS` doit contenir l'origine **exacte** du Core, telle
qu'elle s'affiche dans la barre d'adresse (`http://localhost:8080` ≠ `http://127.0.0.1:8080`).

## Vérifier l'embarquement

```bash
curl -sI https://design.exemple.org/ | grep -iE "x-frame-options|content-security-policy"
```

Attendu : **pas** de `X-Frame-Options`, et un `Content-Security-Policy: frame-ancestors 'self' https://core.exemple.org`.
Si `X-Frame-Options: SAMEORIGIN` apparaît encore, les fichiers montés ne sont pas pris en compte (chemins, ou image
d'une autre version).

## Diagnostic : l'iframe est vide, ou « localhost n'autorise pas la connexion »

Ce message du navigateur est celui d'une iframe **refusée par Penpot**. Un script interroge Penpot comme le fait le
navigateur et dit précisément pourquoi :

```bash
docker/egen/check-embedding.sh http://localhost:9001 http://localhost:8080
#                              └─ adresse de Penpot   └─ origine du Core (barre d'adresse)
```

Il distingue : Penpot qui ne tourne pas (connexion refusée), `X-Frame-Options` encore présent (Penpot lancé **sans** les
fichiers de ce fork, ou `PENPOT_FRAME_ANCESTORS` absent), une origine du Core non autorisée (`localhost` ≠ `127.0.0.1`,
`http` ≠ `https`, port), une redirection vers une autre adresse. Il se teste lui-même :
`bash docker/egen/tests/test-check-embedding.sh`.

## Cas d'un autre site que le Core

Ajouter `enable-cors` à `PENPOT_FLAGS` (cookie `SameSite=None`) et garder `secure-session-cookies` (HTTPS obligatoire).
Les navigateurs qui bloquent les cookies tiers peuvent malgré tout empêcher la connexion dans l'iframe : préférer un
sous-domaine du même site.

## Mettre à jour

Les deux fichiers montés doivent correspondre à la version des images :

1. `git fetch upstream --tags` puis `git rebase <nouveau-tag> egen` (résoudre les conflits éventuels dans
   `docker/images/files/nginx-entrypoint.sh` et `nginx-security-headers.conf.template`) ;
2. `bash docker/images/files/tests/test-frame-ancestors.sh` (doit afficher 0 échec) ;
3. `PENPOT_VERSION=<nouveau-tag>` dans `.env`, puis `docker compose pull && docker compose up -d`.

## Sauvegarde

Volumes `penpot_postgres_v15` (base) et `penpot_assets` (fichiers) : à sauvegarder ensemble.
