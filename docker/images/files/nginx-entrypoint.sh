#!/usr/bin/env bash

is_truthy() {
  local value="${1,,}"
  [[ "$value" == "true" || "$value" == "t" || "$value" == "1" ]]
}

is_falsy() {
  local value="${1,,}"
  [[ "$value" == "false" || "$value" == "f" || "$value" == "0" ]]
}


#########################################
## Air Gapped config
#########################################

if [[ $PENPOT_FLAGS == *"enable-air-gapped-conf"* ]]; then
    rm /etc/nginx/overrides/location.d/external-locations.conf;
    export PENPOT_FLAGS="$PENPOT_FLAGS disable-google-fonts-provider disable-dashboard-templates-section"
fi

#########################################
## App Frontend config
#########################################

update_flags() {
  if [ -n "$PENPOT_FLAGS" ]; then
    echo "$(sed \
      -e "s|^//var penpotFlags = .*;|var penpotFlags = \"$PENPOT_FLAGS\";|g" \
      "$1")" > "$1"
  fi

  if [ -n "$PENPOT_PUBLIC_URI" ]; then
      echo "var penpotPublicURI = \"$PENPOT_PUBLIC_URI\";" >> "$1";
  fi
}

update_oidc_name() {
  if [ -n "$PENPOT_OIDC_NAME" ]; then
    echo "$(sed \
      -e "s|^//var penpotOIDCName = .*;|var penpotOIDCName = \"$PENPOT_OIDC_NAME\";|g" \
      "$1")" > "$1"
  fi
}

update_flags /var/www/app/js/config.js
update_oidc_name /var/www/app/js/config.js

#########################################
## Nginx Config
#########################################

