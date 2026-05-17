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
