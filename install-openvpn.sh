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
DATA_DIR="$APP_DIR/data"; DOWNLOAD_DIR="$APP_DIR/downloads"; DB_FILE="$DATA_DIR/vpn.sqlite"
PKI_DIR="/etc/openvpn/pki-webadmin"; OVPN_DIR="/etc/openvpn/server"; LOG_DIR="/var/log/openvpn"; BIN_DIR="/usr/local/bin"
UDP_PORT="${OVPN_UDP_PORT:-1194}"; TCP_PORT="${OVPN_TCP_PORT:-8443}"
DEFAULT_USER="${DEFAULT_USER:-Easin}"; DEFAULT_USER_PASS="${DEFAULT_USER_PASS:-Easin112233@}"
SERVER_ADDR="$(curl -4 -fsSL https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
NET_IFACE="$(ip route get 1.1.1.1 | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"; : "${NET_IFACE:=eth0}"
CONF_FILE="/etc/vpn-protocols.conf"
is_port(){ [[ "${1:-}" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 )); }
valid_user(){ [[ "${1:-}" =~ ^[A-Za-z0-9._-]{3,32}$ ]]; }
set_conf(){ local k="$1" v="$2"; touch "$CONF_FILE"; if grep -qE "^${k}=" "$CONF_FILE"; then sed -i "s|^${k}=.*|${k}=${v}|" "$CONF_FILE"; else echo "${k}=${v}" >> "$CONF_FILE"; fi; chmod 644 "$CONF_FILE"; }
port_used(){ local port="$1" proto="$2"; case "$proto" in udp) ss -H -lun 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$" ;; tcp) ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$" ;; esac; }
is_port "$UDP_PORT" || { echo "ERROR: Invalid OpenVPN UDP port: $UDP_PORT" >&2; exit 1; }
is_port "$TCP_PORT" || { echo "ERROR: Invalid OpenVPN TCP port: $TCP_PORT" >&2; exit 1; }
[[ "$UDP_PORT" != "$TCP_PORT" ]] || { echo "ERROR: OpenVPN UDP and TCP ports cannot be same" >&2; exit 1; }
valid_user "$DEFAULT_USER" || { echo "ERROR: Invalid default username. Use 3-32 chars: A-Z a-z 0-9 . _ -" >&2; exit 1; }

echo "[OpenVPN] Installing packages..."
apt_update_install openvpn easy-rsa apache2 php libapache2-mod-php php-sqlite3 php-cli sqlite3 curl openssl ca-certificates acl netcat-openbsd iptables iproute2 python3

systemctl stop openvpn-server@server-udp openvpn-server@server-tcp ovpn-iptables.service 2>/dev/null || true
port_used "$UDP_PORT" udp && { echo "ERROR: UDP port $UDP_PORT is already in use" >&2; exit 1; }
port_used "$TCP_PORT" tcp && { echo "ERROR: TCP port $TCP_PORT is already in use" >&2; exit 1; }
systemctl disable openvpn-server@server-udp openvpn-server@server-tcp ovpn-iptables.service 2>/dev/null || true
rm -rf "$PKI_DIR"
rm -f "$OVPN_DIR/server-udp.conf" "$OVPN_DIR/server-tcp.conf" /etc/systemd/system/ovpn-iptables.service
mkdir -p "$APP_DIR" "$DATA_DIR" "$DOWNLOAD_DIR" "$PKI_DIR" "$OVPN_DIR" "$LOG_DIR" "$BIN_DIR"

cat >/etc/sysctl.d/99-vpn-forward.conf <<SYSCTL
net.ipv4.ip_forward=1
SYSCTL
sysctl --system >/dev/null || true

