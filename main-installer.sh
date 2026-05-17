#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then echo "Run as root"; exit 1; fi
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
trap restore_apt_auto_updates EXIT


REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/drmmya/OpenVPN-OpenConnect-V2rayInstaller/main}"
INSTALLER_DIR="/root/vpn-installer"
mkdir -p "$INSTALLER_DIR/panel-admin"

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
LOCAL_DIR=""
if [[ -f "$SCRIPT_PATH" ]]; then LOCAL_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"; fi

fetch_file(){
  local remote="$1" dest="$2"
  if [[ -n "$LOCAL_DIR" && -f "$LOCAL_DIR/$remote" ]]; then
    mkdir -p "$(dirname "$dest")"; cp "$LOCAL_DIR/$remote" "$dest"
  else
    mkdir -p "$(dirname "$dest")"; curl -fsSL "$REPO_RAW/$remote" -o "$dest"
  fi
}

ROOT_FILES=(setup-panel-ui.sh install-openvpn.sh install-openconnect.sh install-v2ray.sh vpn-control.sh)
PANEL_FILES=(config.php status_lib.php style.css login.php index.php change_password.php logout.php settings.php servers.php system_control.php system-control.php install_log.php api_status.php openvpn.php openconnect.php v2ray.php README.md api/node_status.php api/multi_status.php assets/multirole.js)

for f in "${ROOT_FILES[@]}"; do fetch_file "$f" "$INSTALLER_DIR/$f"; chmod +x "$INSTALLER_DIR/$f"; done
for f in "${PANEL_FILES[@]}"; do
  fetch_file "panel-admin/$f" "$INSTALLER_DIR/panel-admin/$f"
done

cd "$INSTALLER_DIR"

is_port(){ [[ "${1:-}" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 )); }
validate_choice(){ [[ "$CHOICE" == "0" || "$CHOICE" == "all" || "$CHOICE" =~ ^[1-3](,[1-3])*$ ]]; }
validate_port(){ local name="$1" value="$2"; is_port "$value" || { echo "ERROR: Invalid $name port: $value" >&2; exit 1; }; }
check_duplicate_ports(){
  local seen="" p label
  for label in "$@"; do
    p="${label#*=}"
    [[ ",${seen}," == *",${p},"* ]] && { echo "ERROR: Duplicate selected port: ${p}" >&2; exit 1; }
    seen="${seen},${p}"
  done
}

read -r -p "Select protocols [0/all, 1=OpenVPN, 2=OpenConnect, 3=V2Ray, example 1,2]: " CHOICE || true
CHOICE="${CHOICE:-0}"; CHOICE="${CHOICE// /}"
validate_choice || { echo "ERROR: Invalid protocol selection. Use 0/all or 1,2,3." >&2; exit 1; }
want(){ [[ "$CHOICE" == "0" || "$CHOICE" == "all" || ",$CHOICE," == *",$1,"* ]]; }

ASK_OVPN=0; ASK_OC=0; ASK_V2=0
want 1 && ASK_OVPN=1
want 2 && ASK_OC=1
want 3 && ASK_V2=1

OVPN_UDP_PORT="1194"; OVPN_TCP_PORT="8443"; OC_PORT="443"; V2_PORT="4443"
if [[ "$ASK_OVPN" == "1" ]]; then
  read -r -p "OpenVPN UDP port [1194]: " v || true; OVPN_UDP_PORT="${v:-1194}"
  read -r -p "OpenVPN TCP port [8443]: " v || true; OVPN_TCP_PORT="${v:-8443}"
fi
if [[ "$ASK_OC" == "1" ]]; then read -r -p "OpenConnect TCP/UDP port [443]: " v || true; OC_PORT="${v:-443}"; fi
if [[ "$ASK_V2" == "1" ]]; then read -r -p "V2Ray/Xray port [4443]: " v || true; V2_PORT="${v:-4443}"; fi

