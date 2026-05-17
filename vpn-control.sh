#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Temporarily stop Ubuntu/Debian auto-updates and wait for apt/dpkg locks.
apt_lock_pids(){
  command -v fuser >/dev/null 2>&1 || return 0
  fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock 2>/dev/null | tr ' ' '\n' | awk 'NF' | sort -u
}
stop_apt_auto_updates(){
  command -v systemctl >/dev/null 2>&1 || return 0
  echo "[APT] Temporarily stopping apt-daily/unattended-upgrades during installer..."
  systemctl stop apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service unattended-upgrades.service 2>/dev/null || true
}
restore_apt_auto_updates(){
  [[ "${RESTORE_APT_AUTO_UPDATE:-1}" == "1" ]] || return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl start apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
  systemctl start unattended-upgrades.service 2>/dev/null || true
}
wait_for_apt_ready(){
  stop_apt_auto_updates
  local waited=0 max="${APT_LOCK_WAIT_SECONDS:-300}" pids pid args
  while true; do
    pids="$(apt_lock_pids || true)"
    [[ -z "$pids" ]] && break
    echo "[APT] apt/dpkg lock busy by PID(s): $(echo "$pids" | tr '\n' ' ')"
    for pid in $pids; do
      args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
      if [[ "$args" == *unattended-upgr* || "$args" == *apt.systemd.daily* ]]; then
        if (( waited >= 15 )); then echo "[APT] Asking auto-update PID $pid to stop..."; kill -TERM "$pid" 2>/dev/null || true; fi
        if (( waited >= 60 )); then echo "[APT] Force-stopping stuck auto-update PID $pid..."; kill -KILL "$pid" 2>/dev/null || true; fi
      fi
    done
    if (( waited >= max )); then echo "ERROR: apt/dpkg lock did not release after ${max}s. Try again later." >&2; exit 100; fi
    sleep 5; waited=$((waited+5))
  done
  dpkg --configure -a >/dev/null 2>&1 || true
}
apt_update_install(){
  wait_for_apt_ready
  apt-get update >/dev/null
  wait_for_apt_ready
  apt-get install -y "$@" >/dev/null
}


ACTION="${1:-}"
PROTO="${2:-}"
PORT1="${3:-}"
PORT2="${4:-}"
CONF="/etc/vpn-protocols.conf"
INSTALLER_DIR="${INSTALLER_DIR:-/root/vpn-installer}"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/drmmya/OpenVPN-OpenConnect-V2rayInstaller/main}"
PANEL_DIR="/var/www/html/panel-admin"
trap 'rc=$?; restore_apt_auto_updates; if [[ "${ACTION:-}" == "install" && $rc -ne 0 ]]; then echo "===== ${PROTO:-protocol} INSTALL FAILED (exit code $rc) =====" >&2; fi' EXIT

fail(){ echo "$(date '+[%Y-%m-%d %H:%M:%S]') ERROR: $*" >&2; exit 1; }
info(){ echo "$(date '+[%Y-%m-%d %H:%M:%S]') $*"; }
is_port(){ [[ "${1:-}" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 )); }
get_conf(){ local k="$1" d="${2:-}"; [[ -f "$CONF" ]] && grep -E "^${k}=" "$CONF" | tail -1 | cut -d= -f2- || printf '%s' "$d"; }
set_conf(){ local k="$1" v="$2"; touch "$CONF"; if grep -qE "^${k}=" "$CONF"; then sed -i "s|^${k}=.*|${k}=${v}|" "$CONF"; else echo "${k}=${v}" >> "$CONF"; fi; chmod 644 "$CONF"; }
port_in_use(){ local port="$1" proto="${2:-any}"; case "$proto" in tcp) ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$" ;; udp) ss -H -lun 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$" ;; *) ss -H -ltun 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$" ;; esac; }
ensure_free(){ local p="$1" current="${2:-}" proto="${3:-any}"; is_port "$p" || fail "Invalid port: $p"; if [[ "$p" != "$current" ]] && port_in_use "$p" "$proto"; then fail "Port $p/$proto already used. Choose another port."; fi; }
allow_tcp(){ iptables -C INPUT -p tcp --dport "$1" -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport "$1" -j ACCEPT; }
allow_udp(){ iptables -C INPUT -p udp --dport "$1" -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport "$1" -j ACCEPT; }

