#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# EGEN : diagnostique pourquoi Penpot s'affiche (ou non) dans l'iframe du Core.
# Interroge Penpot comme le fait le navigateur et compare ses en-têtes à l'origine du Core.
#
# Usage : docker/egen/check-embedding.sh <url-de-penpot> <origine-du-core>
#   ex. : docker/egen/check-embedding.sh http://localhost:9001 http://localhost:8080
#
# <origine-du-core> = schéma + hôte + port, EXACTEMENT comme dans la barre d'adresse du navigateur qui affiche
# le Core (http://localhost:8080 et http://127.0.0.1:8080 sont deux origines différentes).
# Code de sortie : 0 = embarquement autorisé · 1 = refusé par Penpot · 2 = Penpot injoignable ou mauvais appel.

set -u

PENPOT_URL="${1:-}"
CORE_ORIGIN="${2:-}"
[ -n "$PENPOT_URL" ] && [ -n "$CORE_ORIGIN" ] || { sed -n '5,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
command -v curl >/dev/null || { echo "curl est requis" >&2; exit 2; }

ok()   { echo "  ✓ $1"; }
ko()   { echo "  ✗ $1"; }
note() { echo "  • $1"; }

if [[ ! "$CORE_ORIGIN" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]]; then
    ko "origine du Core invalide : '$CORE_ORIGIN' (attendu : http://hôte[:port] ou https://hôte[:port], sans chemin ni « / » final)"
    exit 2
fi

case "$CORE_ORIGIN" in
    *://0.0.0.0|*://0.0.0.0:*)
        echo "  ⚠ 0.0.0.0 n'est pas une adresse de navigation : le serveur écoute sur toutes les interfaces, mais il faut ouvrir"
        echo "    le Core sur http://localhost:<port>. Sous 0.0.0.0 le navigateur est sur un AUTRE site que Penpot (localhost) :"
        echo "    la session Penpot ne passe pas dans l'iframe, et l'origine « 0.0.0.0 » doit être autorisée à part."
        echo ;;
esac

echo "Penpot : $PENPOT_URL"
echo "Core   : $CORE_ORIGIN"
echo

ERR="$(mktemp)"; trap 'rm -f "$ERR"' EXIT
RAW="$(curl -sS -m 10 -o /dev/null -D - -L --max-redirs 5 -w 'FINAL_URL:%{url_effective}\n' "$PENPOT_URL" 2>"$ERR")"
RC=$?
if [ $RC -ne 0 ]; then
    case $RC in
        7)  ko "Penpot ne répond pas à cette adresse (connexion refusée) : rien n'écoute sur ce port.";
            note "Penpot est-il démarré ?  docker compose ps   puis   docker compose logs penpot-frontend";
            note "Le port publié est celui de PENPOT_BIND (127.0.0.1:9001 par défaut)." ;;
        6)  ko "nom d'hôte introuvable (DNS) : $(cat "$ERR")" ;;
        28) ko "délai dépassé : Penpot ne répond pas dans les 10 s." ;;
        35|60|51|58) ko "erreur TLS/certificat : $(cat "$ERR")"; note "En local, utiliser http://localhost:<port> ; en production, un certificat valide est requis." ;;
        *)  ko "échec de la requête (curl $RC) : $(cat "$ERR")" ;;
    esac
    exit 2
fi

FINAL_URL="$(printf '%s\n' "$RAW" | sed -n 's/^FINAL_URL://p' | tail -1)"
# En-têtes de la DERNIÈRE réponse (après redirections éventuelles).
HEADERS="$(printf '%s\n' "$RAW" | tr -d '\r' | grep -v '^FINAL_URL:' | awk 'BEGIN{RS=""; ORS="\n\n"} {last=$0} END{print last}')"
STATUS="$(printf '%s\n' "$HEADERS" | sed -n '1s/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p')"

origin_of() { printf '%s' "$1" | sed -E 's#^(https?://[^/]+).*#\1#'; }
FINAL_ORIGIN="$(origin_of "$FINAL_URL")"
GIVEN_ORIGIN="$(origin_of "$PENPOT_URL")"

FAIL=0
if [ -n "$STATUS" ] && [ "$STATUS" -ge 500 ]; then
    ko "Penpot répond en erreur (HTTP $STATUS) : voir  docker compose logs"
    exit 2
fi
ok "Penpot répond (HTTP ${STATUS:-?})"

if [ "$FINAL_ORIGIN" != "$GIVEN_ORIGIN" ]; then
    note "Penpot redirige vers $FINAL_ORIGIN : c'est CETTE adresse que le navigateur doit voir : PENPOT_PUBLIC_URI (publiée comme `url` dans /egen-config.json) doit lui être identique."
fi

