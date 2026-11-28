#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# EGEN: tests of the integration declaration /egen-config.json (nginx-entrypoint.sh +
# egen-config.json.template + the `location = /egen-config.json` block of nginx.conf.template).
#
# Runs the REAL entrypoint against a sandbox (every absolute /etc/nginx and /tmp path is rewritten
# into a temporary directory). Needs bash and envsubst (gettext). When nginx and curl are installed,
# the real location block is also served and checked over HTTP. When node is installed, the rendered
# declaration is parsed as JSON and its invariants are checked.
#
# Usage: docker/images/files/tests/test-egen-config.sh

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES="$(dirname "$HERE")"
command -v envsubst >/dev/null || { echo "envsubst (gettext) is required" >&2; exit 2; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
ko() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

# Prepare a sandbox (SB) and run the entrypoint in it (RC = exit code). Reuses $SB when KEEP=1.
run_entrypoint() {
    if [ "${KEEP:-0}" != 1 ]; then
        SB="$(mktemp -d -p "$ROOT")"
        mkdir -p "$SB/etc/nginx/overrides/"{main.d,http.d,server.d,assets.d,location.d} "$SB/tmp"
        for f in nginx.conf.template:nginx.conf.template nginx-resolvers.conf.template:resolvers.conf.template \
                 nginx-admin-console-locations.conf.template:nginx-admin-console-locations.conf.template \
                 nginx-mcp-locations.conf.template:nginx-mcp-locations.conf.template \
                 nginx-security-headers.conf.template:nginx-security-headers.conf.template \
                 egen-config.json.template:egen-config.json.template; do
            cp "$FILES/${f%%:*}" "$SB/tmp/${f##*:}"
        done
        cp "$FILES/nginx-external-locations.conf" "$SB/etc/nginx/overrides/location.d/external-locations.conf"
        sed -e 's#/etc/nginx#@@ETC@@#g' -e 's#/tmp/#@@TMP@@/#g' \
            -e "s#@@ETC@@#$SB/etc/nginx#g" -e "s#@@TMP@@#$SB/tmp#g" "$FILES/nginx-entrypoint.sh" > "$SB/entrypoint.sh"
    fi
    env -i PATH="$PATH" HOME="$SB" PENPOT_FLAGS="disable-admin-console" "$@" bash "$SB/entrypoint.sh" true >"$SB/out.log" 2>"$SB/err.log"
    RC=$?
    DECL="$SB/etc/nginx/egen-config.json"
}

published() { [ -f "$DECL" ]; }
field() { node -e 'const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=process.argv[2].split(".").reduce((o,k)=>o?.[k],m);console.log(typeof v==="object"?JSON.stringify(v):v)' "$DECL" "$1"; }

echo "1. non publié sans PENPOT_FRAME_ANCESTORS (comportement upstream)"
run_entrypoint PENPOT_PUBLIC_URI="https://design.example.org"
[ $RC -eq 0 ] && ok "entrypoint terminé (rc=0)" || ko "rc=$RC : $(cat "$SB/err.log")"
published && ko "déclaration publiée à tort" || ok "aucune déclaration"

echo "2. non publié sans PENPOT_PUBLIC_URI valide, sans bloquer le démarrage"
for bad in "" "http://evil.example.org" "https://a.org/path" "https://a.org?x=1" "https://user@a.org" "ftp://a.org" "design.example.org" "https://a.org;x" "http://localhost.evil.org"; do
    run_entrypoint PENPOT_FRAME_ANCESTORS="https://core.example.org" PENPOT_PUBLIC_URI="$bad"
    if [ $RC -eq 0 ] && ! published; then ok "ignoré, démarrage OK : '${bad}'"; else ko "publiée ou rc=$RC : '${bad}'"; fi
done
run_entrypoint PENPOT_FRAME_ANCESTORS="https://core.example.org" PENPOT_PUBLIC_URI="https://a.org/path"
grep -q "egen-config.json not published" "$SB/err.log" && ok "avertissement explicite" || ko "pas d'avertissement"

echo "3. publié : https, slash final retiré, port, localhost"
for pair in "https://design.example.org|https://design.example.org" "https://design.example.org/|https://design.example.org" \
            "https://design.example.org:8443|https://design.example.org:8443" "http://localhost:9001|http://localhost:9001" \
            "http://127.0.0.1:9001/|http://127.0.0.1:9001"; do
    in="${pair%%|*}"; want="${pair##*|}"
    run_entrypoint PENPOT_FRAME_ANCESTORS="https://core.example.org" PENPOT_PUBLIC_URI="$in"
    if [ $RC -eq 0 ] && published && grep -qF "\"url\": \"$want\"," "$DECL"; then ok "$in → url $want"; else ko "$in (rc=$RC)"; fi
    grep -q '__PENPOT_PUBLIC_URL__' "$DECL" 2>/dev/null && ko "marqueur non remplacé"
done

echo "4. contenu de la déclaration"
run_entrypoint PENPOT_FRAME_ANCESTORS="https://core.example.org" PENPOT_PUBLIC_URI="https://design.example.org"
if command -v node >/dev/null; then
    [ "$(field manifestVersion)" = "1" ] && ok "manifestVersion 1" || ko "manifestVersion"
    [ "$(field name)" = "@civitas/esm-penpot-app" ] && ok "name" || ko "name"
    [ "$(field route)" = "penpot" ] && ok "route penpot" || ko "route"
    [ "$(field technology)" = "other" ] && ok "technology other" || ko "technology"
    [ "$(field navigation.mode)" = "none" ] && ok "navigation none (Penpot est une SPA qui ne parle pas au Core)" || ko "navigation"
    [ "$(field capabilities)" = "{}" ] && ok "aucune capacité demandée (pas de client EGEN dans Penpot)" || ko "capabilities"
    [ "$(field placement.rail)" = "left" ] && [ "$(field placement.group)" = "Conception" ] && ok "placement rail gauche, groupe Conception" || ko "placement"
    [ "$(field iframe.sandbox)" = '["allow-downloads","allow-modals","allow-popups-to-escape-sandbox"]' ] && ok "iframe.sandbox" || ko "iframe.sandbox"
    [ "$(field iframe.allow)" = '["clipboard-read","clipboard-write","fullscreen"]' ] && ok "iframe.allow" || ko "iframe.allow"
else
    echo "  (ignoré : node non installé)"
fi

echo "5. redémarrage : jamais de déclaration périmée"
run_entrypoint PENPOT_FRAME_ANCESTORS="https://core.example.org" PENPOT_PUBLIC_URI="https://design.example.org"
published && ok "publiée au premier démarrage" || ko "non publiée"
KEEP=1 run_entrypoint PENPOT_PUBLIC_URI="https://design.example.org"
published && ko "déclaration périmée conservée (PENPOT_FRAME_ANCESTORS retiré)" || ok "retirée quand l'embarquement est désactivé"
KEEP=1 run_entrypoint PENPOT_FRAME_ANCESTORS="https://core.example.org" PENPOT_PUBLIC_URI="https://autre.example.org"
grep -qF '"url": "https://autre.example.org",' "$DECL" && ok "régénérée avec la nouvelle URL" || ko "URL non mise à jour"

if command -v nginx >/dev/null && command -v curl >/dev/null; then
    echo "6. nginx réel : le bloc de nginx.conf.template, servi en HTTP"
    PORT=$((20000 + RANDOM % 20000))
    BLOCK="$(awk '/location = \/egen-config\.json \{/{f=1} f{print} f&&/^            }/{exit}' "$FILES/nginx.conf.template")"
    [ -n "$BLOCK" ] && ok "bloc location présent dans le template" || ko "bloc location introuvable"
    serve() { # $1 = 0|1 : déclaration publiée ?
        run_entrypoint PENPOT_FRAME_ANCESTORS="https://core.example.org" $([ "$1" = 1 ] && echo PENPOT_PUBLIC_URI=https://design.example.org)
        mkdir -p "$ROOT/www" "$ROOT/ngx"; echo '<!doctype html>spa' > "$ROOT/www/index.html"
        cat > "$ROOT/ngx/nginx.conf" <<NGX
user root; daemon off; pid $ROOT/ngx/nginx.pid; error_log $ROOT/ngx/error.log;
events {}
http { access_log off; client_body_temp_path $ROOT/ngx/b; proxy_temp_path $ROOT/ngx/p; fastcgi_temp_path $ROOT/ngx/f; uwsgi_temp_path $ROOT/ngx/u; scgi_temp_path $ROOT/ngx/s;
  server { listen 127.0.0.1:$PORT; root $ROOT/www;
    location / {
$(printf '%s\n' "$BLOCK" | sed "s#/etc/nginx#$SB/etc/nginx#g")
      try_files \$uri /index.html =404;
    } } }
NGX
        nginx -c "$ROOT/ngx/nginx.conf" >/dev/null 2>&1 & NPID=$!
        sleep 1
    }
    stop() { kill "$NPID" 2>/dev/null; wait "$NPID" 2>/dev/null; }

    serve 1
    H="$(curl -s -D - -o "$ROOT/body.json" "http://127.0.0.1:$PORT/egen-config.json")"
    stop
    echo "$H" | head -1 | grep -q " 200" && ok "HTTP 200" || ko "HTTP : $(echo "$H" | head -1)"
    echo "$H" | grep -qi '^content-type: application/json' && ok "Content-Type application/json" || ko "Content-Type"
    echo "$H" | grep -qi '^cache-control: no-store' && ok "jamais en cache (le Core fige son SHA-256)" || ko "Cache-Control"
    echo "$H" | grep -qi '^access-control-allow-origin: \*' && ok "CORS ouvert (lecture seule, publique)" || ko "CORS"
    echo "$H" | grep -qi '^x-content-type-options: nosniff' && ok "en-têtes de sécurité conservés" || ko "en-têtes de sécurité perdus"
    cmp -s "$ROOT/body.json" "$DECL" && ok "corps = fichier généré, octet pour octet" || ko "corps différent"

    serve 0
    CODE="$(curl -s -o "$ROOT/body.out" -w '%{http_code}' "http://127.0.0.1:$PORT/egen-config.json")"
    stop
    [ "$CODE" = "404" ] && ok "non publiée : 404 (jamais le repli SPA)" || ko "non publiée : HTTP $CODE"
    grep -q 'spa' "$ROOT/body.out" && ko "le repli SPA a répondu" || ok "aucun HTML renvoyé"
else
    echo "6. (ignoré : nginx/curl non installés)"
fi

echo
echo "Résultat : $PASS ok, $FAIL échec(s)"
[ "$FAIL" -eq 0 ]
