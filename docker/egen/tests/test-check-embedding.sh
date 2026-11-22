#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# EGEN : teste check-embedding.sh contre un VRAI nginx servant les en-têtes produits par le VRAI entrypoint.
# Usage : docker/egen/tests/test-check-embedding.sh   (nécessite bash, curl, envsubst, nginx)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EGEN="$(dirname "$HERE")"
FILES="$(cd "$EGEN/../images/files" && pwd)"
CHECK="$EGEN/check-embedding.sh"
for c in curl envsubst nginx; do command -v "$c" >/dev/null || { echo "$c est requis"; exit 2; }; done

ROOT="$(mktemp -d)"; PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done; rm -rf "$ROOT"; }; trap cleanup EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ok   $1"; }; ko() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

# Génère le fichier d'en-têtes avec le vrai entrypoint (chemins réécrits dans un bac à sable) ; $@ = variables d'env.
gen_headers() {
    local sb; sb="$(mktemp -d -p "$ROOT")"
    mkdir -p "$sb/etc/nginx/overrides/"{main.d,http.d,server.d,assets.d,location.d} "$sb/tmp"
    cp "$FILES/nginx.conf.template" "$sb/tmp/"; cp "$FILES/nginx-resolvers.conf.template" "$sb/tmp/resolvers.conf.template"
    cp "$FILES"/nginx-{admin-console,mcp}-locations.conf.template "$FILES/nginx-security-headers.conf.template" "$sb/tmp/"
    cp "$FILES/nginx-external-locations.conf" "$sb/etc/nginx/overrides/location.d/external-locations.conf"
    sed -e 's#/etc/nginx#@@ETC@@#g' -e 's#/tmp/#@@TMP@@/#g' -e "s#@@ETC@@#$sb/etc/nginx#g" -e "s#@@TMP@@#$sb/tmp#g" "$FILES/nginx-entrypoint.sh" > "$sb/e.sh"
    env -i PATH="$PATH" HOME="$sb" PENPOT_FLAGS=disable-admin-console "$@" bash "$sb/e.sh" true >/dev/null 2>&1
    echo "$sb/etc/nginx/nginx-security-headers.conf"
}

# Démarre nginx sur un port libre avec ces en-têtes ; $1 = fichier d'en-têtes ; $2 = (optionnel) URL de redirection.
serve() {
    local port=$((21000 + RANDOM % 15000)) d; d="$(mktemp -d -p "$ROOT")"; mkdir -p "$d/www" "$d/t"; echo ok > "$d/www/index.html"
    local loc="root $d/www;"; [ -n "${2:-}" ] && loc="return 302 $2;"
    loc="$loc ${3:-}"
    cat > "$d/n.conf" <<NGX
daemon off; pid $d/n.pid; error_log $d/e.log;
events {}
http { access_log off; client_body_temp_path $d/t/b; proxy_temp_path $d/t/p; fastcgi_temp_path $d/t/f; uwsgi_temp_path $d/t/u; scgi_temp_path $d/t/s;
  server { listen 127.0.0.1:$port; $loc include $1; } }
NGX
    nginx -c "$d/n.conf" >/dev/null 2>&1 & PIDS+=($!); sleep 0.7; echo "$port"
}

run_check() { OUT="$(bash "$CHECK" "$@" 2>&1)"; RC=$?; }
expect() { # $1 libellé, $2 code attendu, $3 motif attendu dans la sortie
    if [ $RC -eq "$2" ] && printf '%s' "$OUT" | grep -qE "$3"; then ok "$1"; else ko "$1 (rc=$RC, attendu $2, motif « $3 »)"; echo "$OUT" | sed 's/^/        /'; fi
}

echo "1. Penpot SANS les fichiers du fork (X-Frame-Options) — la panne la plus probable en local"
H="$(gen_headers PENPOT_DUMMY=1)"; P="$(serve "$H")"
run_check "http://127.0.0.1:$P" http://localhost:8080
expect "refus détecté, cause expliquée" 1 "X-Frame-Options: SAMEORIGIN.*REFUSE|Résultat : Penpot ne peut PAS"

echo "2. PENPOT_FRAME_ANCESTORS = l'origine exacte du Core"
H="$(gen_headers PENPOT_FRAME_ANCESTORS='http://localhost:8080')"; P="$(serve "$H")"
run_check "http://127.0.0.1:$P" http://localhost:8080
expect "embarquement autorisé" 0 "frame-ancestors autorise http://localhost:8080"

