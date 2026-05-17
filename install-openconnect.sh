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
BIN_DIR="/usr/local/bin"
OC_PORT="${OC_PORT:-443}"
DEFAULT_USER="${DEFAULT_USER:-Easin}"
DEFAULT_USER_PASS="${DEFAULT_USER_PASS:-Easin112233@}"
CONF_FILE="/etc/vpn-protocols.conf"
SERVER_ADDR="$(curl -4 -fsSL https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"
NET_IFACE="$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"; : "${NET_IFACE:=eth0}"

is_port(){ [[ "${1:-}" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 )); }
valid_user(){ [[ "${1:-}" =~ ^[A-Za-z0-9._-]{3,32}$ ]]; }
set_conf(){ local k="$1" v="$2"; touch "$CONF_FILE"; if grep -qE "^${k}=" "$CONF_FILE"; then sed -i "s|^${k}=.*|${k}=${v}|" "$CONF_FILE"; else echo "${k}=${v}" >> "$CONF_FILE"; fi; chmod 644 "$CONF_FILE"; }
port_used(){ local port="$1"; ss -H -ltun 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"; }

is_port "$OC_PORT" || { echo "ERROR: Invalid OpenConnect port: $OC_PORT" >&2; exit 1; }
valid_user "$DEFAULT_USER" || { echo "ERROR: Invalid default username. Use 3-32 chars: A-Z a-z 0-9 . _ -" >&2; exit 1; }

mkdir -p "$APP_DIR" "$DATA_DIR" "$BIN_DIR"
echo "[OpenConnect] Installing packages..."
apt_update_install ocserv gnutls-bin apache2 php libapache2-mod-php php-cli php-sqlite3 sqlite3 curl openssl sudo iptables iproute2 ca-certificates

systemctl stop ocserv 2>/dev/null || true
if port_used "$OC_PORT"; then
  echo "ERROR: OpenConnect port $OC_PORT is already in use. Choose another port." >&2
  exit 1
fi

mkdir -p /etc/ocserv/ssl "$DATA_DIR" "$BIN_DIR"
touch /etc/ocserv/ocpasswd
chmod 600 /etc/ocserv/ocpasswd
chown root:root /etc/ocserv/ocpasswd

openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -keyout /etc/ocserv/ssl/server-key.pem -out /etc/ocserv/ssl/server-cert.pem -subj "/CN=${SERVER_ADDR}" -addext "subjectAltName=IP:${SERVER_ADDR}" >/dev/null 2>&1 || true
chmod 600 /etc/ocserv/ssl/server-key.pem
chmod 644 /etc/ocserv/ssl/server-cert.pem

cat >/etc/ocserv/ocserv.conf <<EOF
auth = "plain[passwd=/etc/ocserv/ocpasswd]"
tcp-port = ${OC_PORT}
udp-port = ${OC_PORT}
run-as-user = nobody
run-as-group = daemon
use-occtl = true
socket-file = /run/occtl.socket
server-cert = /etc/ocserv/ssl/server-cert.pem
server-key = /etc/ocserv/ssl/server-key.pem
max-clients = 100000
max-same-clients = 0
default-domain = ${SERVER_ADDR}
ipv4-network = 10.20.30.0
ipv4-netmask = 255.255.255.0
dns = 1.1.1.1
dns = 8.8.8.8
tunnel-all-dns = true
route = default
keepalive = 32400
dpd = 90
mobile-dpd = 1800
switch-to-tcp-timeout = 25
try-mtu-discovery = false
compression = false
server-stats-reset-time = 604800
device = vpns
predictable-ips = true
cisco-client-compat = true
connect-script = /usr/local/bin/oc-event-log.sh
disconnect-script = /usr/local/bin/oc-event-log.sh
EOF

iptables -t nat -C POSTROUTING -s 10.20.30.0/24 -o "$NET_IFACE" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.20.30.0/24 -o "$NET_IFACE" -j MASQUERADE
iptables -C FORWARD -s 10.20.30.0/24 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s 10.20.30.0/24 -j ACCEPT
iptables -C FORWARD -d 10.20.30.0/24 -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -A FORWARD -d 10.20.30.0/24 -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -C INPUT -p tcp --dport "$OC_PORT" -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport "$OC_PORT" -j ACCEPT
iptables -C INPUT -p udp --dport "$OC_PORT" -j ACCEPT 2>/dev/null || iptables -A INPUT -p udp --dport "$OC_PORT" -j ACCEPT

cat >"$BIN_DIR/oc-user-manage.sh" <<OCUSER
#!/usr/bin/env bash
set -euo pipefail
PASSFILE="/etc/ocserv/ocpasswd"
CSV="$DATA_DIR/oc_users.csv"
cmd="\${1:-}"; user="\${2:-}"; pass="\${3:-}"
valid_user(){ [[ "\${1:-}" =~ ^[A-Za-z0-9._-]{3,32}$ ]]; }
mkdir -p "\$(dirname "\$CSV")"; touch "\$PASSFILE" "\$CSV"
chmod 600 "\$PASSFILE"; chmod 664 "\$CSV"; chown root:www-data "\$CSV" 2>/dev/null || true
upsert(){ local u="\$1" b="\${2:-0}"; awk -F'|' -v U="\$u" '\$1!=U' "\$CSV" > "\$CSV.tmp" 2>/dev/null || true; printf '%s|%s\n' "\$u" "\$b" >> "\$CSV.tmp"; mv "\$CSV.tmp" "\$CSV"; chmod 664 "\$CSV"; chown root:www-data "\$CSV" 2>/dev/null || true; }
delcsv(){ local u="\$1"; awk -F'|' -v U="\$u" '\$1!=U' "\$CSV" > "\$CSV.tmp" 2>/dev/null || true; mv "\$CSV.tmp" "\$CSV"; chmod 664 "\$CSV"; chown root:www-data "\$CSV" 2>/dev/null || true; }
killu(){ command -v occtl >/dev/null 2>&1 && occtl -s /run/occtl.socket disconnect user "\$1" >/dev/null 2>&1 || true; }
[[ -z "\$user" ]] || valid_user "\$user" || { echo "Invalid username. Use 3-32 chars: A-Z a-z 0-9 . _ -" >&2; exit 1; }
case "\$cmd" in
 add|update) [[ -n "\$user" && -n "\$pass" ]] || exit 1; printf '%s\n%s\n' "\$pass" "\$pass" | ocpasswd -c "\$PASSFILE" "\$user" >/dev/null; upsert "\$user" 0; echo "User saved: \$user";;
 delete) [[ -n "\$user" ]] || exit 1; ocpasswd -c "\$PASSFILE" -d "\$user" >/dev/null 2>&1 || true; delcsv "\$user"; killu "\$user"; echo "User deleted: \$user";;
 block) [[ -n "\$user" ]] || exit 1; upsert "\$user" 1; ocpasswd -c "\$PASSFILE" -d "\$user" >/dev/null 2>&1 || true; killu "\$user"; echo "User blocked: \$user";;
 unblock) [[ -n "\$user" && -n "\$pass" ]] || { echo "Password required to unblock" >&2; exit 1; }; printf '%s\n%s\n' "\$pass" "\$pass" | ocpasswd -c "\$PASSFILE" "\$user" >/dev/null; upsert "\$user" 0; echo "User unblocked: \$user";;
 *) echo "Usage: \$0 {add|update|delete|block|unblock} user [pass]"; exit 1;;