ensure_script(){
  local f="$1"
  mkdir -p "$INSTALLER_DIR"
  if [[ ! -f "$INSTALLER_DIR/$f" ]]; then
    curl -fsSL "$REPO_RAW/$f" -o "$INSTALLER_DIR/$f" || fail "$f not found locally and download failed"
    chmod +x "$INSTALLER_DIR/$f"
  fi
  bash -n "$INSTALLER_DIR/$f" || fail "$f has syntax error"
}

net_iface(){ ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true; }
write_firewall_service(){
  local iface; iface="$(net_iface)"; iface="${iface:-eth0}"
  cat >/usr/local/bin/vpn-iptables-apply.sh <<RULES
#!/usr/bin/env bash
set -e
CONF="/etc/vpn-protocols.conf"
OPENVPN=0; OPENCONNECT=0; V2RAY=0
OVPN_UDP_PORT=1194; OVPN_TCP_PORT=8443; OC_PORT=443; V2_PORT=4443
[[ -f "\$CONF" ]] && . "\$CONF" || true
allow_tcp(){ iptables -C INPUT -p tcp --dport "\$1" -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport "\$1" -j ACCEPT; }
allow_udp(){ iptables -C INPUT -p udp --dport "\$1" -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport "\$1" -j ACCEPT; }
masq(){ iptables -t nat -C POSTROUTING -s "\$1" -o ${iface} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s "\$1" -o ${iface} -j MASQUERADE; }
fw_s(){ iptables -C FORWARD -s "\$1" -j ACCEPT 2>/dev/null || iptables -A FORWARD -s "\$1" -j ACCEPT; }
fw_d(){ iptables -C FORWARD -d "\$1" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -A FORWARD -d "\$1" -m state --state ESTABLISHED,RELATED -j ACCEPT; }
if [[ "\${OPENVPN}" == "1" ]]; then
  masq 10.8.0.0/24; masq 10.9.0.0/24
  fw_s 10.8.0.0/24; fw_d 10.8.0.0/24; fw_s 10.9.0.0/24; fw_d 10.9.0.0/24
  allow_udp "\${OVPN_UDP_PORT}"; allow_tcp "\${OVPN_TCP_PORT}"
fi
if [[ "\${OPENCONNECT}" == "1" ]]; then
  masq 10.20.30.0/24; fw_s 10.20.30.0/24; fw_d 10.20.30.0/24
  allow_tcp "\${OC_PORT}"; allow_udp "\${OC_PORT}"
fi
if [[ "\${V2RAY}" == "1" ]]; then
  allow_tcp "\${V2_PORT}"
fi
allow_tcp 80
RULES
  chmod +x /usr/local/bin/vpn-iptables-apply.sh
  cat >/etc/systemd/system/vpn-iptables.service <<'UNIT'
[Unit]
Description=Apply VPN iptables rules
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/vpn-iptables-apply.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload || true
  systemctl enable vpn-iptables.service >/dev/null 2>&1 || true
  systemctl restart vpn-iptables.service >/dev/null 2>&1 || /usr/local/bin/vpn-iptables-apply.sh || true
}

