#!/usr/bin/env bash
# =============================================================================
# deploy-proxy.sh — one-click VLESS+Reality+Vision (Xray) + Hysteria2 (port hopping)
# Target: fresh Ubuntu/Debian VPS, run as root.
#
#   bash deploy-proxy.sh              # install / re-run (reuses existing credentials)
#   bash deploy-proxy.sh --show       # re-print client links / QR codes only
#   bash deploy-proxy.sh --uninstall  # remove everything this script installed
#
# Env overrides (all optional):
#   NODE_NAME     node name prefix in links (default: short hostname)
#   SERVER_ADDR   address put in client links (default: auto-detected public IPv4)
#   HY2_PASSWORD  Hysteria2 password (default: random, reused on re-run)
#   HY2_PORT      Hysteria2 UDP port (default: random 50001-65000, reused on re-run)
#   HOP_RANGE     UDP port-hopping range "A-B" (default 20000-50000; NO_HOP=1 disables)
#   REALITY_PORT  Reality TCP port (default: 443 if free, else 8443, else random)
#   REALITY_SNI   Reality target/SNI (default: auto-pick + end-to-end verified)
#   KEEP_BBR=1    with --uninstall: keep BBR/sysctl tuning
# =============================================================================
set -euo pipefail

STATE_DIR=/etc/proxy-deploy
STATE_FILE=$STATE_DIR/state.env
HOP_ENV=$STATE_DIR/porthop.env
OUT_DIR=/root/proxy-client
HY_DIR=/etc/hysteria
XRAY_CONF=/usr/local/etc/xray/config.json
PORTHOP_SCRIPT=/usr/local/sbin/hy2-porthop.sh
PORTHOP_UNIT=/etc/systemd/system/hy2-porthop.service
SYSCTL_FILE=/etc/sysctl.d/99-proxy.conf
MODLOAD_FILE=/etc/modules-load.d/bbr.conf
HY2_INSTALL_URL=https://get.hy2.sh/
XRAY_INSTALL_URL=https://github.com/XTLS/Xray-install/raw/main/install-release.sh
SNI_CANDIDATES=(dl.google.com www.amazon.com www.microsoft.com www.apple.com)
MASQ_URL=https://www.bing.com
HY2_SNI=www.bing.com
TEST_URL=https://www.gstatic.com/generate_204

TMP_FILES=()
BG_PIDS=()
cleanup() {
  local p f
  for p in "${BG_PIDS[@]:-}"; do if [ -n "$p" ]; then kill "$p" 2>/dev/null || true; fi; done
  for f in "${TMP_FILES[@]:-}"; do [ -n "$f" ] && rm -f "$f"; done
}
trap cleanup EXIT