esac
OCUSER
chmod +x "$BIN_DIR/oc-user-manage.sh"

cat >"$BIN_DIR/oc-event-log.sh" <<'OCEVENT'
#!/usr/bin/env bash
set -euo pipefail
DB="/var/www/html/panel-admin/data/oc_events.sqlite"
TYPE="${REASON:-${script_type:-connect}}"; USER_NAME="${USERNAME:-${USER:-${username:-}}}"; REAL_IP="${IP_REAL:-${REMOTE_HOST:-${trusted_ip:-}}}"; VPN_IP="${IP_REMOTE:-${IP_LOCAL:-${ifconfig_pool_remote_ip:-}}}"; AGENT="${USER_AGENT:-${DEVICE_TYPE:-}}"; DUR="${STATS_DURATION:-${time_duration:-0}}"; BIN="${STATS_BYTES_IN:-${bytes_received:-0}}"; BOUT="${STATS_BYTES_OUT:-${bytes_sent:-0}}"
case "$(printf '%s' "$TYPE"|tr '[:upper:]' '[:lower:]')" in *disconnect*) EVENT_TYPE="disconnect";; *) EVENT_TYPE="connect";; esac
esc(){ printf "%s" "$1" | sed "s/'/''/g"; }
mkdir -p "$(dirname "$DB")"
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS oc_events(id INTEGER PRIMARY KEY AUTOINCREMENT,event_time TEXT DEFAULT CURRENT_TIMESTAMP,event_type TEXT,username TEXT,real_ip TEXT,vpn_ip TEXT,user_agent TEXT,duration INTEGER DEFAULT 0,bytes_in INTEGER DEFAULT 0,bytes_out INTEGER DEFAULT 0); INSERT INTO oc_events(event_type,username,real_ip,vpn_ip,user_agent,duration,bytes_in,bytes_out) VALUES('$(esc "$EVENT_TYPE")','$(esc "$USER_NAME")','$(esc "$REAL_IP")','$(esc "$VPN_IP")','$(esc "$AGENT")',${DUR:-0},${BIN:-0},${BOUT:-0});"
OCEVENT
chmod +x "$BIN_DIR/oc-event-log.sh"