active_openvpn(){ systemctl is-active --quiet openvpn-server@server-udp || systemctl is-active --quiet openvpn-server@server-tcp; }
active_openconnect(){ systemctl is-active --quiet ocserv; }
active_v2ray(){ systemctl is-active --quiet xray; }
verify_state(){
  local proto="$1" want="$2"
  case "$proto:$want" in
    openvpn:active) active_openvpn || fail "OpenVPN did not start/restart" ;;
    openvpn:inactive) ! active_openvpn || fail "OpenVPN did not stop" ;;
    openconnect:active) active_openconnect || fail "OpenConnect did not start/restart" ;;
    openconnect:inactive) ! active_openconnect || fail "OpenConnect did not stop" ;;
    v2ray:active|xray:active) active_v2ray || fail "V2Ray/Xray did not start/restart" ;;
    v2ray:inactive|xray:inactive) ! active_v2ray || fail "V2Ray/Xray did not stop" ;;
  esac
}
svc_start(){ case "$1" in openvpn) systemctl start openvpn-server@server-udp openvpn-server@server-tcp; verify_state openvpn active ;; openconnect) systemctl start ocserv; verify_state openconnect active ;; v2ray|xray) systemctl start xray; verify_state v2ray active ;; *) fail "Unknown protocol: $1" ;; esac; }
svc_stop(){ case "$1" in openvpn) systemctl stop openvpn-server@server-udp openvpn-server@server-tcp 2>/dev/null || true; verify_state openvpn inactive ;; openconnect) systemctl stop ocserv 2>/dev/null || true; verify_state openconnect inactive ;; v2ray|xray) systemctl stop xray 2>/dev/null || true; verify_state v2ray inactive ;; *) fail "Unknown protocol: $1" ;; esac; }
svc_restart(){ write_firewall_service; case "$1" in openvpn) systemctl restart openvpn-server@server-udp openvpn-server@server-tcp; verify_state openvpn active ;; openconnect) systemctl restart ocserv; verify_state openconnect active ;; v2ray|xray) systemctl restart xray; verify_state v2ray active ;; *) fail "Unknown protocol: $1" ;; esac; }

write_ovpn_profile_generator(){
  cat >/usr/local/bin/ovpn-make-profile.sh <<'MKPROFILE'
#!/usr/bin/env bash
set -euo pipefail
USER_NAME="${1:?username required}"
SERVER_ADDR="${2:?server addr required}"
[[ "$USER_NAME" =~ ^[A-Za-z0-9._-]{3,32}$ ]] || { echo "Invalid username" >&2; exit 1; }
CONF="/etc/vpn-protocols.conf"
ENV_OVPN_UDP_PORT="${OVPN_UDP_PORT:-}"
ENV_OVPN_TCP_PORT="${OVPN_TCP_PORT:-}"
OVPN_UDP_PORT=1194
OVPN_TCP_PORT=8443
if [[ -f "$CONF" ]]; then
  # shellcheck disable=SC1090
  source "$CONF" || true
fi
[[ -n "$ENV_OVPN_UDP_PORT" ]] && OVPN_UDP_PORT="$ENV_OVPN_UDP_PORT"
[[ -n "$ENV_OVPN_TCP_PORT" ]] && OVPN_TCP_PORT="$ENV_OVPN_TCP_PORT"
OUT_DIR="/var/www/html/panel-admin/downloads"
PKI_DIR="/etc/openvpn/pki-webadmin"
mkdir -p "$OUT_DIR"
chown root:www-data "$OUT_DIR" 2>/dev/null || true
chmod 775 "$OUT_DIR" 2>/dev/null || true
TMP_FILE="$(mktemp "$OUT_DIR/.${USER_NAME}.XXXXXX")"
cat >"$TMP_FILE" <<PROFILE
client
dev tun
nobind
persist-key
persist-tun
auth-user-pass
auth-nocache
remote ${SERVER_ADDR} ${OVPN_UDP_PORT} udp
remote ${SERVER_ADDR} ${OVPN_TCP_PORT} tcp-client
remote-random
resolv-retry infinite
remote-cert-tls server
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-CBC
auth SHA256
verb 3
pull
push-peer-info
setenv UV_PROFILE_USER ${USER_NAME}
<ca>
$(cat "$PKI_DIR/ca.crt")
</ca>
<tls-crypt>
$(cat "$PKI_DIR/ta.key")
</tls-crypt>
PROFILE
chmod 664 "$TMP_FILE" 2>/dev/null || true
chown root:www-data "$TMP_FILE" 2>/dev/null || true
mv -f "$TMP_FILE" "$OUT_DIR/$USER_NAME.ovpn"
chmod 664 "$OUT_DIR/$USER_NAME.ovpn" 2>/dev/null || true
chown root:www-data "$OUT_DIR/$USER_NAME.ovpn" 2>/dev/null || true
MKPROFILE
  chmod +x /usr/local/bin/ovpn-make-profile.sh
}
regen_ovpn_profiles(){
  local server
  server="$(curl -4 -fsSL https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
  if [[ -x /usr/local/bin/ovpn-user-manage.sh && -f "$PANEL_DIR/data/vpn.sqlite" ]]; then
    sqlite3 "$PANEL_DIR/data/vpn.sqlite" "SELECT username FROM ovpn_users" 2>/dev/null | while read -r u; do
      [[ -n "$u" ]] && SERVER_ADDR_OVERRIDE="$server" /usr/local/bin/ovpn-user-manage.sh regen "$u"
    done
  fi
}