PORT_LABELS=()
if [[ "$ASK_OVPN" == "1" ]]; then validate_port "OpenVPN UDP" "$OVPN_UDP_PORT"; validate_port "OpenVPN TCP" "$OVPN_TCP_PORT"; PORT_LABELS+=("OVPN_UDP=$OVPN_UDP_PORT" "OVPN_TCP=$OVPN_TCP_PORT"); fi
if [[ "$ASK_OC" == "1" ]]; then validate_port "OpenConnect" "$OC_PORT"; PORT_LABELS+=("OC=$OC_PORT"); fi
if [[ "$ASK_V2" == "1" ]]; then validate_port "V2Ray" "$V2_PORT"; PORT_LABELS+=("V2=$V2_PORT"); fi
[[ ${#PORT_LABELS[@]} -gt 0 ]] && check_duplicate_ports "${PORT_LABELS[@]}"

export OVPN_UDP_PORT OVPN_TCP_PORT OC_PORT V2_PORT
export PANEL_DIR="/var/www/html/panel-admin"
export PANEL_ALIAS="vpn-panel"
export ADMIN_USER="${ADMIN_USER:-openvpn}"
export ADMIN_PASS="${ADMIN_PASS:-Easin112233@}"
export DEFAULT_USER="${DEFAULT_USER:-Easin}"
export DEFAULT_USER_PASS="${DEFAULT_USER_PASS:-Easin112233@}"

cleanup_old_install(){
  echo "[MAIN] Cleaning old VPN install if present..."
  OLD_OVPN_UDP_PORT="1194"; OLD_OVPN_TCP_PORT="8443"; OLD_OC_PORT="443"; OLD_V2_PORT="4443"
  if [[ -f /etc/vpn-protocols.conf ]]; then
    OLD_OVPN_UDP_PORT="$(grep -E '^OVPN_UDP_PORT=' /etc/vpn-protocols.conf | tail -1 | cut -d= -f2 || true)"; OLD_OVPN_UDP_PORT="${OLD_OVPN_UDP_PORT:-1194}"
    OLD_OVPN_TCP_PORT="$(grep -E '^OVPN_TCP_PORT=' /etc/vpn-protocols.conf | tail -1 | cut -d= -f2 || true)"; OLD_OVPN_TCP_PORT="${OLD_OVPN_TCP_PORT:-8443}"
    OLD_OC_PORT="$(grep -E '^OC_PORT=' /etc/vpn-protocols.conf | tail -1 | cut -d= -f2 || true)"; OLD_OC_PORT="${OLD_OC_PORT:-443}"
    OLD_V2_PORT="$(grep -E '^V2_PORT=' /etc/vpn-protocols.conf | tail -1 | cut -d= -f2 || true)"; OLD_V2_PORT="${OLD_V2_PORT:-4443}"
  fi
  systemctl stop openvpn-server@server-udp openvpn-server@server-tcp ovpn-iptables.service vpn-iptables.service ocserv xray apache2 2>/dev/null || true
  systemctl disable openvpn-server@server-udp openvpn-server@server-tcp ovpn-iptables.service vpn-iptables.service ocserv xray 2>/dev/null || true
  rm -rf /var/www/html/ovpn-admin /var/www/html/panel-admin /etc/openvpn/pki-webadmin /root/easy-rsa
  rm -f /etc/openvpn/server/server-udp.conf /etc/openvpn/server/server-tcp.conf
  rm -f /etc/ocserv/ocserv.conf /etc/ocserv/ocpasswd; rm -rf /etc/ocserv/ssl
  rm -f /usr/local/etc/xray/config.json /etc/xray/config.json
  rm -f /etc/systemd/system/ovpn-iptables.service /etc/systemd/system/vpn-iptables.service
  rm -f /usr/local/bin/ovpn-auth.php /usr/local/bin/ovpn-log-event.php /usr/local/bin/ovpn-make-profile.sh /usr/local/bin/ovpn-user-manage.sh /usr/local/bin/ovpn-kill-user.sh /usr/local/bin/ovpn-iptables-apply.sh /usr/local/bin/vpn-iptables-apply.sh
  rm -f /usr/local/bin/oc-user-manage.sh /usr/local/bin/oc-event-log.sh /usr/local/bin/oc-active-sessions.sh
  rm -f /etc/vpn-protocols.conf
  rm -f /var/log/openvpn/server-udp.log /var/log/openvpn/server-tcp.log /var/log/openvpn/openvpn-status-udp.log /var/log/openvpn/openvpn-status-tcp.log /var/log/openvpn/ipp-udp.txt /var/log/openvpn/ipp-tcp.txt
  for p in "$OLD_OVPN_UDP_PORT" 1194; do while iptables -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null; do :; done; done
  for p in "$OLD_OVPN_TCP_PORT" 8443; do while iptables -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; do :; done; done
  for p in "$OLD_OC_PORT" 443 444; do while iptables -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; do :; done; while iptables -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null; do :; done; done
  for p in "$OLD_V2_PORT" 4443; do while iptables -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; do :; done; done
  systemctl daemon-reload || true
}

wait_for_apt_ready
cleanup_old_install

echo "[MAIN] Setting up panel..."
bash ./setup-panel-ui.sh

INSTALLED_OPENVPN=0; INSTALLED_OPENCONNECT=0; INSTALLED_V2RAY=0
if [[ "$ASK_OVPN" == "1" ]]; then bash ./install-openvpn.sh; INSTALLED_OPENVPN=1; fi
if [[ "$ASK_OC" == "1" ]]; then bash ./install-openconnect.sh; INSTALLED_OPENCONNECT=1; fi
if [[ "$ASK_V2" == "1" ]]; then bash ./install-v2ray.sh; INSTALLED_V2RAY=1; fi

cat >/etc/vpn-protocols.conf <<EOF
OPENVPN=$INSTALLED_OPENVPN
OPENCONNECT=$INSTALLED_OPENCONNECT
V2RAY=$INSTALLED_V2RAY
OVPN_UDP_PORT=$OVPN_UDP_PORT
OVPN_TCP_PORT=$OVPN_TCP_PORT
OC_PORT=$OC_PORT
V2_PORT=$V2_PORT
EOF
chmod 644 /etc/vpn-protocols.conf
/usr/local/bin/vpn-control.sh refresh-firewall >/dev/null 2>&1 || true

SERVER_ADDR="$(curl -4 -fsSL https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
if [[ "$INSTALLED_OPENVPN" == "1" && -x /usr/local/bin/ovpn-user-manage.sh && -f "$PANEL_DIR/data/vpn.sqlite" ]]; then
  sqlite3 "$PANEL_DIR/data/vpn.sqlite" "SELECT username FROM ovpn_users" 2>/dev/null | while read -r u; do
    [[ -n "$u" ]] && SERVER_ADDR_OVERRIDE="$SERVER_ADDR" /usr/local/bin/ovpn-user-manage.sh regen "$u" >/dev/null 2>&1 || true
  done
fi
echo
echo "=============================================="
echo "Installation completed"
echo "=============================================="
[[ "$INSTALLED_OPENVPN" == "1" ]] && echo "OpenVPN UDP = $OVPN_UDP_PORT" && echo "OpenVPN TCP = $OVPN_TCP_PORT"
[[ "$INSTALLED_OPENCONNECT" == "1" ]] && echo "OpenConnect = $OC_PORT"
[[ "$INSTALLED_V2RAY" == "1" ]] && echo "V2Ray/Xray = $V2_PORT"
echo "Admin URL = http://${SERVER_ADDR}/vpn-panel"
echo "Admin user = ${ADMIN_USER}"
echo "Admin pass = ${ADMIN_PASS}"
echo "Default VPN user = ${DEFAULT_USER}"
echo "Default VPN pass = ${DEFAULT_USER_PASS}"
echo "=============================================="
