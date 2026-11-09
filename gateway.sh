#!/usr/bin/env bash
# Cloudflare WARP gateway.
#
# Brings up a WireGuard tunnel to Cloudflare WARP inside this container's own
# network namespace and routes everything that LAN clients send to this
# container through it (NAT). Optionally falls back to the direct path when
# WARP is unreachable (KILL_SWITCH=false, the default) or blocks traffic
# (KILL_SWITCH=true).
set -euo pipefail

# ---------------------------------------------------------------- settings --
KILL_SWITCH="${KILL_SWITCH:-false}"
ENABLE_DNS="${ENABLE_DNS:-true}"
DNS_UPSTREAMS="${DNS_UPSTREAMS:-1.1.1.1 1.0.0.1}"
WARP_LICENSE_KEY="${WARP_LICENSE_KEY:-}"
WARP_ENDPOINT="${WARP_ENDPOINT:-}"          # host:port, default from wgcf profile
WARP_ENDPOINT_FALLBACK="${WARP_ENDPOINT_FALLBACK:-162.159.192.1:2408}"
WARP_MTU="${WARP_MTU:-}"                    # default from wgcf profile (1280)
HEALTH_URL="${HEALTH_URL:-https://1.1.1.1/cdn-cgi/trace}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-10}"    # seconds between checks
HEALTH_FAILURES="${HEALTH_FAILURES:-3}"     # consecutive failures => WARP down
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-5}"

DATA_DIR=/data
RUN_DIR=/run/warp-gateway
WG_IF=wg0
FWMARK=51820          # set by WireGuard on its own (outer) UDP packets
WARP_TABLE=51820      # default route -> wg0
DIRECT_TABLE=51821    # default route -> LAN router (fallback path)
PROBE_UID=9999        # health probe user, always routed via WARP

PRIO_MAIN=100         # non-default routes from main (LAN, etc.)
PRIO_PROBE=150        # health probe -> WARP table
PRIO_FALLBACK=200     # only present while failed over
PRIO_WARP=300         # everything else -> WARP table

is_true() { case "${1,,}" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac; }
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [warp-gateway] $*"; }
die() { log "ERROR: $*"; exit 1; }

mkdir -p "$RUN_DIR" "$DATA_DIR"
echo "starting" > "$RUN_DIR/state"

# ------------------------------------------------------------ LAN details --
LAN_IF="$(ip -4 route show default | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')"
LAN_GW="$(ip -4 route show default | awk '{for(i=1;i<NF;i++) if($i=="via"){print $(i+1); exit}}')"
[ -n "$LAN_IF" ] && [ -n "$LAN_GW" ] || die "no default IPv4 route; is the container attached to the LAN network?"
LAN_CIDR="$(ip -4 route show dev "$LAN_IF" scope link | awk '$1 ~ /\// {print $1; exit}')"
LAN_ADDR="$(ip -4 -o addr show dev "$LAN_IF" | awk '{print $4; exit}')"
log "LAN interface $LAN_IF, address $LAN_ADDR, subnet $LAN_CIDR, router $LAN_GW"
log "kill switch: $(is_true "$KILL_SWITCH" && echo ENABLED || echo disabled)"

# ------------------------------------------------- WARP account / profile --
cd "$DATA_DIR"
if [ ! -s wgcf-account.toml ]; then
    log "registering a new WARP device (wgcf register)"
    wgcf register --accept-tos || die "WARP registration failed"
fi

if [ -n "$WARP_LICENSE_KEY" ] && [ "$(cat .license-applied 2>/dev/null)" != "$WARP_LICENSE_KEY" ]; then
    log "applying WARP+ license key"
    if WGCF_LICENSE_KEY="$WARP_LICENSE_KEY" wgcf update; then
        echo "$WARP_LICENSE_KEY" > .license-applied
        rm -f wgcf-profile.conf
    else
        log "WARNING: applying license key failed, continuing with current account"
    fi
fi

if [ ! -s wgcf-profile.conf ]; then
    log "generating WireGuard profile (wgcf generate)"
    wgcf generate || die "could not generate WireGuard profile"
fi

profile_get() { # key -> all values (comma/line separated) for that key
    awk -F'=' -v k="$1" '
        { key=$1; gsub(/[ \t]/, "", key) }
        key==k { sub(/^[^=]*=[ \t]*/, ""); print }' wgcf-profile.conf | tr ',' '\n' | sed 's/[[:space:]]//g' | grep -v '^$'
}
WG_PRIVATE_KEY="$(profile_get PrivateKey | head -n1)"
WG_PEER_KEY="$(profile_get PublicKey | head -n1)"
WG_ADDR4="$(profile_get Address | grep -v ':' | head -n1)"
PROFILE_ENDPOINT="$(profile_get Endpoint | head -n1)"
MTU="${WARP_MTU:-$(profile_get MTU | head -n1)}"
MTU="${MTU:-1280}"
[ -n "$WG_PRIVATE_KEY" ] && [ -n "$WG_PEER_KEY" ] && [ -n "$WG_ADDR4" ] \
    || die "could not parse $DATA_DIR/wgcf-profile.conf (delete it to regenerate)"