cat >"$BIN_DIR/ovpn-iptables-apply.sh" <<RULES
#!/usr/bin/env bash
set -e
iptables -t nat -C POSTROUTING -s 10.8.0.0/24 -o ${NET_IFACE} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o ${NET_IFACE} -j MASQUERADE
iptables -t nat -C POSTROUTING -s 10.9.0.0/24 -o ${NET_IFACE} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -o ${NET_IFACE} -j MASQUERADE
iptables -C INPUT -p udp --dport ${UDP_PORT} -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport ${UDP_PORT} -j ACCEPT
iptables -C INPUT -p tcp --dport ${TCP_PORT} -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport ${TCP_PORT} -j ACCEPT
iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport 80 -j ACCEPT
RULES
chmod +x "$BIN_DIR/ovpn-iptables-apply.sh"; "$BIN_DIR/ovpn-iptables-apply.sh" || true
cat >/etc/systemd/system/ovpn-iptables.service <<'UNIT'
[Unit]
Description=Apply VPN iptables rules
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/ovpn-iptables-apply.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT

echo "[OpenVPN] Generating PKI..."
rm -rf /root/easy-rsa
make-cadir /root/easy-rsa >/dev/null
cd /root/easy-rsa
./easyrsa init-pki >/dev/null
EASYRSA_BATCH=1 ./easyrsa build-ca nopass >/dev/null 2>&1
EASYRSA_BATCH=1 ./easyrsa build-server-full server nopass >/dev/null 2>&1
./easyrsa gen-dh >/dev/null 2>&1
openvpn --genkey secret pki/ta.key
cp pki/ca.crt "$PKI_DIR/ca.crt"; cp pki/issued/server.crt "$PKI_DIR/server.crt"; cp pki/private/server.key "$PKI_DIR/server.key"; cp pki/dh.pem "$PKI_DIR/dh.pem"; cp pki/ta.key "$PKI_DIR/ta.key"
chown -R root:www-data "$PKI_DIR"; chmod 750 "$PKI_DIR"; chmod 640 "$PKI_DIR/server.key" "$PKI_DIR/ta.key"; chmod 644 "$PKI_DIR/ca.crt" "$PKI_DIR/server.crt" "$PKI_DIR/dh.pem"

sqlite3 "$DB_FILE" <<'SQL'
CREATE TABLE IF NOT EXISTS ovpn_users(id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE NOT NULL, password_hash TEXT NOT NULL, blocked INTEGER NOT NULL DEFAULT 0, created_at TEXT DEFAULT CURRENT_TIMESTAMP, updated_at TEXT DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS ovpn_events(id INTEGER PRIMARY KEY AUTOINCREMENT,event_type TEXT NOT NULL,event_time TEXT DEFAULT CURRENT_TIMESTAMP,username TEXT,common_name TEXT,real_ip TEXT,virtual_ip TEXT,platform TEXT,platform_version TEXT,openvpn_version TEXT,gui_version TEXT,ssl_library TEXT,hwaddr TEXT,time_duration INTEGER DEFAULT 0,rx_bytes INTEGER DEFAULT 0,tx_bytes INTEGER DEFAULT 0,raw_peer_info TEXT,app_hint TEXT);
SQL
USER_HASH="$(php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$DEFAULT_USER_PASS")"
sqlite3 "$DB_FILE" "INSERT OR REPLACE INTO ovpn_users(username,password_hash,blocked) VALUES('$(printf "%s" "$DEFAULT_USER"|sed "s/'/''/g")','$USER_HASH',0);"

cat >"$BIN_DIR/ovpn-auth.php" <<PHP
#!/usr/bin/env php
<?php
\$db=new SQLite3('$DB_FILE'); \$db->busyTimeout(5000); \$user=''; \$pass='';
if(\$argc>=2 && is_file(\$argv[1])){\$lines=@file(\$argv[1],FILE_IGNORE_NEW_LINES); \$user=trim(\$lines[0]??''); \$pass=trim(\$lines[1]??'');} else {\$user=getenv('username')?:''; \$pass=getenv('password')?:'';}
if(\$user===''||\$pass==='') exit(1);
\$st=\$db->prepare('SELECT password_hash,blocked FROM ovpn_users WHERE username=:u LIMIT 1'); \$st->bindValue(':u',\$user,SQLITE3_TEXT); \$r=\$st->execute(); \$row=\$r?\$r->fetchArray(SQLITE3_ASSOC):false;
if(!\$row || (int)(\$row['blocked']??0)===1) exit(1); exit(password_verify(\$pass,\$row['password_hash'])?0:1);
PHP
chmod +x "$BIN_DIR/ovpn-auth.php"

