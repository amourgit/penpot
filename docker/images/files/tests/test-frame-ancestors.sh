#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# EGEN: tests of PENPOT_FRAME_ANCESTORS in nginx-entrypoint.sh.
#
# Runs the REAL entrypoint against a sandbox: every absolute /etc/nginx and
# /tmp path is rewritten into a temporary directory, so it is safe to run
# anywhere. Needs bash and envsubst (gettext). When nginx is installed, the
# generated header file is also served by a real nginx and checked over HTTP.
#
# Usage: docker/images/files/tests/test-frame-ancestors.sh

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES="$(dirname "$HERE")"
command -v envsubst >/dev/null || { echo "envsubst (gettext) is required" >&2; exit 2; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
ko()   { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

# Run the entrypoint in a fresh sandbox; sets SB (sandbox dir) and RC (exit code).
run_entrypoint() {
    SB="$(mktemp -d -p "$ROOT")"
    mkdir -p "$SB/etc/nginx/overrides/"{main.d,http.d,server.d,assets.d,location.d} "$SB/tmp"
    cp "$FILES/nginx.conf.template"                        "$SB/tmp/nginx.conf.template"
    cp "$FILES/nginx-resolvers.conf.template"              "$SB/tmp/resolvers.conf.template"
    cp "$FILES/nginx-admin-console-locations.conf.template" "$SB/tmp/nginx-admin-console-locations.conf.template"
    cp "$FILES/nginx-mcp-locations.conf.template"          "$SB/tmp/nginx-mcp-locations.conf.template"
    cp "$FILES/nginx-security-headers.conf.template"       "$SB/tmp/nginx-security-headers.conf.template"
    cp "$FILES/nginx-external-locations.conf"              "$SB/etc/nginx/overrides/location.d/external-locations.conf"
    # One pass through placeholders: the sandbox itself may live under /tmp.
    sed -e 's#/etc/nginx#@@ETC@@#g' -e 's#/tmp/#@@TMP@@/#g' \
        -e "s#@@ETC@@#$SB/etc/nginx#g" -e "s#@@TMP@@#$SB/tmp#g" "$FILES/nginx-entrypoint.sh" > "$SB/entrypoint.sh"
    env -i PATH="$PATH" HOME="$SB" PENPOT_FLAGS="${FLAGS:-disable-admin-console}" \
        "$@" bash "$SB/entrypoint.sh" true >"$SB/out.log" 2>"$SB/err.log"
    RC=$?
    HEADERS="$SB/etc/nginx/nginx-security-headers.conf"
}

has()  { grep -qF -- "$1" "$HEADERS"; }

echo "1. sans PENPOT_FRAME_ANCESTORS : comportement upstream inchangé"
run_entrypoint PENPOT_DUMMY=1
[ $RC -eq 0 ]                                   && ok "entrypoint terminé (rc=0)"            || ko "rc=$RC : $(cat "$SB/err.log")"
has 'add_header X-Frame-Options SAMEORIGIN always;' && ok "X-Frame-Options SAMEORIGIN conservé"   || ko "X-Frame-Options absent"
has "frame-ancestors 'self' \""                  && ko "en-tête frame-ancestors imposé inattendu" || ok "aucun en-tête frame-ancestors imposé"
has "frame-ancestors 'self'; form-action"        && ok "politique par défaut : frame-ancestors 'self'" || ko "politique par défaut modifiée"

echo "2. une origine, CSP en report-only (défaut)"
run_entrypoint PENPOT_FRAME_ANCESTORS="https://core.example.org"
[ $RC -eq 0 ]                                    && ok "entrypoint terminé (rc=0)"            || ko "rc=$RC : $(cat "$SB/err.log")"
has 'X-Frame-Options'                            && ko "X-Frame-Options encore envoyé"        || ok "X-Frame-Options retiré"
has 'add_header Content-Security-Policy "frame-ancestors '"'self' https://core.example.org"'" always;' \
                                                 && ok "frame-ancestors IMPOSÉ (même en report-only)" || ko "frame-ancestors non imposé"
has 'Content-Security-Policy-Report-Only'        && ok "CSP report-only conservée"            || ko "CSP report-only absente"
has "frame-ancestors 'self' https://core.example.org; form-action" && ok "politique par défaut alignée" || ko "politique par défaut non alignée"

echo "3. plusieurs origines, joker de sous-domaine, port, CSP enforce"
run_entrypoint PENPOT_CSP_MODE=enforce PENPOT_FRAME_ANCESTORS="  https://core.example.org   https://*.example.org	http://localhost:3000 "
[ $RC -eq 0 ]                                    && ok "entrypoint terminé (rc=0)"            || ko "rc=$RC : $(cat "$SB/err.log")"
has "frame-ancestors 'self' https://core.example.org https://*.example.org http://localhost:3000\" always;" \
                                                 && ok "liste normalisée (espaces/tabulations)" || ko "liste mal normalisée"
[ "$(grep -c 'add_header Content-Security-Policy ' "$HEADERS")" -eq 2 ] && ok "enforce : deux CSP cohérentes (intersection = la liste)" || ko "nombre d'en-têtes CSP inattendu"

echo "4. entrées invalides refusées (exit 1, aucune ouverture silencieuse)"
for bad in "*" "https://a.org;script-src *" "'none'" "ftp://a.org" "https://a.org/path" "core.example.org" "https://*" "https://a.org https://b.org*"; do
    run_entrypoint PENPOT_FRAME_ANCESTORS="$bad"
    if [ $RC -eq 1 ] && grep -q "invalid PENPOT_FRAME_ANCESTORS" "$SB/err.log"; then ok "refusé : $bad"; else ko "accepté à tort : $bad (rc=$RC)"; fi
done

echo "5. politique CSP personnalisée : frame-ancestors reste du ressort du déployeur"
run_entrypoint PENPOT_CSP_POLICY="default-src 'self'; frame-ancestors https://own.example.org" PENPOT_FRAME_ANCESTORS="https://core.example.org"
[ $RC -eq 0 ] && has "default-src 'self'; frame-ancestors https://own.example.org" && ok "politique personnalisée non réécrite" || ko "politique personnalisée altérée"

if command -v nginx >/dev/null && command -v curl >/dev/null; then
    echo "6. nginx réel : en-têtes HTTP effectivement envoyés"
    run_entrypoint PENPOT_FRAME_ANCESTORS="https://core.example.org"
    PORT=$((20000 + RANDOM % 20000))
    mkdir -p "$ROOT/www" "$ROOT/ngx"; echo ok > "$ROOT/www/index.html"
    cat > "$ROOT/ngx/nginx.conf" <<NGX
daemon off; pid $ROOT/ngx/nginx.pid; error_log $ROOT/ngx/error.log;
events {}
http { access_log off; client_body_temp_path $ROOT/ngx/b; proxy_temp_path $ROOT/ngx/p; fastcgi_temp_path $ROOT/ngx/f; uwsgi_temp_path $ROOT/ngx/u; scgi_temp_path $ROOT/ngx/s;
  server { listen 127.0.0.1:$PORT; root $ROOT/www; include $HEADERS; } }
NGX
    nginx -c "$ROOT/ngx/nginx.conf" >/dev/null 2>&1 & NPID=$!
    sleep 1
    H="$(curl -s -D - -o /dev/null "http://127.0.0.1:$PORT/")"
    kill "$NPID" 2>/dev/null; wait "$NPID" 2>/dev/null
    echo "$H" | grep -qi '^content-security-policy: frame-ancestors '"'self' https://core.example.org" && ok "HTTP : frame-ancestors 'self' https://core.example.org" || ko "HTTP : frame-ancestors absent"
    echo "$H" | grep -qi '^x-frame-options' && ko "HTTP : X-Frame-Options présent" || ok "HTTP : pas de X-Frame-Options"
    echo "$H" | grep -qi '^x-content-type-options: nosniff' && ok "HTTP : autres en-têtes de sécurité conservés" || ko "HTTP : en-têtes de sécurité perdus"
else
    echo "6. (ignoré : nginx/curl non installés)"
fi

echo
echo "Résultat : $PASS ok, $FAIL échec(s)"
[ "$FAIL" -eq 0 ]