# --- X-Frame-Options : refuse tout embarquement par une autre origine ---------------------------
XFO="$(printf '%s\n' "$HEADERS" | grep -i '^x-frame-options:' | head -1 | sed 's/^[^:]*: *//')"
if [ -n "$XFO" ]; then
    ko "X-Frame-Options: $XFO — le navigateur REFUSE d'afficher Penpot dans l'iframe du Core (message « n'autorise pas la connexion »)."
    note "Cause : Penpot tourne SANS les fichiers nginx de ce fork, ou PENPOT_FRAME_ANCESTORS n'est pas défini."
    note "Vérifier : docker compose config | grep -A3 nginx-entrypoint   (volumes montés)  et  PENPOT_FRAME_ANCESTORS dans .env"
    note "Puis recréer le conteneur : docker compose up -d --force-recreate penpot-frontend"
    FAIL=1
else
    ok "pas d'X-Frame-Options"
fi

# --- CSP frame-ancestors (seule la politique IMPOSÉE compte, pas Report-Only) ----------------
ENFORCED="$(printf '%s\n' "$HEADERS" | grep -i '^content-security-policy:' | grep -io "frame-ancestors[^;]*" || true)"
if [ -n "$(printf '%s\n' "$HEADERS" | grep -i '^content-security-policy-report-only:' | grep -i 'frame-ancestors')" ] && [ -z "$ENFORCED" ]; then
    note "frame-ancestors n'apparaît qu'en Report-Only : les navigateurs l'ignorent, il ne protège ni ne bloque."
fi

allowed_by() { # $1 = jeton frame-ancestors ; vrai s'il autorise $CORE_ORIGIN
    local tok="$1"
    case "$tok" in
        "*") return 0 ;;
        "$CORE_ORIGIN") return 0 ;;
        *://\*.*) # joker de sous-domaine : https://*.exemple.org
            local scheme="${tok%%://*}" host="${tok#*://\*.}"
            [[ "$CORE_ORIGIN" == "$scheme://"*".$host" || "$CORE_ORIGIN" == "$scheme://"*".$host":* ]] && return 0 ;;
    esac
    return 1
}

if [ -n "$ENFORCED" ]; then
    ALL_OK=1; LIST=""
    # Plusieurs en-têtes CSP : le navigateur applique l'INTERSECTION ; chacun doit autoriser le Core.
    while IFS= read -r directive; do
        [ -z "$directive" ] && continue
        found=0
        for tok in ${directive#frame-ancestors}; do
            tok="${tok//\'/}"; LIST="$LIST $tok"
            allowed_by "$tok" && found=1
        done
        [ $found -eq 1 ] || ALL_OK=0
    done <<< "$ENFORCED"
    if [ $ALL_OK -eq 1 ]; then
        ok "frame-ancestors autorise $CORE_ORIGIN"
    else
        ko "frame-ancestors n'autorise PAS $CORE_ORIGIN (autorisés :${LIST:- aucun})"
        note "Mettre dans .env :  PENPOT_FRAME_ANCESTORS=$CORE_ORIGIN   puis   docker compose up -d --force-recreate penpot-frontend"
        note "Attention : l'origine doit être identique à celle de la barre d'adresse du Core (localhost ≠ 127.0.0.1, http ≠ https, port inclus)."
        FAIL=1
    fi
elif [ -z "$XFO" ]; then
    note "aucune restriction d'embarquement n'est annoncée : l'iframe s'affichera, mais n'importe quel site pourra aussi embarquer Penpot. Définir PENPOT_FRAME_ANCESTORS."
fi

# --- Backend de Penpot : le frontend (nginx) répond même quand le backend est arrêté ----------------
BACKEND_FAIL=0
API_CODE="$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$FINAL_ORIGIN/api/rpc/command/get-profile" 2>/dev/null || true)"
case "$API_CODE" in
    502|503|504)
        ko "le BACKEND de Penpot ne répond pas (HTTP $API_CODE sur /api) : le frontend est là, mais l'interface ne se chargera pas."
        note "docker compose ps   et   docker compose logs --tail 40 penpot-backend"
        note "« password authentication failed for user \"penpot\" » : le mot de passe de .env n'est plus celui de la base (voir le README, « Dépannage »)."
        BACKEND_FAIL=1 ;;
    2??|3??|401|403) ok "le backend de Penpot répond (HTTP $API_CODE)" ;;
esac

echo
if [ $FAIL -eq 0 ] && [ $BACKEND_FAIL -eq 1 ]; then
    echo "Résultat : l'embarquement est autorisé, MAIS le backend de Penpot est en panne : corriger le ✗ ci-dessus."
    exit 1
fi
if [ $FAIL -eq 0 ]; then
    echo "Résultat : Penpot PEUT être affiché dans l'iframe du Core ($CORE_ORIGIN)."
    echo "Si l'iframe reste vide malgré tout : ouvrir la console du navigateur (F12) et chercher « Refused to frame » ou « Mixed Content »."
    exit 0
fi
echo "Résultat : Penpot ne peut PAS être affiché dans l'iframe du Core ($CORE_ORIGIN). Corriger les ✗ ci-dessus."
exit 1