echo "3. PENPOT_FRAME_ANCESTORS = une AUTRE origine (127.0.0.1 au lieu de localhost)"
H="$(gen_headers PENPOT_FRAME_ANCESTORS='http://127.0.0.1:8080')"; P="$(serve "$H")"
run_check "http://127.0.0.1:$P" http://localhost:8080
expect "refus détecté avec la liste des origines autorisées" 1 "n'autorise PAS http://localhost:8080 \(autorisés : 'self' http://127.0.0.1:8080\)|n'autorise PAS http://localhost:8080"
printf '%s' "$OUT" | grep -q "localhost ≠ 127.0.0.1" && ok "le piège localhost ≠ 127.0.0.1 est signalé" || ko "piège localhost/127.0.0.1 non signalé"

echo "4. joker de sous-domaine et plusieurs origines"
H="$(gen_headers PENPOT_FRAME_ANCESTORS='https://x.example.org https://*.example.org')"; P="$(serve "$H")"
run_check "http://127.0.0.1:$P" https://core.example.org
expect "https://*.example.org autorise https://core.example.org" 0 "autorise https://core.example.org"
run_check "http://127.0.0.1:$P" https://core.autre.org
expect "…mais pas https://core.autre.org" 1 "n'autorise PAS"
run_check "http://127.0.0.1:$P" http://core.example.org
expect "…ni http://core.example.org (schéma différent)" 1 "n'autorise PAS"

echo "5. Penpot injoignable (rien n'écoute) et arguments invalides"
run_check "http://127.0.0.1:1" http://localhost:8080
expect "connexion refusée expliquée" 2 "connexion refusée"
run_check "http://127.0.0.1:$P" http://localhost:8080/
expect "origine du Core avec « / » final refusée" 2 "origine du Core invalide"
run_check
expect "sans argument : aide" 2 "Usage"

echo "6. Redirection vers une autre origine"
H="$(gen_headers PENPOT_FRAME_ANCESTORS='http://localhost:8080')"; DEST="$(serve "$H")"; SRC="$(serve "$H" "http://127.0.0.1:$DEST/")"
run_check "http://127.0.0.1:$SRC" http://localhost:8080
expect "redirection signalée, verdict sur la destination" 0 "redirige vers http://127.0.0.1:$DEST"

echo "7. Backend de Penpot arrêté (le frontend répond, /api en 502) — le cas des logs de l'utilisateur"
H="$(gen_headers PENPOT_FRAME_ANCESTORS='http://localhost:8080')"; P="$(serve "$H" "" "location /api/ { return 502; }")"
run_check "http://127.0.0.1:$P" http://localhost:8080
expect "embarquement OK mais backend en panne signalé (code 1)" 1 "BACKEND de Penpot ne répond pas \(HTTP 502.*password authentication failed|MAIS le backend"
printf '%s' "$OUT" | grep -q "autorise http://localhost:8080" && ok "…l'embarquement, lui, est bien reconnu comme autorisé" || ko "embarquement non reconnu"
H="$(gen_headers PENPOT_FRAME_ANCESTORS='http://localhost:8080')"; P="$(serve "$H" "" "location /api/ { return 200 '{}'; }")"
run_check "http://127.0.0.1:$P" http://localhost:8080
expect "backend qui répond : tout est vert" 0 "le backend de Penpot répond \(HTTP 200\)"

echo "8. Le Core ouvert sur 0.0.0.0 (le cas des logs de l'utilisateur)"
H="$(gen_headers PENPOT_FRAME_ANCESTORS='http://localhost:8080 http://127.0.0.1:8080')"; P="$(serve "$H")"
run_check "http://127.0.0.1:$P" http://0.0.0.0:8080
expect "0.0.0.0 non autorisé et expliqué" 1 "n'autorise PAS http://0.0.0.0:8080"
printf '%s' "$OUT" | grep -q "0.0.0.0 n'est pas une adresse de navigation" && ok "l'avertissement 0.0.0.0 est affiché" || ko "avertissement 0.0.0.0 absent"
H="$(gen_headers PENPOT_FRAME_ANCESTORS='http://localhost:8080 http://0.0.0.0:8080')"; P="$(serve "$H")"
run_check "http://127.0.0.1:$P" http://0.0.0.0:8080
expect "0.0.0.0 autorisé explicitement : accepté" 0 "autorise http://0.0.0.0:8080"

echo; echo "Résultat : $PASS ok, $FAIL échec(s)"; [ "$FAIL" -eq 0 ]
