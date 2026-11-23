#!/usr/bin/env bash
# Met à jour le frontend Penpot : image officielle + bundle compilé du fork (option B).
# Part du DERNIER COMMIT de la branche courante, construit dans un clone sans espace dans le chemin.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="${PENPOT_BUILD_DIR:-$HOME/penpot-build}"
COMPOSE_DIR="$REPO/docker/egen"
PV=$(grep -E '^PENPOT_VERSION=' "$COMPOSE_DIR/.env" 2>/dev/null | cut -d= -f2 || true)
PV=${PV:-2.19.3}
IMG="egen-penpot-frontend"

case "$BUILD" in *" "*) echo "ERREUR : PENPOT_BUILD_DIR ne doit pas contenir d'espace ($BUILD)"; exit 1;; esac

if [ -n "$(git -C "$REPO" status --porcelain --untracked-files=no)" ]; then
  echo "ERREUR : modifications non commitées dans $REPO. Commit d'abord (le build part du dernier commit)."
  exit 1
fi

BRANCH="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
echo ">> Branche : $BRANCH | Penpot $PV | build dans $BUILD"

[ -d "$BUILD/.git" ] || git clone --branch "$BRANCH" "$REPO" "$BUILD"
git -C "$BUILD" fetch --tags --force "$REPO" "$BRANCH"
git -C "$BUILD" checkout -f -B "$BRANCH" FETCH_HEAD
echo ">> Commit : $(git -C "$BUILD" log -1 --oneline)"

cd "$BUILD"
./manage.sh build-frontend-bundle
mkdir -p docker/images/bundle-frontend
rsync -a --delete ./bundles/frontend/ ./docker/images/bundle-frontend/

docker build -t "$IMG:$PV-new" \
  -f docker/egen/Dockerfile.frontend-full \
  --build-arg PENPOT_VERSION="$PV" \
  docker/images

# Le build a réussi : sauvegarde de l'image actuelle, puis bascule.
if docker image inspect "$IMG:$PV" >/dev/null 2>&1; then
  docker tag "$IMG:$PV" "$IMG:previous"
fi
docker tag "$IMG:$PV-new" "$IMG:$PV"
docker rmi "$IMG:$PV-new" >/dev/null

cd "$COMPOSE_DIR"
docker compose up -d --no-build --no-deps --force-recreate penpot-frontend
docker compose ps penpot-frontend
docker image prune -f >/dev/null

echo ">> OK. Ctrl+Maj+R dans le Core. Retour arrière : docker/egen/update-frontend.sh --rollback"