# Resolve the endpoint to an IP now, while DNS still works via the LAN.
# This avoids depending on DNS later (e.g. with the kill switch engaged).
ENDPOINT="${WARP_ENDPOINT:-${PROFILE_ENDPOINT:-$WARP_ENDPOINT_FALLBACK}}"
EP_HOST="${ENDPOINT%:*}"; EP_PORT="${ENDPOINT##*:}"
if ! [[ "$EP_HOST" =~ ^[0-9.]+$ ]]; then
    EP_IP="$(getent ahostsv4 "$EP_HOST" 2>/dev/null | awk '{print $1; exit}')" || true
    if [ -n "${EP_IP:-}" ]; then
        ENDPOINT="$EP_IP:$EP_PORT"
    else
        log "WARNING: cannot resolve $EP_HOST, using $WARP_ENDPOINT_FALLBACK"
        ENDPOINT="$WARP_ENDPOINT_FALLBACK"
    fi
fi
log "WARP endpoint $ENDPOINT, tunnel address $WG_ADDR4, MTU $MTU"

# ---------------------------------------------------------------- cleanup --
WG_GO_PID=""
DNS_PID=""
cleanup_net() {
    ip rule del priority "$PRIO_MAIN"     2>/dev/null || true
    ip rule del priority "$PRIO_PROBE"    2>/dev/null || true
    ip rule del priority "$PRIO_FALLBACK" 2>/dev/null || true
    ip rule del priority "$PRIO_WARP"     2>/dev/null || true
    ip route flush table "$WARP_TABLE"    2>/dev/null || true
    ip route flush table "$DIRECT_TABLE"  2>/dev/null || true
    ip link del "$WG_IF"                  2>/dev/null || true
    for spec in "filter FORWARD WARPGW_FWD" "filter OUTPUT WARPGW_OUT" \
                "nat POSTROUTING WARPGW_NAT" "mangle FORWARD WARPGW_MSS"; do
        set -- $spec
        while iptables -t "$1" -D "$2" -j "$3" 2>/dev/null; do :; done
        iptables -t "$1" -F "$3" 2>/dev/null || true
        iptables -t "$1" -X "$3" 2>/dev/null || true
    done
}
shutdown() {
    log "shutting down"
    [ -n "$DNS_PID" ] && kill "$DNS_PID" 2>/dev/null || true
    cleanup_net
    [ -n "$WG_GO_PID" ] && kill "$WG_GO_PID" 2>/dev/null || true
    exit 0
}
trap shutdown TERM INT
cleanup_net

# ------------------------------------------------------- WireGuard tunnel --
if ip link add "$WG_IF" type wireguard 2>/dev/null; then
    log "using kernel WireGuard"
else
    [ -c /dev/net/tun ] || die "kernel WireGuard unavailable and /dev/net/tun missing"
    log "kernel WireGuard unavailable, using wireguard-go (userspace)"
    WG_PROCESS_FOREGROUND=1 wireguard-go "$WG_IF" &
    WG_GO_PID=$!
    for _ in $(seq 50); do ip link show "$WG_IF" >/dev/null 2>&1 && break; sleep 0.1; done
    ip link show "$WG_IF" >/dev/null 2>&1 || die "wireguard-go failed to create $WG_IF"
fi

umask 077
cat > "$RUN_DIR/wg.conf" <<EOF
[Interface]
PrivateKey = $WG_PRIVATE_KEY
FwMark = $FWMARK

[Peer]
PublicKey = $WG_PEER_KEY
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $ENDPOINT
PersistentKeepalive = 25
EOF
wg setconf "$WG_IF" "$RUN_DIR/wg.conf"
ip -4 addr add "$WG_ADDR4" dev "$WG_IF"
ip link set "$WG_IF" mtu "$MTU" up

# ----------------------------------------------------------------- routing --
# WireGuard's own UDP packets carry FWMARK and use the main table (-> LAN).
# Everything else (forwarded client traffic and local traffic) uses WARP.
ip route add default dev "$WG_IF" table "$WARP_TABLE"
ip route add default via "$LAN_GW" dev "$LAN_IF" table "$DIRECT_TABLE"
if is_true "$KILL_SWITCH"; then
    # If wg0 disappears its route goes with it; the blackhole keeps traffic
    # from falling through to the main table.
    ip route add blackhole default metric 4096 table "$WARP_TABLE"
fi
ip rule add priority "$PRIO_MAIN"  lookup main suppress_prefixlength 0
ip rule add priority "$PRIO_PROBE" uidrange "$PROBE_UID-$PROBE_UID" lookup "$WARP_TABLE"
ip rule add priority "$PRIO_WARP"  not fwmark "$FWMARK" lookup "$WARP_TABLE"