cat >"$BIN_DIR/ovpn-log-event.php" <<PHP
#!/usr/bin/env php
<?php
\$db=new SQLite3('$DB_FILE'); \$db->busyTimeout(5000); function envv(\$k){\$v=getenv(\$k); return \$v===false?'':(string)\$v;} \$peer=[]; foreach(\$_SERVER as \$k=>\$v){ if(strpos(\$k,'IV_')===0||strpos(\$k,'UV_')===0||in_array(\$k,['username','common_name','trusted_ip','trusted_port','ifconfig_pool_remote_ip','script_type','bytes_received','bytes_sent','time_duration'],true)) \$peer[\$k]=(string)\$v; }
\$app=\$peer['UV_APP_PACKAGE']??(\$peer['UV_APP_NAME']??(\$peer['IV_GUI_VER']??(\$peer['IV_PLAT']??''))); \$type=envv('script_type')==='client-disconnect'?'disconnect':'connect';
\$st=\$db->prepare('INSERT INTO ovpn_events(event_type,username,common_name,real_ip,virtual_ip,platform,platform_version,openvpn_version,gui_version,ssl_library,hwaddr,time_duration,rx_bytes,tx_bytes,raw_peer_info,app_hint) VALUES(:event_type,:username,:common_name,:real_ip,:virtual_ip,:platform,:platform_version,:openvpn_version,:gui_version,:ssl_library,:hwaddr,:time_duration,:rx_bytes,:tx_bytes,:raw_peer_info,:app_hint)');
foreach(['event_type'=>\$type,'username'=>envv('username'),'common_name'=>envv('common_name'),'real_ip'=>envv('trusted_ip'),'virtual_ip'=>envv('ifconfig_pool_remote_ip'),'platform'=>envv('IV_PLAT'),'platform_version'=>envv('IV_PLAT_VER'),'openvpn_version'=>envv('IV_VER'),'gui_version'=>envv('IV_GUI_VER'),'ssl_library'=>envv('IV_SSL'),'hwaddr'=>envv('IV_HWADDR'),'raw_peer_info'=>json_encode(\$peer,JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES),'app_hint'=>\$app] as \$k=>\$v){\$st->bindValue(':'.\$k,\$v,SQLITE3_TEXT);} foreach(['time_duration'=>envv('time_duration')?:0,'rx_bytes'=>envv('bytes_received')?:0,'tx_bytes'=>envv('bytes_sent')?:0] as \$k=>\$v){\$st->bindValue(':'.\$k,(int)\$v,SQLITE3_INTEGER);} \$st->execute();
PHP
chmod +x "$BIN_DIR/ovpn-log-event.php"

cat >"$BIN_DIR/ovpn-make-profile.sh" <<'MK'
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
MK
chmod +x "$BIN_DIR/ovpn-make-profile.sh"

cat >"$BIN_DIR/ovpn-kill-user.sh" <<'KILL'
#!/usr/bin/env bash
set -euo pipefail
USER_NAME="${1:-}"; [[ -n "$USER_NAME" ]] || exit 0
for port in 7505 7506; do printf "kill %s\nquit\n" "$USER_NAME" | nc -N 127.0.0.1 "$port" >/dev/null 2>&1 || true; done
KILL
chmod +x "$BIN_DIR/ovpn-kill-user.sh"

