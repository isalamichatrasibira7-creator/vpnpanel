<?php
require __DIR__.'/config.php'; require_login();
header('Content-Type: application/json; charset=utf-8');

function svc_running($proto){
  $proto = preg_replace('/[^a-z0-9_-]/i','',$proto);
  exec('sudo -n /usr/local/bin/vpn-control.sh status '.escapeshellarg($proto).' >/dev/null 2>&1', $o, $c);
  return $c === 0;
}
function h($v){ return htmlspecialchars((string)$v, ENT_QUOTES, 'UTF-8'); }
function badge_html($ok,$on='Active',$off='Blocked'){ return $ok ? '<span class="badge green">'.h($on).'</span>' : '<span class="badge red">'.h($off).'</span>'; }
function parse_ovpn_status_file($file){
  $rows=[]; if(!is_readable($file)) return $rows;
  foreach(file($file, FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES) as $line){
    $line=trim($line); if(strpos($line,'CLIENT_LIST')!==0) continue;
    $p=preg_split('/[,\t]/',$line); if(count($p)<3) continue;
    if(count($p)>=10){
      $rows[]=['common_name'=>$p[1]??'','real_address'=>$p[2]??'','virtual_address'=>$p[3]??'','bytes_received'=>(int)($p[5]??0),'bytes_sent'=>(int)($p[6]??0),'connected_since'=>$p[7]??'','username'=>$p[9]??($p[1]??''),'client_id'=>$p[10]??'','cipher'=>$p[count($p)-1]??''];
    } else {
      $rows[]=['common_name'=>$p[1]??'','real_address'=>$p[2]??'','virtual_address'=>'','bytes_received'=>(int)($p[3]??0),'bytes_sent'=>(int)($p[4]??0),'connected_since'=>$p[5]??'','username'=>$p[1]??'','client_id'=>'','cipher'=>$p[count($p)-1]??''];
    }
  }
  return $rows;
}
function ovpn_last_gui($u){
  if(!is_file(DB_PATH)) return '';
  try{ $st=db()->prepare("SELECT gui_version FROM ovpn_events WHERE username=:u AND COALESCE(gui_version,'')<>'' ORDER BY id DESC LIMIT 1"); $st->bindValue(':u',$u,SQLITE3_TEXT); $r=$st->execute(); $row=$r?$r->fetchArray(SQLITE3_ASSOC):false; return $row['gui_version']??''; } catch(Throwable $e){ return ''; }
}
function ovpn_users(){
  $rows=[]; if(!is_file(DB_PATH)) return $rows;
  try{ $res=db()->query('SELECT id,username,blocked,created_at,updated_at FROM ovpn_users ORDER BY id DESC'); while($res && $row=$res->fetchArray(SQLITE3_ASSOC)) $rows[]=$row; } catch(Throwable $e){}
  return $rows;
}
function ovpn_logs($limit=40){
  $rows=[]; if(!is_file(DB_PATH)) return $rows;
  try{ $st=db()->prepare("SELECT * FROM ovpn_events WHERE event_type='connect' ORDER BY id DESC LIMIT :l"); $st->bindValue(':l',(int)$limit,SQLITE3_INTEGER); $r=$st->execute(); while($r && $row=$r->fetchArray(SQLITE3_ASSOC)) $rows[]=$row; } catch(Throwable $e){}
  return $rows;
}
function ovpn_active(){
  $rows=[]; foreach(['/var/log/openvpn/openvpn-status-udp.log'=>'UDP','/var/log/openvpn/openvpn-status-tcp.log'=>'TCP'] as $file=>$src){ foreach(parse_ovpn_status_file($file) as $r){ $r['source']=$src; if(($r['username']??'')==='') $r['username']=$r['common_name']??''; $r['gui_version']=ovpn_last_gui($r['username']); $rows[]=$r; } }
  return $rows;
}
function openvpn_html($users,$active,$logs){
  $activeBy=[]; foreach($active as $a){ $u=$a['username']?:$a['common_name']; $activeBy[$u]=($activeBy[$u]??0)+1; }
  $usersHtml='';
  foreach($users as $u){ $name=$u['username']; $usersHtml.='<tr><td><strong>'.h($name).'</strong></td><td>'.(((int)$u['blocked']===1)?'<span class="badge red">Blocked</span>':'<span class="badge green">Active</span>').'</td><td><span class="badge">'.h($activeBy[$name]??0).' connected</span></td><td><form method="post" class="actions"><input type="hidden" name="action" value="edit"><input type="hidden" name="edit_username" value="'.h($name).'"><input name="edit_password" placeholder="New password" required><button class="btn">Update</button></form></td><td class="actions"><a class="btn green" href="download.php?u='.rawurlencode($name).'">Download</a><form method="post" style="display:inline"><input type="hidden" name="username" value="'.h($name).'">'.(((int)$u['blocked']===1)?'<button class="btn yellow" name="action" value="unblock">Unblock</button>':'<button class="btn red" name="action" value="block">Block</button>').'</form><form method="post" style="display:inline" onsubmit="return confirm(\'Delete this user?\')"><input type="hidden" name="username" value="'.h($name).'"><button class="btn red" name="action" value="delete">Delete</button></form></td></tr>'; }
  if($usersHtml==='') $usersHtml='<tr><td colspan="5" class="empty">No OpenVPN users yet.</td></tr>';
  $activeHtml='';
  foreach($active as $c){ $u=$c['username']?:$c['common_name']; $activeHtml.='<tr><td><strong>'.h($u).'</strong></td><td><span class="badge">'.h($c['source']).'</span></td><td class="small">'.h($c['gui_version']?:'-').'</td><td>'.h($c['real_address']).'</td><td>'.h($c['virtual_address']?:'-').'</td><td>'.h($c['connected_since']).'</td><td>'.h(human_bytes($c['bytes_received'])).'</td><td>'.h(human_bytes($c['bytes_sent'])).'</td></tr>'; }
  if($activeHtml==='') $activeHtml='<tr><td colspan="8" class="empty">No active OpenVPN devices.</td></tr>';
  $logsHtml='';
  foreach($logs as $r){ $logsHtml.='<tr><td>'.h($r['event_time']).'</td><td>'.h($r['username']?:$r['common_name']).'</td><td>'.h($r['real_ip']).'</td><td>'.h($r['virtual_ip']).'</td><td class="small">'.h($r['gui_version']?:'-').'</td></tr>'; }
  if($logsHtml==='') $logsHtml='<tr><td colspan="5" class="empty">No OpenVPN logs yet.</td></tr>';
  return ['users'=>$usersHtml,'active'=>$activeHtml,'logs'=>$logsHtml];
}
function oc_users(){ $f=DATA_DIR.'/oc_users.csv'; $rows=[]; if(!is_readable($f)) return $rows; foreach(file($f,FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES) as $line){ $p=explode('|',$line); if(trim($p[0]??'')!=='') $rows[]=['username'=>trim($p[0]),'blocked'=>(int)($p[1]??0)]; } return $rows; }
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
function oc_logs($limit=40){ $f=DATA_DIR.'/oc_events.sqlite'; if(!is_file($f)) return []; $db=new SQLite3($f); $res=$db->query('SELECT * FROM oc_events ORDER BY id DESC LIMIT '.(int)$limit); $rows=[]; while($res && $r=$res->fetchArray(SQLITE3_ASSOC)) $rows[]=$r; return $rows; }
function openconnect_html($users,$sessions,$logs){
  $usersHtml=''; foreach($users as $u){ $name=$u['username']; $usersHtml.='<tr><td><strong>'.h($name).'</strong></td><td>'.(((int)$u['blocked']===1)?'<span class="badge red">Blocked</span>':'<span class="badge green">Active</span>').'</td><td><form method="post" class="actions"><input type="hidden" name="action" value="update"><input type="hidden" name="username" value="'.h($name).'"><input name="password" placeholder="New password" required><button class="btn">Update</button></form></td><td class="actions"><form method="post" style="display:inline"><input type="hidden" name="username" value="'.h($name).'">'.(((int)$u['blocked']===1)?'<input name="password" placeholder="Password to unblock" required><button class="btn yellow" name="action" value="unblock">Unblock</button>':'<button class="btn red" name="action" value="block">Block</button>').'</form><form method="post" style="display:inline" onsubmit="return confirm(\'Delete this user?\')"><input type="hidden" name="username" value="'.h($name).'"><button class="btn red" name="action" value="delete">Delete</button></form></td></tr>'; }
  if($usersHtml==='') $usersHtml='<tr><td colspan="4" class="empty">No OpenConnect users yet.</td></tr>';
  $sessionsHtml=''; foreach($sessions as $s){ $sessionsHtml.='<tr><td>'.h($s['id']).'</td><td><strong>'.h($s['user']).'</strong></td><td>'.h($s['real_ip']).'</td><td>'.h($s['vpn_ip']).'</td><td>'.h($s['device']).'</td><td>'.h($s['since']).'</td></tr>'; }
  if($sessionsHtml==='') $sessionsHtml='<tr><td colspan="6" class="empty">No active OpenConnect session.</td></tr>';
  $logsHtml=''; foreach($logs as $r){ $logsHtml.='<tr><td>'.h($r['event_time']).'</td><td>'.h($r['event_type']).'</td><td>'.h($r['username']).'</td><td>'.h($r['real_ip']).'</td><td>'.h($r['vpn_ip']).'</td><td>'.h(human_bytes($r['bytes_in'])).'</td><td>'.h(human_bytes($r['bytes_out'])).'</td></tr>'; }
  if($logsHtml==='') $logsHtml='<tr><td colspan="7" class="empty">No OpenConnect logs yet.</td></tr>';
  return ['users'=>$usersHtml,'sessions'=>$sessionsHtml,'logs'=>$logsHtml];
}
function v2ray_env(){ $env=[]; $f=DATA_DIR.'/v2ray.env'; if(is_file($f)){ foreach(file($f,FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES) as $line){ if(strpos($line,'=')!==false){[$k,$v]=explode('=',$line,2); $env[$k]=$v; } } } return $env; }
function v2ray_active($port){ $port=(int)$port; return trim((string)shell_exec("ss -Htn state established '( sport = :$port )' 2>/dev/null | awk '{print \$5}' | cut -d: -f1 | sort -u | wc -l")); }
function proto_payload($proto){
  if($proto==='openvpn'){
    $users=ovpn_users(); $active=ovpn_active(); $logs=ovpn_logs();
    return ['proto'=>'openvpn','name'=>'OpenVPN','installed'=>proto_enabled('OPENVPN'),'running'=>svc_running('openvpn'),'ports'=>['udp'=>cfgv('OVPN_UDP_PORT','1194'),'tcp'=>cfgv('OVPN_TCP_PORT','8443')],'counts'=>['users'=>count($users),'active'=>count($active)],'html'=>openvpn_html($users,$active,$logs)];
  }
  if($proto==='openconnect'){
    $users=oc_users(); $sessions=oc_sessions(); $logs=oc_logs(); $port=cfgv('OC_PORT','443'); $server=$_SERVER['SERVER_ADDR']??$_SERVER['SERVER_NAME']??'SERVER_IP'; $url='https://'.$server.':'.$port;
    return ['proto'=>'openconnect','name'=>'OpenConnect','installed'=>proto_enabled('OPENCONNECT'),'running'=>svc_running('openconnect'),'port'=>$port,'server_url'=>$url,'counts'=>['users'=>count($users),'active'=>count($sessions)],'html'=>openconnect_html($users,$sessions,$logs)];
  }
  if($proto==='v2ray'){
    $env=v2ray_env(); $port=(int)($env['V2_PORT']??cfgv('V2_PORT','4443')); $uuid=$env['V2_UUID']??''; $host=$env['SERVER_ADDR']??($_SERVER['SERVER_ADDR']??'SERVER_IP'); $link='vless://'.$uuid.'@'.$host.':'.$port.'?encryption=none&security=none&type=tcp#VPN-Panel-V2Ray';
    return ['proto'=>'v2ray','name'=>'V2Ray/Xray','installed'=>proto_enabled('V2RAY'),'running'=>svc_running('v2ray'),'port'=>$port,'host'=>$host,'uuid'=>$uuid,'link'=>$link,'active_ips'=>v2ray_active($port),'manual'=>"Address: {$host}\nPort: {$port}\nUUID: {$uuid}\nProtocol: VLESS\nNetwork: TCP\nSecurity: None\nEncryption: None"];
  }
  return null;
}
$proto=$_GET['proto']??'all';
$allowed=['openvpn','openconnect','v2ray','all'];
if(!in_array($proto,$allowed,true)){ http_response_code(400); echo json_encode(['ok'=>false,'error'=>'Invalid protocol']); exit; }
if($proto==='all'){
  echo json_encode(['ok'=>true,'updated_at'=>date('Y-m-d H:i:s'),'protocols'=>['openvpn'=>proto_payload('openvpn'),'openconnect'=>proto_payload('openconnect'),'v2ray'=>proto_payload('v2ray')]]);
} else {
  $payload=proto_payload($proto); $payload['ok']=true; $payload['updated_at']=date('Y-m-d H:i:s'); echo json_encode($payload);
}