cat >"$BIN_DIR/oc-active-sessions.sh" <<'OCACT'
#!/usr/bin/env bash
set -euo pipefail
SOCK="/run/occtl.socket"
[[ -S "$SOCK" ]] || exit 0
occtl -s "$SOCK" show users 2>/dev/null || true
OCACT
chmod +x "$BIN_DIR/oc-active-sessions.sh"

cat >/etc/sudoers.d/vpn-panel-oc <<EOF
www-data ALL=(root) NOPASSWD: /usr/local/bin/oc-user-manage.sh
www-data ALL=(root) NOPASSWD: /usr/local/bin/oc-active-sessions.sh
EOF
chmod 440 /etc/sudoers.d/vpn-panel-oc
visudo -cf /etc/sudoers.d/vpn-panel-oc >/dev/null

sqlite3 "$DATA_DIR/oc_events.sqlite" "CREATE TABLE IF NOT EXISTS oc_events(id INTEGER PRIMARY KEY AUTOINCREMENT,event_time TEXT DEFAULT CURRENT_TIMESTAMP,event_type TEXT,username TEXT,real_ip TEXT,vpn_ip TEXT,user_agent TEXT,duration INTEGER DEFAULT 0,bytes_in INTEGER DEFAULT 0,bytes_out INTEGER DEFAULT 0);" || true
chown www-data:www-data "$DATA_DIR/oc_events.sqlite" 2>/dev/null || true
chmod 664 "$DATA_DIR/oc_events.sqlite" 2>/dev/null || true

"$BIN_DIR/oc-user-manage.sh" add "$DEFAULT_USER" "$DEFAULT_USER_PASS" >/dev/null

