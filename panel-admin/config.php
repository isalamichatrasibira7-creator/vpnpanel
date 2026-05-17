<?php
session_start();
date_default_timezone_set('UTC');
define('APP_DIR', __DIR__);
define('DATA_DIR', __DIR__.'/data');
define('DB_PATH', __DIR__.'/data/vpn.sqlite');
define('DOWNLOAD_DIR', __DIR__.'/downloads');
if(!is_dir(DATA_DIR)) @mkdir(DATA_DIR,0775,true);
if(!is_dir(DOWNLOAD_DIR)) @mkdir(DOWNLOAD_DIR,0775,true);
function db(){ static $db=null; if($db===null){ $db=new SQLite3(DB_PATH); $db->busyTimeout(5000); } return $db; }
function esc($v){ return htmlspecialchars((string)$v, ENT_QUOTES, 'UTF-8'); }
function require_login(){ if(empty($_SESSION['admin_user'])){ header('Location: login.php'); exit; } }
function admin_login($u,$p){ $st=db()->prepare('SELECT username,password_hash FROM admins WHERE username=:u LIMIT 1'); $st->bindValue(':u',$u,SQLITE3_TEXT); $r=$st->execute(); $row=$r?$r->fetchArray(SQLITE3_ASSOC):false; return $row && password_verify($p,$row['password_hash']); }
function cli($cmd){ exec($cmd.' 2>&1',$out,$code); return [$code, implode("\n",$out)]; }
function human_bytes($bytes){ $bytes=(float)$bytes; $units=['B','KB','MB','GB','TB']; $i=0; while($bytes>=1024 && $i<count($units)-1){$bytes/=1024;$i++;} return ($i===0?(string)(int)$bytes:number_format($bytes,2)).' '.$units[$i]; }
function bw_total($row){ return (int)($row['rx'] ?? 0) + (int)($row['tx'] ?? 0); }
function vps_bandwidth(){
    $out = shell_exec('vnstat --json 2>/dev/null');
    if(!$out) return ['today'=>0,'month'=>0,'total'=>0,'ready'=>false];
    $data = json_decode($out, true);
    $iface = $data['interfaces'][0] ?? null;
    if(!$iface) return ['today'=>0,'month'=>0,'total'=>0,'ready'=>false];
    $traffic = $iface['traffic'] ?? [];
    $days = $traffic['day'] ?? [];
    $months = $traffic['month'] ?? [];
    $today = $days ? bw_total(end($days)) : 0;
    $month = $months ? bw_total(end($months)) : 0;
    $total = bw_total($traffic['total'] ?? []);
    return ['today'=>$today,'month'=>$month,'total'=>$total,'ready'=>true];
}
function vpn_conf(){ $f='/etc/vpn-protocols.conf'; return is_file($f) ? parse_ini_file($f) : []; }
function proto_enabled($k){ $c=vpn_conf(); return !empty($c[$k]) && (string)$c[$k] !== '0'; }
function cfgv($k,$d=''){ $c=vpn_conf(); return isset($c[$k]) ? $c[$k] : $d; }