cat >"$BIN_DIR/ovpn-user-manage.sh" <<USR
#!/usr/bin/env bash
set -euo pipefail
DB="$DB_FILE"; DOWNLOAD_DIR="$DOWNLOAD_DIR"; SERVER_ADDR="\${SERVER_ADDR_OVERRIDE:-\$(curl -4 -fsSL https://api.ipify.org 2>/dev/null || hostname -I | awk '{print \$1}')}"; cmd="\${1:-}"; user="\${2:-}"; pass="\${3:-}"; esc(){ printf "%s" "\$1"|sed "s/'/''/g"; }; valid_user(){ [[ "\${1:-}" =~ ^[A-Za-z0-9._-]{3,32}$ ]]; }; fix_download_perms(){ mkdir -p "\$DOWNLOAD_DIR"; chown root:www-data "\$DOWNLOAD_DIR" 2>/dev/null || true; chmod 775 "\$DOWNLOAD_DIR" 2>/dev/null || true; }; [[ -z "\$user" || "\$cmd" == "" ]] || valid_user "\$user" || { echo "Invalid username. Use 3-32 chars: A-Z a-z 0-9 . _ -" >&2; exit 1; }
case "\$cmd" in
add) [[ -n "\$user" && -n "\$pass" ]] || exit 1; fix_download_perms; hash="\$(php -r 'echo password_hash(\$argv[1], PASSWORD_DEFAULT);' "\$pass")"; sqlite3 "\$DB" "INSERT INTO ovpn_users(username,password_hash,blocked) VALUES('\$(esc "\$user")','\$(esc "\$hash")',0);"; /usr/local/bin/ovpn-make-profile.sh "\$user" "\$SERVER_ADDR"; echo "User added: \$user";;
update) [[ -n "\$user" && -n "\$pass" ]] || exit 1; fix_download_perms; hash="\$(php -r 'echo password_hash(\$argv[1], PASSWORD_DEFAULT);' "\$pass")"; sqlite3 "\$DB" "UPDATE ovpn_users SET password_hash='\$(esc "\$hash")',updated_at=CURRENT_TIMESTAMP WHERE username='\$(esc "\$user")';"; /usr/local/bin/ovpn-make-profile.sh "\$user" "\$SERVER_ADDR"; echo "User updated: \$user";;
delete) [[ -n "\$user" ]] || exit 1; fix_download_perms; sqlite3 "\$DB" "DELETE FROM ovpn_users WHERE username='\$(esc "\$user")';"; chmod 664 "\$DOWNLOAD_DIR/\$user.ovpn" 2>/dev/null || true; rm -f -- "\$DOWNLOAD_DIR/\$user.ovpn"; echo "User deleted: \$user";;
block) [[ -n "\$user" ]] || exit 1; sqlite3 "\$DB" "UPDATE ovpn_users SET blocked=1,updated_at=CURRENT_TIMESTAMP WHERE username='\$(esc "\$user")';"; /usr/local/bin/ovpn-kill-user.sh "\$user"; echo "User blocked: \$user";;
unblock) [[ -n "\$user" ]] || exit 1; sqlite3 "\$DB" "UPDATE ovpn_users SET blocked=0,updated_at=CURRENT_TIMESTAMP WHERE username='\$(esc "\$user")';"; echo "User unblocked: \$user";;
regen) [[ -n "\$user" ]] || exit 1; /usr/local/bin/ovpn-make-profile.sh "\$user" "\$SERVER_ADDR"; echo "Profile regenerated: \$user";;
*) echo "Usage: \$0 {add|update|delete|block|unblock|regen} user [pass]"; exit 1;; esac
USR
chmod +x "$BIN_DIR/ovpn-user-manage.sh"
cat >/etc/sudoers.d/vpn-panel-ovpn <<'SUDOOVPN'
www-data ALL=(root) NOPASSWD: /usr/local/bin/ovpn-user-manage.sh, /usr/local/bin/ovpn-make-profile.sh, /usr/local/bin/ovpn-kill-user.sh
SUDOOVPN
chmod 440 /etc/sudoers.d/vpn-panel-ovpn
visudo -cf /etc/sudoers.d/vpn-panel-ovpn >/dev/null
set_conf OPENVPN 1; set_conf OVPN_UDP_PORT "$UDP_PORT"; set_conf OVPN_TCP_PORT "$TCP_PORT"
"$BIN_DIR/ovpn-make-profile.sh" "$DEFAULT_USER" "$SERVER_ADDR"