# nginx's `auto` starts one worker per CPU of the host, not of the container,
# and each worker reserves the memory for all its connections at startup. A
# container limited to a few CPUs on a large node can run out of memory before
# serving a request, so size the workers from the CPUs the container can use
# (its cpuset, and its CPU quota rounded up) when they are fewer than the host's.
container_cpu_limit() {
  local quota="" period="" cpus
  cpus="$(nproc 2>/dev/null)" || return 1
  if [ -r /sys/fs/cgroup/cpu.max ]; then
    read -r quota period < /sys/fs/cgroup/cpu.max
  elif [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then
    quota="$(< /sys/fs/cgroup/cpu/cpu.cfs_quota_us)"
    period="$(< /sys/fs/cgroup/cpu/cpu.cfs_period_us)"
  fi
  # "max" (cgroup v2) and -1 (cgroup v1) mean no quota, and 0 is not one.
  if [[ "$quota" =~ ^[1-9][0-9]*$ && "$period" =~ ^[1-9][0-9]*$ ]]; then
    quota=$(( (quota + period - 1) / period ))
    (( quota < cpus )) && cpus=$quota
  fi
  (( cpus < $(nproc --all) )) || return 1
  echo "$cpus"
}

export PENPOT_HTTP_SERVER_WORKER_PROCESSES=${PENPOT_HTTP_SERVER_WORKER_PROCESSES:-$(container_cpu_limit || echo auto)}
export PENPOT_HTTP_SERVER_WORKER_CONNECTIONS=${PENPOT_HTTP_SERVER_WORKER_CONNECTIONS:-65535}

if [[ ! "$PENPOT_HTTP_SERVER_WORKER_PROCESSES" =~ ^(auto|[1-9][0-9]*)$ ]]; then
    echo "penpot: invalid PENPOT_HTTP_SERVER_WORKER_PROCESSES '${PENPOT_HTTP_SERVER_WORKER_PROCESSES}'; expected auto or a positive integer" >&2
    exit 1
fi

if [[ ! "$PENPOT_HTTP_SERVER_WORKER_CONNECTIONS" =~ ^[1-9][0-9]*$ ]]; then
    echo "penpot: invalid PENPOT_HTTP_SERVER_WORKER_CONNECTIONS '${PENPOT_HTTP_SERVER_WORKER_CONNECTIONS}'; expected a positive integer" >&2
    exit 1
fi

export PENPOT_BACKEND_URI=${PENPOT_BACKEND_URI:-http://penpot-backend:6060}
export PENPOT_EXPORTER_URI=${PENPOT_EXPORTER_URI:-http://penpot-exporter:6061}
export PENPOT_HTTP_SERVER_MAX_BODY_SIZE=${PENPOT_HTTP_SERVER_MAX_BODY_SIZE:-367001600} # Default to 350MiB
export PENPOT_IPV6_LISTEN_DIRECTIVE=${PENPOT_IPV6_LISTEN_DIRECTIVE:-"listen [::]:8080 default_server reuseport backlog=16384;"}
if is_truthy "${PENPOT_DISABLE_IPV6_LISTEN:-}"; then
  export PENPOT_IPV6_LISTEN_DIRECTIVE=""
fi

envsubst "\$PENPOT_HTTP_SERVER_WORKER_PROCESSES,\$PENPOT_HTTP_SERVER_WORKER_CONNECTIONS,\$PENPOT_BACKEND_URI,\$PENPOT_EXPORTER_URI,\$PENPOT_HTTP_SERVER_MAX_BODY_SIZE,\$PENPOT_IPV6_LISTEN_DIRECTIVE" \
        < /tmp/nginx.conf.template > /etc/nginx/nginx.conf

if [[ " $PENPOT_FLAGS " != *" disable-admin-console "* ]]; then
    export PENPOT_ADMIN_CONSOLE_URI=${PENPOT_ADMIN_CONSOLE_URI:-http://penpot-admin-console:3000}
    envsubst "\$PENPOT_ADMIN_CONSOLE_URI" \
             < /tmp/nginx-admin-console-locations.conf.template > /etc/nginx/overrides/server.d/admin-console-locations.conf
else
    rm -f /etc/nginx/overrides/server.d/admin-console-locations.conf
fi

if [[ $PENPOT_FLAGS == *"enable-mcp"* ]]; then
    export PENPOT_MCP_URI=${PENPOT_MCP_URI:-http://penpot-mcp:4401}
    export PENPOT_MCP_URI_WS=${PENPOT_MCP_URI_WS:-http://penpot-mcp:4402}

    envsubst "\$PENPOT_MCP_URI,\$PENPOT_MCP_URI_WS" \
             < /tmp/nginx-mcp-locations.conf.template > /etc/nginx/overrides/server.d/mcp-locations.conf
else
    rm -f /etc/nginx/overrides/server.d/mcp-locations.conf
fi

PENPOT_DEFAULT_INTERNAL_RESOLVER="$(awk 'BEGIN{ORS=" "} $1=="nameserver" { sub(/%.*$/,"",$2); print ($2 ~ ":")? "["$2"]": $2}' /etc/resolv.conf)"
export PENPOT_INTERNAL_RESOLVER=${PENPOT_INTERNAL_RESOLVER:-$PENPOT_DEFAULT_INTERNAL_RESOLVER}
envsubst "\$PENPOT_INTERNAL_RESOLVER" \
         < /tmp/resolvers.conf.template > /etc/nginx/overrides/http.d/resolvers.conf

#########################################
## Security Headers Config
#########################################

# The default policy describes what a stock Penpot deployment actually
# needs: 'wasm-unsafe-eval' for the render engine, 'unsafe-inline' styles
# for the inline style attributes emitted by the UI, and blob:/data: for
# thumbnails, exports and font handling. Everything else is same-origin,
# because the Google Fonts and GitHub templates endpoints are reverse
# proxied by this very server.
#
# The hashes of the inline scripts of index.html are emitted by the frontend
# build and moved to /etc/nginx at image build time. A bundle predating that
# change simply yields no hashes, in which case those scripts would be
# reported (or blocked under enforce) as before.
#
# It ships in report-only mode because deployments with plugins enabled still
# report eval and remote fetch violations from the SES sandbox. Enforcing mode
# stays opt-in until that is resolved.
export PENPOT_CSP_MODE=${PENPOT_CSP_MODE:-report-only}

if [ -r /etc/nginx/csp-script-hashes.txt ]; then
    PENPOT_CSP_SCRIPT_HASHES=" $(tr -d '\n' < /etc/nginx/csp-script-hashes.txt)"
else
    PENPOT_CSP_SCRIPT_HASHES=""
fi

# EGEN: opt-in embedding of Penpot in an iframe (PENPOT_FRAME_ANCESTORS).
#
# Upstream forbids any framing except by the same origin: it sends
# `X-Frame-Options: SAMEORIGIN` unconditionally and `frame-ancestors 'self'`
# inside a CSP that ships in report-only mode, where frame-ancestors is NOT
# enforced. Embedding Penpot in a host application therefore fails with
# the browser refusing the frame, and extending only the CSP would not help.
#
# PENPOT_FRAME_ANCESTORS is a space-separated list of origins allowed to
# embed Penpot (e.g. "https://core.example.org https://*.example.org").
# When it is set:
#   - X-Frame-Options is dropped (it cannot express a list of origins);
#   - an ENFORCED `Content-Security-Policy: frame-ancestors 'self' <origins>`
#     header is sent whatever PENPOT_CSP_MODE says, so framing stays
#     restricted to the listed origins instead of becoming unrestricted;
#   - the default policy uses the same list, so enforce mode does not
#     intersect it down to 'self'.
# When it is unset, the behaviour is exactly the upstream one.
# Only scheme://host[:port] origins are accepted (optionally "*." host
# prefix): no bare "*", no quotes, no semicolon, so a typo cannot silently
# open the frame to everybody or inject another CSP directive.
if [ -n "${PENPOT_FRAME_ANCESTORS:-}" ]; then
    read -ra _fa_origins <<< "${PENPOT_FRAME_ANCESTORS}"
    _fa_list=""
    for _fa_origin in "${_fa_origins[@]}"; do
        if [[ ! "${_fa_origin}" =~ ^https?://(\*\.)?([A-Za-z0-9-]+\.)*[A-Za-z0-9-]+(:[0-9]{1,5})?$ ]]; then
            echo "penpot: invalid PENPOT_FRAME_ANCESTORS entry '${_fa_origin}'; expected scheme://host[:port] origins separated by spaces" >&2
            exit 1
        fi
        _fa_list="${_fa_list} ${_fa_origin}"
    done
    export PENPOT_CSP_FRAME_ANCESTORS="'self'${_fa_list}"
    export PENPOT_FRAME_DIRECTIVE="add_header Content-Security-Policy \"frame-ancestors ${PENPOT_CSP_FRAME_ANCESTORS}\" always;"
    unset _fa_origins _fa_list _fa_origin
else
    export PENPOT_CSP_FRAME_ANCESTORS="'self'"
    export PENPOT_FRAME_DIRECTIVE="add_header X-Frame-Options SAMEORIGIN always;"
fi

# EGEN: integration declaration for the EGEN Core (docs/integration-apps/17 §7 of the Core).
#
# Penpot ships no EGEN client script, so the declaration asks for no capability: the Core only embeds it
# in an iframe (no shared navigation, no live channel with the Shell). It is published at /egen-config.json, rendered at EVERY
# start from /tmp/egen-config.json.template, and only when the deployment is meant to be embedded:
#   - PENPOT_FRAME_ANCESTORS is set (same opt-in as the framing headers above), and
#   - PENPOT_PUBLIC_URI, the URL the browser reaches Penpot at, is a bare origin: https://host[:port],
#     or http://localhost[:port] for a local trial (the Core must then allow plain http).
# Otherwise nothing is published and /egen-config.json answers 404 (upstream behaviour). An invalid
# PENPOT_PUBLIC_URI only skips the declaration (PENPOT_PUBLIC_URI also serves Penpot itself).
# The file lives under /etc/nginx (writable here, like nginx.conf) and is served by an alias.
_egen_file=/etc/nginx/egen-config.json
rm -f "${_egen_file}"
if [ -n "${PENPOT_FRAME_ANCESTORS:-}" ]; then
    _egen_url="${PENPOT_PUBLIC_URI:-}"
    _egen_url="${_egen_url%/}"
    if [[ "${_egen_url}" =~ ^https://([A-Za-z0-9-]+\.)*[A-Za-z0-9-]+(:[0-9]{1,5})?$ ]] \
        || [[ "${_egen_url}" =~ ^http://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?$ ]]; then
        sed "s|__PENPOT_PUBLIC_URL__|${_egen_url}|" /tmp/egen-config.json.template > "${_egen_file}"
    else
        echo "penpot: WARNING: /egen-config.json not published: PENPOT_PUBLIC_URI '${PENPOT_PUBLIC_URI:-}' is not a bare origin (https://host[:port], or http://localhost[:port])" >&2
    fi
fi
unset _egen_file _egen_url

# Remember whether the policy comes from the deployment before the default
# is applied, so the warning below only fires for the default one.
if [ -n "${PENPOT_CSP_POLICY:-}" ]; then
    PENPOT_CSP_POLICY_IS_CUSTOM="true"
else
    PENPOT_CSP_POLICY_IS_CUSTOM="false"
fi

# Directives a deployment may extend. The default policy carries hashes that
# change on every build, so a deployment that needs an extra origin cannot
# hardcode the whole policy without recomputing them at each release. These
# variables let it declare only what it adds.
#
# base-uri, form-action and object-src are deliberately not extensible:
# there is no legitimate reason to relax them, and doing so silently removes
# the protection they provide. frame-ancestors is only extended through
# PENPOT_FRAME_ANCESTORS (see above), which validates every origin. A deployment that really
# needs it can still set PENPOT_CSP_POLICY and own the whole policy.
if [ "${PENPOT_CSP_POLICY_IS_CUSTOM}" = "false" ]; then
    export PENPOT_CSP_POLICY="default-src 'self'\
; base-uri 'self'\
; object-src 'none'\
; frame-ancestors ${PENPOT_CSP_FRAME_ANCESTORS}\
; form-action 'self'\
; manifest-src 'self'\
; script-src 'self' 'wasm-unsafe-eval'${PENPOT_CSP_SCRIPT_HASHES}${PENPOT_CSP_SCRIPT_SRC_EXTRA:+ ${PENPOT_CSP_SCRIPT_SRC_EXTRA}}\
; style-src 'self' 'unsafe-inline'${PENPOT_CSP_STYLE_SRC_EXTRA:+ ${PENPOT_CSP_STYLE_SRC_EXTRA}}\
; img-src 'self' data: blob:${PENPOT_CSP_IMG_SRC_EXTRA:+ ${PENPOT_CSP_IMG_SRC_EXTRA}}\
; font-src 'self'${PENPOT_CSP_FONT_SRC_EXTRA:+ ${PENPOT_CSP_FONT_SRC_EXTRA}}\
; connect-src 'self' blob: data:${PENPOT_CSP_CONNECT_SRC_EXTRA:+ ${PENPOT_CSP_CONNECT_SRC_EXTRA}}\
; frame-src 'self'${PENPOT_CSP_FRAME_SRC_EXTRA:+ ${PENPOT_CSP_FRAME_SRC_EXTRA}}\
; worker-src 'self' blob:\
; media-src 'self' blob:${PENPOT_CSP_REPORT_URI:+; report-uri ${PENPOT_CSP_REPORT_URI}}"
else
    for _var in SCRIPT_SRC_EXTRA STYLE_SRC_EXTRA IMG_SRC_EXTRA FONT_SRC_EXTRA \
                CONNECT_SRC_EXTRA FRAME_SRC_EXTRA REPORT_URI; do
        eval "_value=\${PENPOT_CSP_${_var}:-}"
        if [ -n "${_value}" ]; then
            echo "penpot: WARNING: PENPOT_CSP_${_var} is ignored because PENPOT_CSP_POLICY defines the whole policy." >&2
        fi
    done
    unset _var _value
    export PENPOT_CSP_POLICY
fi

case "${PENPOT_CSP_MODE}" in
    enforce)
        export PENPOT_CSP_DIRECTIVE="add_header Content-Security-Policy \"${PENPOT_CSP_POLICY}\" always;"
        # The plugin runtime initialises on every page load, whether or not a
        # plugin is opened, and its sandbox needs 'unsafe-eval'. Look at the
        # policy that will actually be served rather than at where it came
        # from, since it can be granted through the default policy, through
        # PENPOT_CSP_SCRIPT_SRC_EXTRA or through a policy of your own.
        case "${PENPOT_CSP_POLICY}" in
            *"'unsafe-eval'"*) ;;
            *)
                echo "penpot: WARNING: PENPOT_CSP_MODE=enforce degrades the plugin runtime." >&2
                echo "penpot: it initialises on every page load and needs 'unsafe-eval', which this policy does not grant." >&2
                echo "penpot: add it through PENPOT_CSP_SCRIPT_SRC_EXTRA if you need plugins, or keep report-only." >&2
                ;;
        esac
        ;;
    report-only)
        export PENPOT_CSP_DIRECTIVE="add_header Content-Security-Policy-Report-Only \"${PENPOT_CSP_POLICY}\" always;"
        ;;
    disabled)
        export PENPOT_CSP_DIRECTIVE=""
        ;;
    *)
        echo "penpot: invalid PENPOT_CSP_MODE '${PENPOT_CSP_MODE}'; expected one of: enforce, report-only, disabled" >&2
        exit 1
        ;;
esac

# HSTS is only meaningful when the deployment is served over HTTPS, so it
# defaults to enabled when PENPOT_PUBLIC_URI declares an https scheme and
# to disabled otherwise. Set PENPOT_HSTS_VALUE explicitly to override it,
# for example to add includeSubDomains or preload, or to an empty value
# to disable it on an https deployment.
if [[ "${PENPOT_PUBLIC_URI:-}" == https://* ]]; then
    export PENPOT_HSTS_VALUE=${PENPOT_HSTS_VALUE-"max-age=31536000"}
else
    export PENPOT_HSTS_VALUE=${PENPOT_HSTS_VALUE-""}
fi

if [ -n "${PENPOT_HSTS_VALUE}" ]; then
    export PENPOT_HSTS_DIRECTIVE="add_header Strict-Transport-Security \"${PENPOT_HSTS_VALUE}\" always;"
else
    export PENPOT_HSTS_DIRECTIVE=""
fi

envsubst "\$PENPOT_CSP_DIRECTIVE,\$PENPOT_HSTS_DIRECTIVE,\$PENPOT_FRAME_DIRECTIVE" \
         < /tmp/nginx-security-headers.conf.template > /etc/nginx/nginx-security-headers.conf

exec "$@";