# ---------------------------------------------------------------- firewall --
iptables -t nat -N WARPGW_NAT
iptables -t nat -A WARPGW_NAT -o "$WG_IF" -j MASQUERADE
iptables -t nat -A WARPGW_NAT -o "$LAN_IF" -s "$LAN_CIDR" ! -d "$LAN_CIDR" -j MASQUERADE
iptables -t nat -A POSTROUTING -j WARPGW_NAT

iptables -t mangle -N WARPGW_MSS
iptables -t mangle -A WARPGW_MSS -o "$WG_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables -t mangle -A FORWARD -j WARPGW_MSS

iptables -N WARPGW_FWD
# Conntrack-INVALID packets skip NAT; never let them out un-translated.
iptables -A WARPGW_FWD -m conntrack --ctstate INVALID -j DROP
iptables -A WARPGW_FWD -i "$LAN_IF" -o "$WG_IF" -j ACCEPT
iptables -A WARPGW_FWD -i "$WG_IF" -o "$LAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -A WARPGW_FWD -i "$WG_IF" -j DROP          # no unsolicited inbound from WARP
if is_true "$KILL_SWITCH"; then
    # Never forward client traffic out of the LAN interface (that would bypass WARP).
    iptables -A WARPGW_FWD -i "$LAN_IF" -o "$LAN_IF" -j DROP
fi
iptables -A FORWARD -j WARPGW_FWD

# Don't send ICMP redirects telling clients to use the real router directly.
iptables -N WARPGW_OUT
iptables -A WARPGW_OUT -o "$LAN_IF" -p icmp --icmp-type redirect -j DROP
iptables -A OUTPUT -j WARPGW_OUT

# ------------------------------------------------------------- DNS server --
if is_true "$ENABLE_DNS"; then
    dns_args=(-k --no-resolv --no-hosts --interface="$LAN_IF" --bind-interfaces
              --cache-size=2000 --log-facility=- --user=root)
    for s in $DNS_UPSTREAMS; do dns_args+=(--server="$s"); done
    dnsmasq "${dns_args[@]}" &
    DNS_PID=$!
    log "DNS forwarder listening on ${LAN_ADDR%/*}:53 (upstreams: $DNS_UPSTREAMS)"
fi

# ---------------------------------------------------- health / failover --
STATE=""
warp_ok() {
    # Runs as the probe user, whose traffic is always policy-routed via wg0,
    # even while the gateway has failed over to the direct path.
    su-exec warpprobe curl -fsS --max-time "$HEALTH_TIMEOUT" "$HEALTH_URL" 2>/dev/null \
        | grep -Eq '^warp=(on|plus)$'
}
set_state() {
    local new="$1"
    [ "$new" = "$STATE" ] && return
    case "$new" in
        warp)
            ip rule del priority "$PRIO_FALLBACK" 2>/dev/null || true
            log "WARP is UP - routing traffic through Cloudflare WARP"
            ;;
        direct)
            ip rule add priority "$PRIO_FALLBACK" lookup "$DIRECT_TABLE" 2>/dev/null || true
            log "WARP is DOWN - kill switch disabled, routing traffic directly via $LAN_GW"
            ;;
        blocked)
            log "WARP is DOWN - kill switch enabled, blocking traffic until WARP recovers"
            ;;
    esac
    # Drop existing NAT state so flows re-establish on the new path.
    [ -n "$STATE" ] && conntrack -F >/dev/null 2>&1 || true
    STATE="$new"
    echo "$STATE" > "$RUN_DIR/state"
}
down_state() { is_true "$KILL_SWITCH" && echo blocked || echo direct; }

# Initial check: give the tunnel a few seconds before deciding.
log "waiting for WARP tunnel"
for _ in $(seq 10); do
    if warp_ok; then set_state warp; break; fi
    sleep 2
done
[ -n "$STATE" ] || set_state "$(down_state)"
log "gateway ready: point clients' default gateway$(is_true "$ENABLE_DNS" && echo ' and DNS server') at ${LAN_ADDR%/*}"

fails=0
while true; do
    sleep "$HEALTH_INTERVAL" & wait $!
    [ -n "$DNS_PID" ] && ! kill -0 "$DNS_PID" 2>/dev/null && die "dnsmasq exited"
    [ -n "$WG_GO_PID" ] && ! kill -0 "$WG_GO_PID" 2>/dev/null && die "wireguard-go exited"
    if warp_ok; then
        fails=0
        set_state warp
    else
        fails=$((fails + 1))
        if [ "$STATE" = warp ] && [ "$fails" -lt "$HEALTH_FAILURES" ]; then
            log "WARP health check failed ($fails/$HEALTH_FAILURES)"
        elif [ "$fails" -ge "$HEALTH_FAILURES" ] || [ "$STATE" != warp ]; then
            set_state "$(down_state)"
            # Nudge WireGuard to re-handshake.
            wg set "$WG_IF" peer "$WG_PEER_KEY" endpoint "$ENDPOINT" 2>/dev/null || true
        fi
    fi
done
