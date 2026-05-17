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

APP_DIR="${PANEL_DIR:-/var/www/html/panel-admin}"
DATA_DIR="$APP_DIR/data"
DOWNLOAD_DIR="$APP_DIR/downloads"
DB_FILE="$DATA_DIR/vpn.sqlite"
ADMIN_USER="${ADMIN_USER:-openvpn}"
ADMIN_PASS="${ADMIN_PASS:-Easin112233@}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

apt_update_install apache2 php libapache2-mod-php php-sqlite3 php-cli sqlite3 curl sudo acl vnstat iproute2 iptables python3 ca-certificates
mkdir -p "$APP_DIR" "$DATA_DIR" "$DOWNLOAD_DIR"

if [[ -d "$SCRIPT_DIR/panel-admin" ]]; then
  cp -a "$SCRIPT_DIR/panel-admin/." "$APP_DIR/"
else
  echo "ERROR: panel-admin source folder missing in $SCRIPT_DIR" >&2
  exit 1
fi

sqlite3 "$DB_FILE" <<'SQL'
CREATE TABLE IF NOT EXISTS admins(id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE NOT NULL, password_hash TEXT NOT NULL, created_at TEXT DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS servers(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, ip_address TEXT NOT NULL, panel_url TEXT NOT NULL, api_token TEXT NOT NULL, role TEXT DEFAULT 'node', enabled INTEGER DEFAULT 1, sort_order INTEGER DEFAULT 0, created_at TEXT DEFAULT CURRENT_TIMESTAMP, updated_at TEXT DEFAULT CURRENT_TIMESTAMP);
CREATE INDEX IF NOT EXISTS idx_servers_enabled ON servers(enabled,sort_order,id);
SQL
ADMIN_HASH="$(php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$ADMIN_PASS")"
sql_escape(){ printf "%s" "$1" | sed "s/'/''/g"; }
sqlite3 "$DB_FILE" "INSERT OR REPLACE INTO admins(username,password_hash) VALUES('$(sql_escape "$ADMIN_USER")','$ADMIN_HASH');"

NODE_TOKEN="$(php -r 'echo bin2hex(random_bytes(32));')"
SERVER_NAME="$(hostname -f 2>/dev/null || hostname)"
sqlite3 "$DB_FILE" "INSERT OR IGNORE INTO settings(key,value) VALUES('panel_role','hybrid');"
sqlite3 "$DB_FILE" "INSERT OR IGNORE INTO settings(key,value) VALUES('node_api_token','$NODE_TOKEN');"
sqlite3 "$DB_FILE" "INSERT OR IGNORE INTO settings(key,value) VALUES('server_name','$(sql_escape "$SERVER_NAME")');"

cat >/etc/apache2/conf-available/vpn-panel.conf <<EOF
Alias /vpn-panel $APP_DIR
<Directory $APP_DIR>
    Options -Indexes +FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>
EOF
a2enconf vpn-panel >/dev/null || true
a2enmod rewrite >/dev/null || true

if [[ -f "$SCRIPT_DIR/vpn-control.sh" ]]; then
  cp "$SCRIPT_DIR/vpn-control.sh" /usr/local/bin/vpn-control.sh
  chmod +x /usr/local/bin/vpn-control.sh
else
  echo "ERROR: vpn-control.sh missing in $SCRIPT_DIR" >&2
  exit 1
fi
bash -n /usr/local/bin/vpn-control.sh

cat >/etc/sudoers.d/vpn-panel-control <<'SUDO'
www-data ALL=(root) NOPASSWD: /usr/local/bin/vpn-control.sh, /usr/local/bin/ovpn-user-manage.sh, /usr/local/bin/ovpn-make-profile.sh, /usr/local/bin/ovpn-kill-user.sh, /usr/local/bin/oc-user-manage.sh, /usr/local/bin/oc-active-sessions.sh
SUDO
chmod 440 /etc/sudoers.d/vpn-panel-control
visudo -cf /etc/sudoers.d/vpn-panel-control >/dev/null

systemctl enable vnstat apache2 >/dev/null 2>&1 || true
systemctl restart vnstat >/dev/null 2>&1 || true

for log in /var/log/vpn-panel-install-openvpn.log /var/log/vpn-panel-install-openconnect.log /var/log/vpn-panel-install-v2ray.log; do
  touch "$log"
  chown www-data:www-data "$log" 2>/dev/null || true
  chmod 664 "$log" 2>/dev/null || true
done
chown -R root:www-data "$APP_DIR"
find "$APP_DIR" -type d -exec chmod 755 {} \;
find "$APP_DIR" -type f -exec chmod 644 {} \;
chown -R www-data:www-data "$DATA_DIR"
chmod -R 775 "$DATA_DIR"
chown -R root:www-data "$DOWNLOAD_DIR" 2>/dev/null || chown -R www-data:www-data "$DOWNLOAD_DIR"
chmod -R 775 "$DOWNLOAD_DIR"
chmod 664 "$DB_FILE"
systemctl reload apache2 >/dev/null 2>&1 || systemctl restart apache2

echo "[Panel] Done: /vpn-panel"