cat >"$OVPN_DIR/server-udp.conf" <<CONF
port ${UDP_PORT}
proto udp
dev tun
persist-key
persist-tun
topology subnet
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ${LOG_DIR}/ipp-udp.txt
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
keepalive 5 20
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-CBC
auth SHA256
ca ${PKI_DIR}/ca.crt
cert ${PKI_DIR}/server.crt
key ${PKI_DIR}/server.key
dh ${PKI_DIR}/dh.pem
tls-crypt ${PKI_DIR}/ta.key
verify-client-cert none
username-as-common-name
auth-user-pass-verify ${BIN_DIR}/ovpn-auth.php via-file
script-security 3
duplicate-cn
client-to-client
status ${LOG_DIR}/openvpn-status-udp.log 1
status-version 3
management 127.0.0.1 7505
log-append ${LOG_DIR}/server-udp.log
verb 4
client-connect ${BIN_DIR}/ovpn-log-event.php
client-disconnect ${BIN_DIR}/ovpn-log-event.php
explicit-exit-notify 1
CONF
cat >"$OVPN_DIR/server-tcp.conf" <<CONF
port ${TCP_PORT}
proto tcp-server
dev tun
persist-key
persist-tun
topology subnet
server 10.9.0.0 255.255.255.0
ifconfig-pool-persist ${LOG_DIR}/ipp-tcp.txt
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
keepalive 5 20
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-CBC
auth SHA256
ca ${PKI_DIR}/ca.crt
cert ${PKI_DIR}/server.crt
key ${PKI_DIR}/server.key
dh ${PKI_DIR}/dh.pem
tls-crypt ${PKI_DIR}/ta.key
verify-client-cert none
username-as-common-name
auth-user-pass-verify ${BIN_DIR}/ovpn-auth.php via-file
script-security 3
duplicate-cn
client-to-client
status ${LOG_DIR}/openvpn-status-tcp.log 1
status-version 3
management 127.0.0.1 7506
log-append ${LOG_DIR}/server-tcp.log
verb 4
client-connect ${BIN_DIR}/ovpn-log-event.php
client-disconnect ${BIN_DIR}/ovpn-log-event.php
CONF