change_openvpn_ports(){
  local udp="$1" tcp="$2" old_udp old_tcp
  old_udp="$(get_conf OVPN_UDP_PORT 1194)"; old_tcp="$(get_conf OVPN_TCP_PORT 8443)"
  ensure_free "$udp" "$old_udp" udp; ensure_free "$tcp" "$old_tcp" tcp
  [[ "$udp" != "$tcp" ]] || fail "OpenVPN UDP and TCP ports cannot be same"
  [[ -f /etc/openvpn/server/server-udp.conf ]] || fail "OpenVPN UDP config not found"
  [[ -f /etc/openvpn/server/server-tcp.conf ]] || fail "OpenVPN TCP config not found"
  sed -i "s/^port .*/port ${udp}/" /etc/openvpn/server/server-udp.conf
  sed -i "s/^port .*/port ${tcp}/" /etc/openvpn/server/server-tcp.conf
  set_conf OPENVPN 1; set_conf OVPN_UDP_PORT "$udp"; set_conf OVPN_TCP_PORT "$tcp"
  allow_udp "$udp"; allow_tcp "$tcp"; write_firewall_service; write_ovpn_profile_generator
  svc_restart openvpn
  regen_ovpn_profiles
  info "OpenVPN ports changed: UDP=$udp TCP=$tcp"
}
change_openconnect_port(){
  local port="$1" old
  old="$(get_conf OC_PORT 443)"; ensure_free "$port" "$old" any
  [[ -f /etc/ocserv/ocserv.conf ]] || fail "OpenConnect config not found"
  sed -i -E "s/^tcp-port = .*/tcp-port = ${port}/; s/^udp-port = .*/udp-port = ${port}/" /etc/ocserv/ocserv.conf
  set_conf OPENCONNECT 1; set_conf OC_PORT "$port"
  allow_tcp "$port"; allow_udp "$port"; write_firewall_service
  svc_restart openconnect
  info "OpenConnect port changed: $port"
}
change_v2ray_port(){
  local port="$1" old cfg
  old="$(get_conf V2_PORT 4443)"; ensure_free "$port" "$old" tcp
  if [[ -f /usr/local/etc/xray/config.json ]]; then cfg="/usr/local/etc/xray/config.json"; elif [[ -f /etc/xray/config.json ]]; then cfg="/etc/xray/config.json"; else fail "Xray config not found"; fi
  command -v python3 >/dev/null 2>&1 || fail "python3 not found. Run: apt-get install -y python3"
  python3 - <<PY
import json
path = "${cfg}"
port = int("${port}")
with open(path) as f:
    data = json.load(f)
if data.get("inbounds"):
    data["inbounds"][0]["port"] = port
with open(path, "w") as f:
    json.dump(data, f, indent=2)
PY
  set_conf V2RAY 1; set_conf V2_PORT "$port"
  [[ -f "$PANEL_DIR/data/v2ray.env" ]] && sed -i "s/^V2_PORT=.*/V2_PORT=${port}/" "$PANEL_DIR/data/v2ray.env" || true
  allow_tcp "$port"; write_firewall_service; svc_restart v2ray
  info "V2Ray/Xray port changed: $port"
}