cat >"$APP_DIR/openconnect.php" <<'PHP'
<?php
require __DIR__.'/config.php'; require_login();
function valid_username($u){ return preg_match('/^[A-Za-z0-9._-]{3,32}$/',$u); }
function oc_users(){ $f=DATA_DIR.'/oc_users.csv'; $rows=[]; if(!is_readable($f)) return $rows; foreach(file($f,FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES) as $line){ $p=explode('|',$line); if(trim($p[0]??'')!=='') $rows[]=['username'=>trim($p[0]),'blocked'=>(int)($p[1]??0)]; } return $rows; }
function oc_logs($limit=80){ $f=DATA_DIR.'/oc_events.sqlite'; if(!is_file($f)) return []; $db=new SQLite3($f); $res=$db->query('SELECT * FROM oc_events ORDER BY id DESC LIMIT '.(int)$limit); $rows=[]; while($res && $r=$res->fetchArray(SQLITE3_ASSOC)) $rows[]=$r; return $rows; }
function oc_session_ip_from_token($token){
  $token=trim((string)$token," \t\n\r\0\x0B[](),;");
  if(preg_match('/^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/',$token,$m)) $token=$m[1];
  if(preg_match('/^(\d{1,3}(?:\.\d{1,3}){3})(?::\d+)?$/',$token,$m)) $token=$m[1];
  return filter_var($token,FILTER_VALIDATE_IP) ? $token : '';
}
function oc_sessions(){
  $out=shell_exec('sudo -n /usr/local/bin/oc-active-sessions.sh 2>/dev/null');
  $rows=[]; if(!$out) return $rows;
  $known=[];
  foreach(oc_users() as $u){ if((int)($u['blocked']??0)===0) $known[$u['username']]=true; }
  $seen=[];
  foreach(explode("\n",trim($out)) as $line){
    $line=trim($line);
    if($line===''||stripos($line,'id')===0||$line[0]=='('||strpos($line,'---')===0) continue;
    if(!preg_match('/^\d+\s+/',$line)) continue;
    $p=preg_split('/\s+/',$line);
    $id=$p[0]??'-'; $user=$p[1]??'';

    // occtl also lists unauthenticated port scanners as username "(none)".
    // Count only real, authenticated VPN users that match the panel username format.
    if(!preg_match('/^[A-Za-z0-9._-]{3,32}$/',$user)) continue;
    if($known && empty($known[$user])) continue;
    if(preg_match('/\b(disconnected|disconnect|offline|logout|closed)\b/i',$line)) continue;

    $ips=[];
    foreach($p as $tok){ $ip=oc_session_ip_from_token($tok); if($ip!=='' && !in_array($ip,$ips,true)) $ips[]=$ip; }
    $vpn='-'; $real='-';
    foreach($ips as $ip){ if(strpos($ip,'10.20.30.')===0){ $vpn=$ip; break; } }
    foreach($ips as $ip){ if($ip!==$vpn){ $real=$ip; break; } }
    if($real==='-' && isset($p[3])){ $ip=oc_session_ip_from_token($p[3]); if($ip!=='') $real=$ip; }
    if($vpn==='-' && isset($p[4])){ $ip=oc_session_ip_from_token($p[4]); if($ip!=='') $vpn=$ip; }

    $device='-';
    foreach($p as $tok){ if(preg_match('/^(vpns|tun|vpn|oc|ppp)[A-Za-z0-9_.:-]*$/i',$tok)){ $device=$tok; break; } }
    if($device==='-' && isset($p[5]) && oc_session_ip_from_token($p[5])==='' && !preg_match('/^[()\-]+$/',$p[5])) $device=$p[5];

    $since='live';
    if(isset($p[6]) && !preg_match('/^[-()]+$/',$p[6])) $since=implode(' ',array_slice($p,6));
    $key=$user.'|'.$real.'|'.$vpn.'|'.$device;
    if(isset($seen[$key])) continue; $seen[$key]=1;
    $rows[]=['id'=>$id,'user'=>$user,'real_ip'=>$real,'vpn_ip'=>$vpn,'device'=>$device,'since'=>$since];
  }
  return $rows;
}
$msg='';$err=''; if($_SERVER['REQUEST_METHOD']==='POST'){ $a=$_POST['action']??'add'; $u=trim($_POST['username']??''); $p=trim($_POST['password']??''); if(!valid_username($u)){$err='Invalid username. Use 3-32 chars: A-Z a-z 0-9 . _ -';} elseif(in_array($a,['add','update','unblock'],true)&&$p===''){$err='Password required';} else { $cmd=$a==='unblock'?'unblock':($a==='update'?'update':($a==='block'?'block':($a==='delete'?'delete':'add'))); [$code,$out]=cli('sudo /usr/local/bin/oc-user-manage.sh '.$cmd.' '.escapeshellarg($u).($p!==''?' '.escapeshellarg($p):'')); $code===0?$msg=$out:$err=$out; } }
$users=oc_users(); $sessions=oc_sessions(); $logs=oc_logs(); $server=$_SERVER['SERVER_ADDR']??$_SERVER['SERVER_NAME']??'SERVER_IP'; $ocUrl='https://'.$server.':'.cfgv('OC_PORT','443'); render_header('OpenConnect Panel'); ?>
<div class="panel-banner"><div class="toolbar"><div><h2 class="section-title">OpenConnect Live Panel</h2><div class="small"><span class="live-dot"></span> Status, active sessions and logs auto-refresh every 5 seconds.</div></div><span id="ocSvcBadge" class="badge">LIVE</span></div></div>
<div class="grid"><div class="card soft-card"><div class="muted">Total users</div><div class="kpi" id="ocTotalUsers"><?=count($users)?></div></div><div class="card soft-card"><div class="muted">Active sessions</div><div class="kpi" id="ocActiveCount"><?=count($sessions)?></div></div><div class="card soft-card"><div class="muted">Port</div><div class="kpi" id="ocPort"><?=esc(cfgv('OC_PORT','443'))?></div></div></div>
<?php if($msg): ?><div class="flash" style="margin-top:18px"><?=esc($msg)?></div><?php endif; ?><?php if($err): ?><div class="flash error" style="margin-top:18px"><?=esc($err)?></div><?php endif; ?>
<div class="card" style="margin-top:18px"><h2 class="section-title">Add / update OpenConnect user</h2><form method="post"><input type="hidden" name="action" value="add"><div class="grid"><input name="username" placeholder="Username" required><input name="password" placeholder="Password" required></div><br><button class="btn green">Save OpenConnect User</button></form></div>
<div class="card" style="margin-top:18px"><h2 class="section-title">Connection URL</h2><div class="copy-row"><div class="code" id="ocServerUrl"><?=esc($ocUrl)?></div><button class="btn copy-btn" data-copy="<?=esc($ocUrl)?>" id="ocCopyBtn" title="Copy URL">📋</button></div><div class="small" style="margin-top:10px">Use this URL in OpenConnect/AnyConnect client.</div></div>
<div class="card" style="margin-top:18px"><h2 class="section-title">OpenConnect Users</h2><div class="table-wrap"><table><thead><tr><th>Username</th><th>Status</th><th>Reset password</th><th>Actions</th></tr></thead><tbody id="ocUsersBody"><?php foreach($users as $u): $name=$u['username']; ?><tr><td><strong><?=esc($name)?></strong></td><td><?=((int)$u['blocked']===1)?'<span class="badge red">Blocked</span>':'<span class="badge green">Active</span>'?></td><td><form method="post" class="actions"><input type="hidden" name="action" value="update"><input type="hidden" name="username" value="<?=esc($name)?>"><input name="password" placeholder="New password" required><button class="btn">Update</button></form></td><td class="actions"><form method="post" style="display:inline"><input type="hidden" name="username" value="<?=esc($name)?>"><?php if((int)$u['blocked']===1): ?><input name="password" placeholder="Password to unblock" required><button class="btn yellow" name="action" value="unblock">Unblock</button><?php else: ?><button class="btn red" name="action" value="block">Block</button><?php endif; ?></form><form method="post" style="display:inline" onsubmit="return confirm('Delete this user?')"><input type="hidden" name="username" value="<?=esc($name)?>"><button class="btn red" name="action" value="delete">Delete</button></form></td></tr><?php endforeach; ?></tbody></table></div></div>
<div class="card" style="margin-top:18px"><div class="toolbar"><h2 class="section-title">OpenConnect Active Devices</h2><span class="badge green"><span id="ocActiveBadge"><?=count($sessions)?></span> active</span></div><div class="table-wrap"><table><thead><tr><th>ID</th><th>User</th><th>Real IP</th><th>VPN IP</th><th>Device</th><th>Since</th></tr></thead><tbody id="ocSessionsBody"><?php if(!$sessions): ?><tr><td colspan="6" class="empty">No active OpenConnect session.</td></tr><?php else: foreach($sessions as $s): ?><tr><td><?=esc($s['id'])?></td><td><strong><?=esc($s['user'])?></strong></td><td><?=esc($s['real_ip'])?></td><td><?=esc($s['vpn_ip'])?></td><td><?=esc($s['device'])?></td><td><?=esc($s['since'])?></td></tr><?php endforeach; endif; ?></tbody></table></div></div>
<div class="card" style="margin-top:18px"><h2 class="section-title">Recent OpenConnect logs</h2><div class="table-wrap"><table><thead><tr><th>Time</th><th>Event</th><th>User</th><th>Real IP</th><th>VPN IP</th><th>Download</th><th>Upload</th></tr></thead><tbody id="ocLogsBody"><?php foreach($logs as $r): ?><tr><td><?=esc($r['event_time'])?></td><td><?=esc($r['event_type'])?></td><td><?=esc($r['username'])?></td><td><?=esc($r['real_ip'])?></td><td><?=esc($r['vpn_ip'])?></td><td><?=esc(human_bytes($r['bytes_in']))?></td><td><?=esc(human_bytes($r['bytes_out']))?></td></tr><?php endforeach; ?></tbody></table></div></div>
<script>
async function refreshOpenConnect(){try{const r=await fetch('api_status.php?proto=openconnect&html=1&_='+Date.now(),{cache:'no-store'});const d=await r.json();if(!d.ok)return;document.getElementById('ocTotalUsers').textContent=d.counts.users;document.getElementById('ocActiveCount').textContent=d.counts.active;document.getElementById('ocActiveBadge').textContent=d.counts.active;document.getElementById('ocPort').textContent=d.port;document.getElementById('ocServerUrl').textContent=d.server_url;document.getElementById('ocCopyBtn').setAttribute('data-copy',d.server_url);const b=document.getElementById('ocSvcBadge');b.className='badge '+(d.running?'green':'red');b.textContent=d.running?'RUNNING':'STOPPED';document.getElementById('ocUsersBody').innerHTML=d.html.users;document.getElementById('ocSessionsBody').innerHTML=d.html.sessions;document.getElementById('ocLogsBody').innerHTML=d.html.logs;}catch(e){}}
refreshOpenConnect();setInterval(refreshOpenConnect,5000);
</script>
<?php render_footer(); ?>

PHP

set_conf OPENCONNECT 1
set_conf OC_PORT "$OC_PORT"
systemctl daemon-reload
systemctl enable ocserv apache2 >/dev/null 2>&1 || true
systemctl reload apache2 >/dev/null 2>&1 || systemctl restart apache2 || true
if [[ -x /usr/local/bin/vpn-control.sh ]]; then /usr/local/bin/vpn-control.sh refresh-firewall >/dev/null 2>&1 || true; fi
systemctl restart ocserv
chown -R root:www-data "$APP_DIR"
find "$APP_DIR" -type d -exec chmod 755 {} \;
find "$APP_DIR" -type f -exec chmod 644 {} \;
chown -R www-data:www-data "$DATA_DIR"
chmod -R 775 "$DATA_DIR"
echo "[OpenConnect] Done on port ${OC_PORT}"