c_g=$'\033[32m'; c_y=$'\033[33m'; c_r=$'\033[31m'; c_b=$'\033[36m'; c_0=$'\033[0m'
log()  { printf '%s[*]%s %s\n' "$c_b" "$c_0" "$*"; }
ok()   { printf '%s[OK]%s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_y" "$c_0" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$c_r" "$c_0" "$*" >&2; exit 1; }

mktmp() {  # mktmp [suffix]  (xray/hysteria detect config format from the file extension)
  local f; f=$(mktemp --suffix="${1:-}"); chmod 600 "$f"; TMP_FILES+=("$f"); printf '%s' "$f"; }

urlencode() {
  local s=$1 out='' c i
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in
      [a-zA-Z0-9.~_-]) out+=$c ;;
      *) printf -v c '%%%02X' "'$c"; out+=$c ;;
    esac
  done
  printf '%s' "$out"
}
yaml_sq() { local s=${1//\'/\'\'}; printf "'%s'" "$s"; }   # YAML single-quoted scalar

# owner process name of a listening port: port_owner tcp|udp PORT
port_owner() {
  local proto=$1 port=$2 flag
  [ "$proto" = tcp ] && flag=-Htlnp || flag=-Hulnp
  ss "$flag" "sport = :$port" 2>/dev/null | grep -o 'users:(("[^"]*' | head -1 | cut -d'"' -f2 || true
}
port_listening() { local proto=$1 port=$2 flag; [ "$proto" = tcp ] && flag=-Htln || flag=-Huln
  [ -n "$(ss "$flag" "sport = :$port" 2>/dev/null)" ]; }

fetch_run() {   # fetch_run URL args...  (download first so curl failures are caught)
  local url=$1 f; shift
  f=$(mktmp)
  curl -fsSL --retry 3 -o "$f" "$url" || die "download failed: $url"
  bash "$f" "$@"
}

detect_ip() {
  local fam=$1 ip='' u
  for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com https://ip.sb; do
    ip=$(curl "-$fam" -fsS -m 6 "$u" 2>/dev/null | tr -d '[:space:]') || ip=''
    if [ "$fam" = 4 ] && [[ $ip =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then printf '%s' "$ip"; return 0; fi
    if [ "$fam" = 6 ] && [[ $ip == *:* ]]; then printf '%s' "$ip"; return 0; fi
  done
  # fallback: source address of the default route
  if [ "$fam" = 4 ]; then ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  else ip=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'); fi
  [[ $ip == fe80* ]] && ip=''
  printf '%s' "$ip"
}

# ----------------------------------------------------------------------------- state
load_state() {
  # env overrides captured before sourcing the state file
  local e_name=${NODE_NAME:-} e_addr=${SERVER_ADDR:-} e_pw=${HY2_PASSWORD:-} e_hp=${HY2_PORT:-}
  local e_hop=${HOP_RANGE:-} e_rp=${REALITY_PORT:-} e_sni=${REALITY_SNI:-}
  if [ -r "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    [ "${1:-}" = quiet ] || log "existing state found ($STATE_FILE) — reusing credentials"
  fi
  [ -n "$e_name" ] && NODE_NAME=$e_name
  [ -n "$e_addr" ] && SERVER_ADDR=$e_addr
  [ -n "$e_pw" ]   && HY2_PASSWORD=$e_pw
  [ -n "$e_hp" ]   && HY2_PORT=$e_hp
  [ -n "$e_hop" ]  && HOP_RANGE=$e_hop
  [ -n "$e_rp" ]   && REALITY_PORT=$e_rp
  [ -n "$e_sni" ]  && { REALITY_SNI=$e_sni; SNI_FORCED=1; }
  NODE_NAME=${NODE_NAME:-$(hostname -s 2>/dev/null || echo VPS)}
  NODE_NAME=$(printf '%s' "$NODE_NAME" | tr -cd 'A-Za-z0-9._-'); NODE_NAME=${NODE_NAME:-VPS}
  HOP_RANGE=${HOP_RANGE:-20000-50000}
  SNI_FORCED=${SNI_FORCED:-0}
  XRAY_UUID=${XRAY_UUID:-}; XRAY_PRIV=${XRAY_PRIV:-}; XRAY_SID=${XRAY_SID:-}
  HY2_PASSWORD=${HY2_PASSWORD:-}; HY2_PORT=${HY2_PORT:-}; REALITY_PORT=${REALITY_PORT:-}
  REALITY_SNI=${REALITY_SNI:-}; SERVER_ADDR=${SERVER_ADDR:-}; UFW_RULES=${UFW_RULES:-}
}

save_state() {
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  local f; f=$(mktmp)
  {
    printf '# generated by deploy-proxy.sh — contains secrets\n'
    local v
    for v in NODE_NAME SERVER_ADDR HY2_PASSWORD HY2_PORT HOP_RANGE REALITY_PORT REALITY_SNI \
             XRAY_UUID XRAY_PRIV XRAY_SID UFW_RULES; do
      printf '%s=%q\n' "$v" "${!v}"
    done
  } > "$f"
  install -m 600 "$f" "$STATE_FILE"
}

# ----------------------------------------------------------------------------- steps
preflight() {
  [ "$(id -u)" -eq 0 ] || die "please run as root"
  command -v apt-get >/dev/null || die "only Debian/Ubuntu (apt) is supported"
  command -v systemctl >/dev/null || die "systemd is required"
  [ "$(uname -m)" = x86_64 ] || [ "$(uname -m)" = aarch64 ] || warn "untested architecture: $(uname -m)"
}

install_pkgs() {
  log "installing packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y -qq
  apt-get install -y -qq curl socat iptables openssl qrencode uuid-runtime jq iproute2 ca-certificates kmod >/dev/null
  ok "packages installed"
}

setup_bbr() {
  log "enabling BBR + fq + 16MB socket buffers"
  modprobe tcp_bbr 2>/dev/null || warn "modprobe tcp_bbr failed (kernel may have it built-in)"
  echo tcp_bbr > "$MODLOAD_FILE"
  cat > "$SYSCTL_FILE" <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
  sysctl --system >/dev/null 2>&1 || true
  local cc; cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')
  if [ "$cc" = bbr ]; then ok "congestion control: bbr"; else warn "congestion control is '$cc' (BBR not active)"; fi
}

pick_hy2_port() {
  local lo=${HOP_RANGE%-*} hi=${HOP_RANGE#*-} p owner i
  if [ -n "$HY2_PORT" ]; then
    owner=$(port_owner udp "$HY2_PORT")
    [ -z "$owner" ] || [ "$owner" = hysteria ] || die "UDP $HY2_PORT is used by '$owner'"
    return
  fi
  for i in $(seq 1 50); do
    p=$(shuf -i 50001-65000 -n 1)
    [ "${NO_HOP:-0}" != 1 ] && [ "$p" -ge "$lo" ] && [ "$p" -le "$hi" ] && continue
    port_listening udp "$p" || { HY2_PORT=$p; return; }
    : "$i"
  done
  die "could not find a free UDP port"
}

pick_reality_port() {
  local owner p
  if [ -n "$REALITY_PORT" ]; then
    owner=$(port_owner tcp "$REALITY_PORT")
    [ -z "$owner" ] || [ "$owner" = xray ] || die "TCP $REALITY_PORT is used by '$owner'"
    return
  fi
  for p in 443 8443; do
    owner=$(port_owner tcp "$p")
    if [ -z "$owner" ] || [ "$owner" = xray ]; then REALITY_PORT=$p; return; fi
    log "TCP $p is used by '$owner', skipping"
  done
  for _ in $(seq 1 50); do
    p=$(shuf -i 10000-19999 -n 1)
    port_listening tcp "$p" || { REALITY_PORT=$p; return; }
  done
  die "could not find a free TCP port"
}

valid_port() { [[ $1 =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

validate_inputs() {
  [[ $HOP_RANGE =~ ^[0-9]+-[0-9]+$ ]] || die "HOP_RANGE must look like 20000-50000"
  local lo=${HOP_RANGE%-*} hi=${HOP_RANGE#*-}
  if ! { [ "$lo" -ge 1024 ] && [ "$hi" -le 65535 ] && [ "$lo" -lt "$hi" ]; }; then die "invalid HOP_RANGE $HOP_RANGE"; fi
  if [ -n "$HY2_PORT" ] && ! valid_port "$HY2_PORT"; then die "invalid HY2_PORT"; fi
  if [ -n "$REALITY_PORT" ] && ! valid_port "$REALITY_PORT"; then die "invalid REALITY_PORT"; fi
}

warn_hop_conflicts() {
  local lo=${HOP_RANGE%-*} hi=${HOP_RANGE#*-}
  if [ "${NO_HOP:-0}" != 1 ]; then
    # warn about other UDP services inside the hop range (they'd be shadowed)
    local busy
    busy=$(ss -Hulnp 2>/dev/null | awk -v lo="$lo" -v hi="$hi" '{n=split($4,a,":"); p=a[n]; if (p>=lo && p<=hi) print p" "$NF}' | grep -v hysteria || true)
    [ -z "$busy" ] || warn "UDP listeners inside hop range $HOP_RANGE will be shadowed for external clients:"$'\n'"$busy"
  fi
}

install_hysteria() {
  log "installing / upgrading Hysteria2 (official get.hy2.sh)"
  fetch_run "$HY2_INSTALL_URL" >/dev/null 2>&1 || fetch_run "$HY2_INSTALL_URL" || die "Hysteria2 install failed"
  command -v hysteria >/dev/null || die "hysteria binary not found after install"
  id hysteria >/dev/null 2>&1 || useradd --system --home-dir /var/lib/hysteria --create-home --shell /usr/sbin/nologin hysteria
  mkdir -p /var/lib/hysteria && chown hysteria:hysteria /var/lib/hysteria
  ok "$(hysteria version 2>/dev/null | awk '/^Version/{print "hysteria "$2}')"
}

setup_hy2_cert() {
  mkdir -p "$HY_DIR"
  local need=1
  if [ -s "$HY_DIR/cert.crt" ] && [ -s "$HY_DIR/private.key" ] && \
     openssl x509 -in "$HY_DIR/cert.crt" -noout -ext subjectAltName 2>/dev/null | grep -q "DNS:$HY2_SNI"; then
    need=0
  fi
  if [ "$need" = 1 ]; then
    log "generating self-signed cert (CN/SAN $HY2_SNI, EC P-256, 100y)"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 36500 \
      -keyout "$HY_DIR/private.key" -out "$HY_DIR/cert.crt" \
      -subj "/CN=$HY2_SNI" -addext "subjectAltName=DNS:$HY2_SNI" >/dev/null 2>&1 || die "cert generation failed"
  else
    log "reusing existing Hysteria2 cert"
  fi
  chown root:root "$HY_DIR/cert.crt"; chmod 644 "$HY_DIR/cert.crt"
  chown hysteria:hysteria "$HY_DIR/private.key"; chmod 600 "$HY_DIR/private.key"
  HY2_PIN=$(openssl x509 -in "$HY_DIR/cert.crt" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')
}

configure_hysteria() {
  [ -n "$HY2_PASSWORD" ] || HY2_PASSWORD=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-20)
  cat > "$HY_DIR/config.yaml" <<EOF
# generated by deploy-proxy.sh
listen: :$HY2_PORT

tls:
  cert: $HY_DIR/cert.crt
  key: $HY_DIR/private.key

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432

auth:
  type: password
  password: $(yaml_sq "$HY2_PASSWORD")

masquerade:
  type: proxy
  proxy:
    url: $MASQ_URL
    rewriteHost: true
EOF
  chown root:hysteria "$HY_DIR/config.yaml"; chmod 640 "$HY_DIR/config.yaml"
  systemctl daemon-reload
  systemctl enable hysteria-server.service >/dev/null 2>&1
  systemctl restart hysteria-server.service
  sleep 2
  systemctl is-active --quiet hysteria-server.service || { journalctl -u hysteria-server -n 20 --no-pager; die "hysteria-server failed to start"; }
  ok "hysteria-server running on UDP $HY2_PORT"
}

setup_porthop() {
  if [ "${NO_HOP:-0}" = 1 ]; then
    log "NO_HOP=1: port hopping disabled"
    if [ -x "$PORTHOP_SCRIPT" ]; then "$PORTHOP_SCRIPT" down || true; fi
    systemctl disable --now hy2-porthop.service >/dev/null 2>&1 || true
    return
  fi
  local iface; iface=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  mkdir -p "$STATE_DIR"
  printf 'IFACE=%q\nRANGE=%q\nTARGET=%q\n' "$iface" "${HOP_RANGE/-/:}" "$HY2_PORT" > "$HOP_ENV"
  cat > "$PORTHOP_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# Hysteria2 UDP port hopping (generated by deploy-proxy.sh). Idempotent: up|down
set -u
CONF=/etc/proxy-deploy/porthop.env
CH=HY2_PORTHOP
IFACE=''; RANGE=''; TARGET=''
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"
ifarg=(); [ -n "$IFACE" ] && ifarg=(-i "$IFACE")
tables() { local t; for t in iptables ip6tables; do command -v "$t" >/dev/null && "$t" -t nat -S >/dev/null 2>&1 && echo "$t"; done; }
del_jumps() {  # remove every PREROUTING jump to our chain, whatever its old parameters
  local t=$1 line
  local -a a
  while read -r line; do
    [ -n "$line" ] || continue
    read -ra a <<<"$line"
    "$t" -t nat -D "${a[@]:1}" 2>/dev/null || true
  done < <("$t" -t nat -S PREROUTING 2>/dev/null | grep -- "-j $CH" || true)
}
up() {
  if [ -z "$RANGE" ] || [ -z "$TARGET" ]; then echo "missing RANGE/TARGET in $CONF" >&2; exit 1; fi
  local t
  for t in $(tables); do
    del_jumps "$t"
    "$t" -t nat -N "$CH" 2>/dev/null || true
    "$t" -t nat -F "$CH"
    "$t" -t nat -A "$CH" -p udp --dport "$RANGE" -j REDIRECT --to-ports "$TARGET"
    "$t" -t nat -I PREROUTING 1 "${ifarg[@]}" -p udp --dport "$RANGE" -j "$CH"
  done
}
down() {
  local t
  for t in $(tables); do
    del_jumps "$t"
    "$t" -t nat -F "$CH" 2>/dev/null || true
    "$t" -t nat -X "$CH" 2>/dev/null || true
  done
}
case "${1:-}" in up) up ;; down) down ;; *) echo "usage: $0 up|down" >&2; exit 1 ;; esac
EOF
  chmod 755 "$PORTHOP_SCRIPT"
  cat > "$PORTHOP_UNIT" <<EOF
[Unit]
Description=Hysteria2 UDP port hopping ($HOP_RANGE -> $HY2_PORT)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$PORTHOP_SCRIPT up
ExecStop=$PORTHOP_SCRIPT down

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable hy2-porthop.service >/dev/null 2>&1
  systemctl restart hy2-porthop.service
  local n4 n6
  n4=$(iptables -t nat -S PREROUTING 2>/dev/null | grep -c -- '-j HY2_PORTHOP' || true)
  n6=$(ip6tables -t nat -S PREROUTING 2>/dev/null | grep -c -- '-j HY2_PORTHOP' || true)
  ok "port hopping UDP $HOP_RANGE -> $HY2_PORT (iface ${iface:-any}; v4 jumps=$n4, v6 jumps=$n6)"
}

install_xray() {
  log "installing / upgrading Xray (official XTLS script)"
  fetch_run "$XRAY_INSTALL_URL" install >/dev/null 2>&1 || fetch_run "$XRAY_INSTALL_URL" install || die "Xray install failed"
  command -v xray >/dev/null || die "xray binary not found after install"
  ok "$(xray version 2>/dev/null | head -1 | awk '{print "xray "$2}')"
}

gen_xray_keys() {
  [ -n "$XRAY_UUID" ] || XRAY_UUID=$(xray uuid 2>/dev/null || uuidgen)
  [ -n "$XRAY_SID" ]  || XRAY_SID=$(openssl rand -hex 8)
  local out
  if [ -n "$XRAY_PRIV" ]; then out=$(xray x25519 -i "$XRAY_PRIV"); else out=$(xray x25519); fi
  XRAY_PRIV=$(printf '%s\n' "$out" | grep -iE '^private' | head -1 | awk -F': *' '{print $2}')
  XRAY_PUB=$(printf '%s\n' "$out" | grep -iE '^(public key|password)' | head -1 | awk -F': *' '{print $2}')
  if [ -z "$XRAY_PRIV" ] || [ -z "$XRAY_PUB" ]; then die "failed to parse 'xray x25519' output"; fi
}

write_xray_config() {   # write_xray_config SNI
  local sni=$1 grp
  mkdir -p "$(dirname "$XRAY_CONF")"
  cat > "$XRAY_CONF" <<EOF
{
  "log": { "loglevel": "warning", "access": "none" },
  "inbounds": [
    {
      "tag": "vless-reality",
      "port": $REALITY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$XRAY_UUID", "flow": "xtls-rprx-vision", "email": "user@$NODE_NAME" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "$sni:443",
          "xver": 0,
          "serverNames": [ "$sni" ],
          "privateKey": "$XRAY_PRIV",
          "shortIds": [ "$XRAY_SID" ]
        }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ], "routeOnly": true }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "ip": [ "geoip:private" ], "outboundTag": "block" },
      { "type": "field", "protocol": [ "bittorrent" ], "outboundTag": "block" }
    ]
  }
}
EOF
  grp=$(id -gn nobody 2>/dev/null || echo nogroup)
  chown "root:$grp" "$XRAY_CONF"; chmod 640 "$XRAY_CONF"
  xray run -test -config "$XRAY_CONF" >/dev/null 2>&1 || { xray run -test -config "$XRAY_CONF"; die "xray config test failed"; }
  systemctl enable xray.service >/dev/null 2>&1
  systemctl restart xray.service
  sleep 1
  systemctl is-active --quiet xray.service || { journalctl -u xray -n 20 --no-pager; die "xray failed to start"; }
}

probe_sni() {  # prints TLS handshake time if host supports TLS1.3 + h2 + X25519
  local h=$1 out
  out=$(curl -sS -o /dev/null --tlsv1.3 --http2 -m 6 -w '%{http_version} %{time_appconnect}' "https://$h/" 2>/dev/null) || return 1
  [ "${out%% *}" = 2 ] || return 1
  timeout 8 openssl s_client -connect "$h:443" -servername "$h" -tls1_3 -groups X25519 </dev/null 2>/dev/null | grep -q 'TLSv1.3' || return 1
  printf '%s' "${out#* }"
}

reality_selftest() {  # end-to-end request through Reality using a throwaway local client
  local sni=$1 cfg sp pid i rc=1
  cfg=$(mktmp .json); sp=$(shuf -i 10000-19999 -n 1)
  cat > "$cfg" <<EOF
{ "log": { "loglevel": "none" },
  "inbounds": [ { "listen": "127.0.0.1", "port": $sp, "protocol": "socks" } ],
  "outbounds": [ { "protocol": "vless",
    "settings": { "vnext": [ { "address": "127.0.0.1", "port": $REALITY_PORT,
      "users": [ { "id": "$XRAY_UUID", "flow": "xtls-rprx-vision", "encryption": "none" } ] } ] },
    "streamSettings": { "network": "tcp", "security": "reality",
      "realitySettings": { "serverName": "$sni", "fingerprint": "chrome", "publicKey": "$XRAY_PUB", "shortId": "$XRAY_SID" } } } ] }
EOF
  xray run -c "$cfg" >/dev/null 2>&1 & pid=$!; BG_PIDS+=("$pid")
  sleep 1.5
  for i in 1 2 3; do
    if [ "$(curl -s -o /dev/null -m 12 -w '%{http_code}' -x "socks5h://127.0.0.1:$sp" "$TEST_URL" || true)" = 204 ]; then rc=0; break; fi
    : "$i"; sleep 1
  done
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  return $rc
}

configure_xray() {
  gen_xray_keys
  local -a order=() ; local h t
  if [ "$SNI_FORCED" = 1 ]; then
    order=("$REALITY_SNI")
  else
    log "probing Reality target candidates (TLS1.3 + h2 + X25519)"
    local scored=''
    # previously chosen SNI goes first (keeps clients stable on re-run)
    local -a cands=()
    [ -n "$REALITY_SNI" ] && cands+=("$REALITY_SNI")
    for h in "${SNI_CANDIDATES[@]}"; do [ "$h" = "$REALITY_SNI" ] || cands+=("$h"); done
    for h in "${cands[@]}"; do
      if t=$(probe_sni "$h"); then
        log "  $h ok (tls ${t}s)"
        # Xray warns that apple/icloud targets may get the IP flagged -> try them last
        case $h in *apple.com|*icloud.com) t="9$t" ;; esac
        scored+="$t $h"$'\n'
      else log "  $h unsuitable"; fi
    done
    if [ -n "$REALITY_SNI" ] && grep -q " $REALITY_SNI\$" <<<"$scored"; then order+=("$REALITY_SNI"); fi
    while read -r _ h; do
      [ -n "$h" ] && [ "$h" != "$REALITY_SNI" ] && order+=("$h")
    done < <(printf '%s' "$scored" | sort -n)
    [ "${#order[@]}" -gt 0 ] || die "no Reality target candidate passed the TLS probe; set REALITY_SNI"
  fi
  local chosen=''
  for h in "${order[@]}"; do
    log "testing Reality end-to-end with SNI $h on TCP $REALITY_PORT"
    write_xray_config "$h"
    if reality_selftest "$h"; then chosen=$h; break; fi
    warn "Reality self-test failed with $h"
  done
  if [ -z "$chosen" ]; then
    if [ "$SNI_FORCED" = 1 ]; then
      warn "keeping forced REALITY_SNI=$REALITY_SNI despite failed self-test"; chosen=$REALITY_SNI
    else
      die "Reality self-test failed for all candidates"
    fi
  fi
  REALITY_SNI=$chosen
  ok "xray Reality running on TCP $REALITY_PORT, SNI $REALITY_SNI"
}

hy2_selftest() {
  local cfg sp pid code
  cfg=$(mktmp .yaml); sp=$(shuf -i 10000-19999 -n 1)
  cat > "$cfg" <<EOF
server: 127.0.0.1:$HY2_PORT
auth: $(yaml_sq "$HY2_PASSWORD")
tls:
  sni: $HY2_SNI
  insecure: true
  pinSHA256: $HY2_PIN
socks5:
  listen: 127.0.0.1:$sp
EOF
  hysteria client -c "$cfg" >/dev/null 2>&1 & pid=$!; BG_PIDS+=("$pid")
  sleep 2
  code=$(curl -s -o /dev/null -m 12 -w '%{http_code}' -x "socks5h://127.0.0.1:$sp" "$TEST_URL" || true)
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  if [ "$code" = 204 ]; then ok "Hysteria2 self-test passed"; else warn "Hysteria2 self-test failed (HTTP $code)"; fi
}

setup_ufw() {
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
    log "ufw is active — opening ports"
    local rules="$REALITY_PORT/tcp $HY2_PORT/udp" r
    [ "${NO_HOP:-0}" != 1 ] && rules+=" ${HOP_RANGE/-/:}/udp"
    for r in $rules; do ufw allow "$r" >/dev/null && log "  ufw allow $r"; done
    UFW_RULES=$rules
  else
    log "ufw not active — host firewall left untouched"
  fi
}

# ----------------------------------------------------------------------------- output
emit_client() {
  [ -r "$STATE_FILE" ] || die "no state found; run install first"
  load_state quiet
  [ -s "$HY_DIR/cert.crt" ] || die "missing $HY_DIR/cert.crt"
  HY2_PIN=$(openssl x509 -in "$HY_DIR/cert.crt" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')
  XRAY_PUB=$(xray x25519 -i "$XRAY_PRIV" | grep -iE '^(public key|password)' | head -1 | awk -F': *' '{print $2}')
  local ip4 ip6 pwq hop
  ip4=${SERVER_ADDR:-$(detect_ip 4)}; ip6=$(detect_ip 6)
  [ -n "$ip4" ] || { ip4=$ip6; ip6=''; }
  [ -n "$ip4" ] || die "could not detect public IP; set SERVER_ADDR"
  pwq=$(urlencode "$HY2_PASSWORD"); hop=$HOP_RANGE
  mkdir -p "$OUT_DIR/qr"; chmod 700 "$OUT_DIR"

  local -a names=() links=()
  mk_links() {  # mk_links HOST(for URI) SUFFIX
    local h=$1 s=$2
    names+=("$NODE_NAME-Reality$s")
    links+=("vless://$XRAY_UUID@$h:$REALITY_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$REALITY_SNI&fp=chrome&pbk=$XRAY_PUB&sid=$XRAY_SID&type=tcp&headerType=none#$NODE_NAME-Reality$s")
    names+=("$NODE_NAME-Hy2$s")
    links+=("hysteria2://$pwq@$h:$HY2_PORT/?sni=$HY2_SNI&insecure=1&pinSHA256=$HY2_PIN#$NODE_NAME-Hy2$s")
    if [ "${NO_HOP:-0}" != 1 ]; then
      names+=("$NODE_NAME-Hy2-Hop$s")
      links+=("hysteria2://$pwq@$h:$HY2_PORT,$hop/?sni=$HY2_SNI&insecure=1&pinSHA256=$HY2_PIN#$NODE_NAME-Hy2-Hop$s")
      names+=("$NODE_NAME-Hy2-Hop-mport$s")
      links+=("hysteria2://$pwq@$h:$HY2_PORT/?mport=$hop&sni=$HY2_SNI&insecure=1&pinSHA256=$HY2_PIN#$NODE_NAME-Hy2-Hop-mport$s")
    fi
  }
  local h4=$ip4; [[ $ip4 == *:* ]] && h4="[$ip4]"
  mk_links "$h4" ""
  [ -n "$ip6" ] && mk_links "[$ip6]" "-v6"

  local i txt="$OUT_DIR/links.txt"
  {
    echo "# $NODE_NAME — generated $(date -u '+%F %T UTC') by deploy-proxy.sh — contains secrets"
    echo "# Hysteria2 cert is self-signed (CN/SAN $HY2_SNI) and pinned via pinSHA256=$HY2_PIN"
    echo "# (insecure=1 only skips CA validation; a wrong cert is still rejected by the pin)"
    for i in "${!links[@]}"; do printf '\n# %s\n%s\n' "${names[$i]}" "${links[$i]}"; done
  } > "$txt"
  for i in "${!links[@]}"; do qrencode -o "$OUT_DIR/qr/${names[$i]}.png" -s 8 -m 2 "${links[$i]}"; done

  # ---- mihomo / Clash Meta
  local yml="$OUT_DIR/clash-meta.yaml" hopline='' pnames="      - $NODE_NAME-Reality"$'\n'"      - $NODE_NAME-Hy2"
  [ "${NO_HOP:-0}" != 1 ] && hopline="    ports: $hop"$'\n'"    hop-interval: 30"
  {
    cat <<EOF
# mihomo / Clash Meta — $NODE_NAME (generated by deploy-proxy.sh, contains secrets)
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: true

proxies:
EOF
    yml_px() {  # yml_px SERVER SUFFIX
      cat <<EOF
  - name: $NODE_NAME-Reality$2
    type: vless
    server: $1
    port: $REALITY_PORT
    uuid: $XRAY_UUID
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: $REALITY_SNI
    client-fingerprint: chrome
    reality-opts:
      public-key: $XRAY_PUB
      short-id: $XRAY_SID

  - name: $NODE_NAME-Hy2$2
    type: hysteria2
    server: $1
    port: $HY2_PORT
${hopline:+$hopline
}    password: $(yaml_sq "$HY2_PASSWORD")
    sni: $HY2_SNI
    skip-cert-verify: false
    fingerprint: $HY2_PIN
    alpn:
      - h3

EOF
    }
    yml_px "$ip4" ""
    if [ -n "$ip6" ]; then yml_px "$ip6" "-v6"; pnames+=$'\n'"      - $NODE_NAME-Reality-v6"$'\n'"      - $NODE_NAME-Hy2-v6"; fi
    cat <<EOF
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - AUTO
      - FALLBACK
$pnames
      - DIRECT
  - name: AUTO
    type: url-test
    proxies:
$pnames
    url: $TEST_URL
    interval: 300
    tolerance: 80
  - name: FALLBACK
    type: fallback
    proxies:
$pnames
    url: $TEST_URL
    interval: 120

rules:
  - GEOIP,LAN,DIRECT,no-resolve
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
EOF
  } > "$yml"
  chmod 600 "$txt" "$yml" "$OUT_DIR"/qr/*.png

  # ---- terminal output
  echo
  echo "=================================================================="
  echo " $NODE_NAME   IPv4: ${ip4}   IPv6: ${ip6:-none}"
  echo " Reality : TCP $REALITY_PORT  SNI $REALITY_SNI"
  echo " Hy2     : UDP $HY2_PORT$([ "${NO_HOP:-0}" != 1 ] && echo "  hop $HOP_RANGE")  pinSHA256 $HY2_PIN"
  echo "=================================================================="
  for i in "${!links[@]}"; do
    [[ ${names[$i]} == *-v6 ]] && continue
    printf '\n%s%s%s\n%s\n' "$c_g" "${names[$i]}" "$c_0" "${links[$i]}"
    case ${names[$i]} in *-mport) ;; *) qrencode -t ansiutf8 -m 1 "${links[$i]}" ;; esac
  done
  [ -n "$ip6" ] && echo && echo "(IPv6 variants are in $txt)"
  echo
  ok "client files: $txt, $yml, $OUT_DIR/qr/"
  warn "Remember to also open TCP $REALITY_PORT and UDP $HY2_PORT$([ "${NO_HOP:-0}" != 1 ] && echo " + UDP $HOP_RANGE") in your provider's cloud firewall / security group."
  [ "$REALITY_PORT" = 443 ] || warn "Reality listens on TCP $REALITY_PORT, not 443 (443 busy or overridden); non-443 Reality ports are somewhat easier to flag."
}

# ----------------------------------------------------------------------------- uninstall
uninstall() {
  preflight
  load_state
  log "uninstalling"
  if [ -x "$PORTHOP_SCRIPT" ]; then "$PORTHOP_SCRIPT" down || true; fi
  systemctl disable --now hy2-porthop.service >/dev/null 2>&1 || true
  rm -f "$PORTHOP_UNIT" "$PORTHOP_SCRIPT"
  if command -v hysteria >/dev/null || [ -d "$HY_DIR" ]; then
    systemctl disable --now hysteria-server.service >/dev/null 2>&1 || true
    fetch_run "$HY2_INSTALL_URL" --remove >/dev/null 2>&1 || warn "hysteria official remove failed; removing manually"
    rm -f /usr/local/bin/hysteria /etc/systemd/system/hysteria-server.service /etc/systemd/system/hysteria-server@.service
    rm -rf "$HY_DIR" /var/lib/hysteria
    userdel hysteria >/dev/null 2>&1 || true
  fi
  if command -v xray >/dev/null || [ -f "$XRAY_CONF" ]; then
    fetch_run "$XRAY_INSTALL_URL" remove --purge >/dev/null 2>&1 || warn "xray official remove failed"
  fi
  if [ -n "${UFW_RULES:-}" ] && command -v ufw >/dev/null; then
    local r; for r in $UFW_RULES; do ufw delete allow "$r" >/dev/null 2>&1 || true; done
  fi
  if [ "${KEEP_BBR:-0}" != 1 ] && [ -f "$SYSCTL_FILE" ]; then
    rm -f "$SYSCTL_FILE" "$MODLOAD_FILE"
    sysctl -w net.ipv4.tcp_congestion_control=cubic net.core.default_qdisc=fq_codel \
              net.core.rmem_max=212992 net.core.wmem_max=212992 >/dev/null 2>&1 || true
    sysctl --system >/dev/null 2>&1 || true
  fi
  systemctl daemon-reload
  rm -rf "$STATE_DIR" "$OUT_DIR"
  ok "uninstalled (apt packages such as curl/qrencode were left in place)"
}

# ----------------------------------------------------------------------------- main
usage() {
  cat <<'EOF'
Usage: bash deploy-proxy.sh [--show | --uninstall | --help]
  (no option)   install / re-run (reuses saved credentials in /etc/proxy-deploy/state.env)
  --show        re-print client links / QR codes, rewrite /root/proxy-client/
  --uninstall   remove Xray, Hysteria2, port hopping, BBR tuning (KEEP_BBR=1 to keep), state
Env: NODE_NAME SERVER_ADDR HY2_PASSWORD HY2_PORT HOP_RANGE NO_HOP=1 REALITY_PORT REALITY_SNI KEEP_BBR=1
EOF
}

main() {
  case "${1:-}" in
    --uninstall) uninstall; exit 0 ;;
    --show) preflight; emit_client; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    '') ;;
    *) die "unknown option: $1 (use --help)" ;;
  esac
  preflight
  load_state
  validate_inputs
  install_pkgs
  setup_bbr
  pick_hy2_port
  pick_reality_port
  warn_hop_conflicts
  install_hysteria
  setup_hy2_cert
  configure_hysteria
  setup_porthop
  install_xray
  configure_xray
  hy2_selftest
  setup_ufw
  SERVER_ADDR=${SERVER_ADDR:-}
  save_state
  emit_client
}
main "$@"