install_protocol(){
  local proto="$1"
  exec 8>/run/vpn-panel-install.lock
  flock -n 8 || fail "Another protocol install is already running. Wait until it finishes, then try again."
  wait_for_apt_ready
  local label="$proto"
  case "$proto" in
    openvpn) label="OpenVPN" ;;
    openconnect) label="OpenConnect" ;;
    v2ray|xray) label="V2Ray/Xray" ;;
  esac
  info "============================================================"
  info "$label INSTALL STARTED FROM ADMIN PANEL"
  info "Please wait. Do not close/reload while packages are installing."
  info "============================================================"
  case "$proto" in
    openvpn)
      local udp="${2:-1194}" tcp="${3:-8443}"
      info "Checking OpenVPN ports: UDP ${udp}, TCP ${tcp}"
      [[ "$udp" != "$tcp" ]] || fail "OpenVPN UDP and TCP ports cannot be same"
      ensure_free "$udp" "$(get_conf OVPN_UDP_PORT '')" udp; ensure_free "$tcp" "$(get_conf OVPN_TCP_PORT '')" tcp
      ensure_script install-openvpn.sh
      export PANEL_DIR OVPN_UDP_PORT="$udp" OVPN_TCP_PORT="$tcp"
      info "Running OpenVPN installer script..."
      bash "$INSTALLER_DIR/install-openvpn.sh"
      info "Saving OpenVPN protocol config..."
      set_conf OPENVPN 1; set_conf OVPN_UDP_PORT "$udp"; set_conf OVPN_TCP_PORT "$tcp"
      info "Refreshing firewall service and regenerating OpenVPN client profiles..."
      write_ovpn_profile_generator; write_firewall_service; regen_ovpn_profiles
      verify_state openvpn active
      info "OpenVPN service active. UDP=${udp}, TCP=${tcp}" ;;
    openconnect)
      local port="${2:-443}"
      info "Checking OpenConnect port: ${port}"
      ensure_free "$port" "$(get_conf OC_PORT '')" any
      ensure_script install-openconnect.sh
      export PANEL_DIR OC_PORT="$port"
      info "Running OpenConnect installer script..."
      bash "$INSTALLER_DIR/install-openconnect.sh"
      info "Saving OpenConnect protocol config..."
      set_conf OPENCONNECT 1; set_conf OC_PORT "$port"; write_firewall_service
      verify_state openconnect active
      info "OpenConnect service active. Port=${port}" ;;
    v2ray|xray)
      local port="${2:-4443}"
      info "Checking V2Ray/Xray port: ${port}"
      ensure_free "$port" "$(get_conf V2_PORT '')" tcp
      ensure_script install-v2ray.sh
      export PANEL_DIR V2_PORT="$port"
      info "Running V2Ray/Xray installer script..."
      bash "$INSTALLER_DIR/install-v2ray.sh"
      info "Saving V2Ray/Xray protocol config..."
      set_conf V2RAY 1; set_conf V2_PORT "$port"; write_firewall_service
      verify_state v2ray active
      info "V2Ray/Xray service active. Port=${port}" ;;
    *) fail "Unknown protocol: $proto" ;;
  esac
  info "============================================================"
  info "$label INSTALL SUCCESSFULLY COMPLETED"
  info "You can restart $label from Admin Panel if needed."
  info "============================================================"
}

case "$ACTION" in
  start) svc_start "$PROTO"; info "Started $PROTO" ;;
  stop) svc_stop "$PROTO"; info "Stopped $PROTO" ;;
  restart) svc_restart "$PROTO"; info "Restarted $PROTO" ;;
  status) case "$PROTO" in openvpn) active_openvpn ;; openconnect) active_openconnect ;; v2ray|xray) active_v2ray ;; *) fail "Unknown protocol: $PROTO" ;; esac ;;
  install) install_protocol "$PROTO" "$PORT1" "$PORT2" ;;
  change-port) case "$PROTO" in openvpn) change_openvpn_ports "$PORT1" "$PORT2" ;; openconnect) change_openconnect_port "$PORT1" ;; v2ray|xray) change_v2ray_port "$PORT1" ;; *) fail "Unknown protocol: $PROTO" ;; esac ;;
  refresh-firewall) write_firewall_service; info "Firewall rules refreshed" ;;
  regen-openvpn-profiles) write_ovpn_profile_generator; regen_ovpn_profiles; info "OpenVPN profiles regenerated" ;;
  *) echo "Usage: $0 {start|stop|restart|status|install|change-port|refresh-firewall|regen-openvpn-profiles} {openvpn|openconnect|v2ray} [ports]"; exit 1 ;;
esac