function setting_get($key,$default=''){
  try{ ensure_multirole_schema(); $st=db()->prepare('SELECT value FROM settings WHERE key=:k LIMIT 1'); $st->bindValue(':k',$key,SQLITE3_TEXT); $r=$st->execute(); $row=$r?$r->fetchArray(SQLITE3_ASSOC):false; return $row ? (string)$row['value'] : $default; }catch(Throwable $e){ return $default; }
}
function setting_set($key,$value){ ensure_multirole_schema(); $st=db()->prepare('INSERT INTO settings(key,value,updated_at) VALUES(:k,:v,CURRENT_TIMESTAMP) ON CONFLICT(key) DO UPDATE SET value=excluded.value,updated_at=CURRENT_TIMESTAMP'); $st->bindValue(':k',$key,SQLITE3_TEXT); $st->bindValue(':v',(string)$value,SQLITE3_TEXT); return $st->execute(); }
function random_token($bytes=32){ try{return bin2hex(random_bytes($bytes));}catch(Throwable $e){return bin2hex(openssl_random_pseudo_bytes($bytes));} }
function ensure_multirole_schema(){
  static $done=false; if($done) return; $done=true;
  if(!is_dir(DATA_DIR)) @mkdir(DATA_DIR,0775,true);
  db()->exec("CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT DEFAULT CURRENT_TIMESTAMP)");
  db()->exec("CREATE TABLE IF NOT EXISTS servers(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, ip_address TEXT NOT NULL, panel_url TEXT NOT NULL, api_token TEXT NOT NULL, role TEXT DEFAULT 'node', enabled INTEGER DEFAULT 1, sort_order INTEGER DEFAULT 0, created_at TEXT DEFAULT CURRENT_TIMESTAMP, updated_at TEXT DEFAULT CURRENT_TIMESTAMP)");
  db()->exec("CREATE INDEX IF NOT EXISTS idx_servers_enabled ON servers(enabled,sort_order,id)");
  $role=setting_get_raw('panel_role','');
  if($role==='') setting_set_raw('panel_role','hybrid');
  $token=setting_get_raw('node_api_token','');
  if($token==='') setting_set_raw('node_api_token',random_token(32));
  $name=setting_get_raw('server_name','');
  if($name==='') setting_set_raw('server_name',php_uname('n'));
}
function setting_get_raw($key,$default=''){
  try{ $st=db()->prepare('SELECT value FROM settings WHERE key=:k LIMIT 1'); $st->bindValue(':k',$key,SQLITE3_TEXT); $r=$st->execute(); $row=$r?$r->fetchArray(SQLITE3_ASSOC):false; return $row ? (string)$row['value'] : $default; }catch(Throwable $e){ return $default; }
}
function setting_set_raw($key,$value){ $st=db()->prepare('INSERT INTO settings(key,value,updated_at) VALUES(:k,:v,CURRENT_TIMESTAMP) ON CONFLICT(key) DO UPDATE SET value=excluded.value,updated_at=CURRENT_TIMESTAMP'); $st->bindValue(':k',$key,SQLITE3_TEXT); $st->bindValue(':v',(string)$value,SQLITE3_TEXT); return $st->execute(); }
function panel_role(){ $r=setting_get('panel_role','hybrid'); return in_array($r,['main','node','hybrid'],true)?$r:'hybrid'; }
function is_main_panel(){ return in_array(panel_role(),['main','hybrid'],true); }
function is_node_panel(){ return in_array(panel_role(),['node','hybrid'],true); }
function server_name(){ return setting_get('server_name',php_uname('n')); }
function normalized_panel_url($url){
  $url=trim((string)$url); if($url==='') return '';
  // Accept both the base panel URL and a full copied node_status URL.
  if(preg_match('#/api/node_status\.php#i',$url)){
    $parts=@parse_url($url);
    if(is_array($parts) && !empty($parts['scheme']) && !empty($parts['host'])){
      $port=isset($parts['port'])?':'.$parts['port']:'';
      $path=$parts['path'] ?? '';
      $path=preg_replace('#/api/node_status\.php$#i','',$path);
      return rtrim($parts['scheme'].'://'.$parts['host'].$port.$path,'/');
    }
  }
  return rtrim($url,'/');
}
function node_token_from_url($url){
  $parts=@parse_url(trim((string)$url));
  if(!is_array($parts) || empty($parts['query'])) return '';
  parse_str($parts['query'],$q);
  return isset($q['token']) ? trim((string)$q['token']) : '';
}
function public_base_url(){
  $scheme=(!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS']!=='off')?'https':'http';
  $host=$_SERVER['HTTP_HOST'] ?? ($_SERVER['SERVER_ADDR'] ?? 'SERVER_IP');
  $script=$_SERVER['SCRIPT_NAME'] ?? '/vpn-panel/index.php';
  $base=rtrim(str_replace('\\','/',dirname($script)),'/');
  if($base==='' || $base==='.') $base='/vpn-panel';
  if(substr($base,-4)==='/api') $base=substr($base,0,-4);
  return $scheme.'://'.$host.$base;
}
ensure_multirole_schema();
function render_header($title='VPN Panel'){
$brand=$title ?: 'VPN Panel';
?>
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title><?=esc($brand)?></title><link rel="stylesheet" href="style.css"></head>
<body><div class="shell"><header class="site-header"><div class="brand-wrap"><button class="menu-btn" type="button" onclick="document.body.classList.toggle('menu-open')">☰</button><div><div class="brand"><?=esc($brand)?></div><div class="sub">Logged in as <?=esc($_SESSION['admin_user'] ?? '')?></div></div></div><a class="refresh-btn" href="<?=esc(basename($_SERVER['PHP_SELF']).(!empty($_SERVER['QUERY_STRING'])?'?'.$_SERVER['QUERY_STRING']:''))?>">Refresh</a></header><div class="layout"><aside class="sidebar"><nav class="menu">
<a href="index.php">Dashboard</a>
<?php if(is_main_panel()): ?><a href="servers.php">Multi VPS Servers</a><?php endif; ?>
<a href="settings.php">Panel Role / API Token</a>
<?php if(proto_enabled('OPENVPN')): ?><a href="openvpn.php">OpenVPN Panel</a><?php endif; ?>
<?php if(proto_enabled('OPENCONNECT')): ?><a href="openconnect.php">OpenConnect Panel</a><?php endif; ?>
<?php if(proto_enabled('V2RAY')): ?><a href="v2ray.php">V2Ray Panel</a><?php endif; ?>
<a href="change_password.php">Change Admin Password</a><a href="logout.php">Logout</a>
</nav></aside><main class="content">
<?php }
function render_footer(){ ?>
</main></div></div><div id="toast" class="toast">Copied!</div><script>
function showToast(msg){var t=document.getElementById('toast'); if(!t)return; t.textContent=msg||'Copied!'; t.classList.add('show'); setTimeout(function(){t.classList.remove('show')},1600)}
function copyText(txt){ if(navigator.clipboard){navigator.clipboard.writeText(txt).then(function(){showToast('Copied!')}).catch(function(){fallbackCopy(txt)})} else fallbackCopy(txt); }
function fallbackCopy(txt){var x=document.createElement('textarea'); x.value=txt; document.body.appendChild(x); x.select(); try{document.execCommand('copy');showToast('Copied!')}catch(e){showToast('Copy failed')} document.body.removeChild(x)}
document.addEventListener('click',function(e){if(document.body.classList.contains('menu-open')&&!e.target.closest('.sidebar')&&!e.target.closest('.menu-btn'))document.body.classList.remove('menu-open'); var b=e.target.closest('[data-copy]'); if(b){e.preventDefault(); copyText(b.getAttribute('data-copy')||'');}});
</script></body></html>
<?php }