cat >"$APP_DIR/openvpn.php" <<'PHP'
<?php
require __DIR__.'/config.php'; require_login();
function ovpn_users(){ $rows=[]; try{ $res=db()->query('SELECT id,username,blocked,created_at,updated_at FROM ovpn_users ORDER BY id DESC'); while($res && $row=$res->fetchArray(SQLITE3_ASSOC)) $rows[]=$row; }catch(Throwable $e){} return $rows; }
function ovpn_logs($limit=80){ $rows=[]; try{ $st=db()->prepare("SELECT * FROM ovpn_events WHERE event_type='connect' ORDER BY id DESC LIMIT :l"); $st->bindValue(':l',(int)$limit,SQLITE3_INTEGER); $r=$st->execute(); while($r && $row=$r->fetchArray(SQLITE3_ASSOC)) $rows[]=$row; }catch(Throwable $e){} return $rows; }
function parse_status_file($file){ $rows=[]; if(!is_readable($file)) return $rows; foreach(file($file,FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES) as $line){ $line=trim($line); if(strpos($line,'CLIENT_LIST')!==0) continue; $p=preg_split('/[,\t]/',$line); if(count($p)<3) continue; if(count($p)>=10){$rows[]=['common_name'=>$p[1]??'','real_address'=>$p[2]??'','virtual_address'=>$p[3]??'','bytes_received'=>(int)($p[5]??0),'bytes_sent'=>(int)($p[6]??0),'connected_since'=>$p[7]??'','username'=>$p[9]??($p[1]??''),'client_id'=>$p[10]??'','cipher'=>$p[count($p)-1]??''];} else {$rows[]=['common_name'=>$p[1]??'','real_address'=>$p[2]??'','virtual_address'=>'','bytes_received'=>(int)($p[3]??0),'bytes_sent'=>(int)($p[4]??0),'connected_since'=>$p[5]??'','username'=>$p[1]??'','client_id'=>'','cipher'=>$p[count($p)-1]??''];} } return $rows; }
function last_gui_for_user($u){ try{ $st=db()->prepare("SELECT gui_version FROM ovpn_events WHERE username=:u AND COALESCE(gui_version,'')<>'' ORDER BY id DESC LIMIT 1"); $st->bindValue(':u',$u,SQLITE3_TEXT); $r=$st->execute(); $row=$r?$r->fetchArray(SQLITE3_ASSOC):false; return $row['gui_version']??''; }catch(Throwable $e){ return ''; } }
function active_clients(){ $rows=[]; foreach(['/var/log/openvpn/openvpn-status-udp.log'=>'UDP','/var/log/openvpn/openvpn-status-tcp.log'=>'TCP'] as $file=>$src){ foreach(parse_status_file($file) as $r){ $r['source']=$src; if(($r['username']??'')==='') $r['username']=$r['common_name']??''; $r['gui_version']=last_gui_for_user($r['username']); $rows[]=$r; } } return $rows; }
function valid_username($u){ return preg_match('/^[A-Za-z0-9._-]{3,32}$/',$u); }
$msg='';$err=''; if($_SERVER['REQUEST_METHOD']==='POST'){ $a=$_POST['action']??''; $u=trim($_POST['username']??$_POST['edit_username']??''); $p=$_POST['password']??$_POST['edit_password']??''; if(in_array($a,['add','edit'],true)){ if(!valid_username($u)){$err='Invalid username. Use 3-32 chars: A-Z a-z 0-9 . _ -';} elseif($p===''){$err='Password required';} else { [$code,$out]=cli('sudo -n /usr/local/bin/ovpn-user-manage.sh '.($a==='edit'?'update':'add').' '.escapeshellarg($u).' '.escapeshellarg($p)); $code===0?$msg=$out:$err=$out; } } elseif(in_array($a,['delete','block','unblock'],true)){ if(!valid_username($u)){$err='Invalid username';} else { [$code,$out]=cli('sudo -n /usr/local/bin/ovpn-user-manage.sh '.$a.' '.escapeshellarg($u)); $code===0?$msg=$out:$err=$out; } } }
$users=ovpn_users(); $active=active_clients(); $logs=ovpn_logs(); $activeBy=[]; foreach($active as $a){$u=$a['username']?:$a['common_name']; $activeBy[$u]=($activeBy[$u]??0)+1;} render_header('OpenVPN Panel'); ?>
<div class="panel-banner"><div class="toolbar"><div><h2 class="section-title">OpenVPN Live Panel</h2><div class="small"><span class="live-dot"></span> Data auto-refreshes every 5 seconds — no manual refresh needed.</div></div><span id="ovpnSvcBadge" class="badge">LIVE</span></div></div>
<div class="grid"><div class="card soft-card"><div class="muted">Total users</div><div class="kpi" id="ovpnTotalUsers"><?=count($users)?></div></div><div class="card soft-card"><div class="muted">Active connections</div><div class="kpi" id="ovpnActiveCount"><?=count($active)?></div></div><div class="card soft-card"><div class="muted">UDP Port</div><div class="kpi" id="ovpnUdpPort"><?=esc(cfgv('OVPN_UDP_PORT','1194'))?></div></div><div class="card soft-card"><div class="muted">TCP Port</div><div class="kpi" id="ovpnTcpPort"><?=esc(cfgv('OVPN_TCP_PORT','8443'))?></div></div></div>
<?php if($msg): ?><div class="flash" style="margin-top:18px"><?=esc($msg)?></div><?php endif; ?><?php if($err): ?><div class="flash error" style="margin-top:18px"><?=esc($err)?></div><?php endif; ?>
<div class="card" style="margin-top:18px"><h2 class="section-title">Add OpenVPN user</h2><form method="post"><input type="hidden" name="action" value="add"><div class="grid"><input name="username" placeholder="Username" required><input name="password" placeholder="Password" required></div><br><button class="btn green">Create OpenVPN User</button></form></div>
<div class="card" style="margin-top:18px"><h2 class="section-title">OpenVPN Users</h2><div class="table-wrap"><table style="min-width:1000px"><thead><tr><th>Username</th><th>Status</th><th>Active Devices</th><th>Edit Password</th><th>Actions</th></tr></thead><tbody id="ovpnUsersBody"><?php foreach($users as $u): $name=$u['username']; ?><tr><td><strong><?=esc($name)?></strong></td><td><?=((int)$u['blocked']===1)?'<span class="badge red">Blocked</span>':'<span class="badge green">Active</span>'?></td><td><span class="badge"><?=esc($activeBy[$name]??0)?> connected</span></td><td><form method="post" class="actions"><input type="hidden" name="action" value="edit"><input type="hidden" name="edit_username" value="<?=esc($name)?>"><input name="edit_password" placeholder="New password" required><button class="btn">Update</button></form></td><td class="actions"><a class="btn green" href="download.php?u=<?=urlencode($name)?>">Download</a><form method="post" style="display:inline"><input type="hidden" name="username" value="<?=esc($name)?>"><?php if((int)$u['blocked']===1): ?><button class="btn yellow" name="action" value="unblock">Unblock</button><?php else: ?><button class="btn red" name="action" value="block">Block</button><?php endif; ?></form><form method="post" style="display:inline" onsubmit="return confirm('Delete this user?')"><input type="hidden" name="username" value="<?=esc($name)?>"><button class="btn red" name="action" value="delete">Delete</button></form></td></tr><?php endforeach; ?></tbody></table></div></div>
<div class="card" style="margin-top:18px"><div class="toolbar"><h2 class="section-title">OpenVPN Active Connected Devices</h2><span class="badge green"><span id="ovpnActiveBadge"><?=count($active)?></span> active</span></div><div class="table-wrap"><table><thead><tr><th>User</th><th>Protocol</th><th>GUI Version</th><th>Real IP</th><th>Virtual IP</th><th>Since</th><th>Download</th><th>Upload</th></tr></thead><tbody id="ovpnActiveBody"><?php if(!$active): ?><tr><td colspan="8" class="empty">No active OpenVPN devices.</td></tr><?php else: foreach($active as $c): $u=$c['username']?:$c['common_name']; ?><tr><td><strong><?=esc($u)?></strong></td><td><span class="badge"><?=esc($c['source'])?></span></td><td class="small"><?=esc($c['gui_version']?:'-')?></td><td><?=esc($c['real_address'])?></td><td><?=esc($c['virtual_address']?:'-')?></td><td><?=esc($c['connected_since'])?></td><td><?=esc(human_bytes($c['bytes_received']))?></td><td><?=esc(human_bytes($c['bytes_sent']))?></td></tr><?php endforeach; endif; ?></tbody></table></div></div>
<div class="card" style="margin-top:18px"><h2 class="section-title">Recent OpenVPN logs</h2><div class="table-wrap"><table><thead><tr><th>Time</th><th>User</th><th>IP</th><th>Virtual IP</th><th>GUI Version</th></tr></thead><tbody id="ovpnLogsBody"><?php foreach($logs as $r): ?><tr><td><?=esc($r['event_time'])?></td><td><?=esc($r['username']?:$r['common_name'])?></td><td><?=esc($r['real_ip'])?></td><td><?=esc($r['virtual_ip'])?></td><td class="small"><?=esc($r['gui_version']?:'-')?></td></tr><?php endforeach; ?></tbody></table></div></div>
<script>
async function refreshOpenVPN(){try{const r=await fetch('api_status.php?proto=openvpn&html=1&_='+Date.now(),{cache:'no-store'});const d=await r.json();if(!d.ok)return;document.getElementById('ovpnTotalUsers').textContent=d.counts.users;document.getElementById('ovpnActiveCount').textContent=d.counts.active;document.getElementById('ovpnActiveBadge').textContent=d.counts.active;document.getElementById('ovpnUdpPort').textContent=d.ports.udp;document.getElementById('ovpnTcpPort').textContent=d.ports.tcp;const b=document.getElementById('ovpnSvcBadge');b.className='badge '+(d.running?'green':'red');b.textContent=d.running?'RUNNING':'STOPPED';document.getElementById('ovpnUsersBody').innerHTML=d.html.users;document.getElementById('ovpnActiveBody').innerHTML=d.html.active;document.getElementById('ovpnLogsBody').innerHTML=d.html.logs;}catch(e){}}
refreshOpenVPN();setInterval(refreshOpenVPN,5000);
</script>
<?php render_footer(); ?>

PHP
cat >"$APP_DIR/download.php" <<PHP
<?php require __DIR__.'/config.php'; require_login(); \$u=basename(\$_GET['u']??''); \$p=DOWNLOAD_DIR.'/'.\$u.'.ovpn'; if(!is_file(\$p)){http_response_code(404);exit('Profile not found');} header('Cache-Control: no-store, no-cache, must-revalidate, max-age=0'); header('Pragma: no-cache'); header('Content-Type: application/octet-stream'); header('Content-Length: '.filesize(\$p)); header('Content-Disposition: attachment; filename="'.\$u.'.ovpn"'); readfile(\$p);
PHP

chown -R root:www-data "$APP_DIR"; find "$APP_DIR" -type d -exec chmod 755 {} \; ; find "$APP_DIR" -type f -exec chmod 644 {} \; ; chown -R www-data:www-data "$DATA_DIR"; chmod -R 775 "$DATA_DIR"; chown -R root:www-data "$DOWNLOAD_DIR" 2>/dev/null || true; chmod -R 775 "$DOWNLOAD_DIR"; find "$DOWNLOAD_DIR" -type f -name '*.ovpn' -exec chown root:www-data {} \; -exec chmod 664 {} \; 2>/dev/null || true; chmod 664 "$DB_FILE"
systemctl daemon-reload
systemctl enable apache2 ovpn-iptables.service openvpn-server@server-udp openvpn-server@server-tcp >/dev/null
systemctl reload apache2 >/dev/null 2>&1 || systemctl restart apache2 || true
systemctl restart ovpn-iptables.service || true
if [[ -x /usr/local/bin/vpn-control.sh ]]; then /usr/local/bin/vpn-control.sh refresh-firewall >/dev/null 2>&1 || true; fi
systemctl restart openvpn-server@server-udp
systemctl restart openvpn-server@server-tcp
chmod 644 "$LOG_DIR"/openvpn-status-udp.log "$LOG_DIR"/openvpn-status-tcp.log 2>/dev/null || true
setfacl -m u:www-data:r "$LOG_DIR"/openvpn-status-udp.log "$LOG_DIR"/openvpn-status-tcp.log 2>/dev/null || true
echo "[OpenVPN] Done"
