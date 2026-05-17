<?php
// Shared Multi-Role status helpers. Requires config.php first.
function ms_svc_running($proto){
  $proto=preg_replace('/[^a-z0-9_-]/i','',$proto);
  exec('sudo -n /usr/local/bin/vpn-control.sh status '.escapeshellarg($proto).' >/dev/null 2>&1',$o,$c);
  return $c===0;
}
function ms_parse_ovpn_status_file($file){
  $rows=[]; if(!is_readable($file)) return $rows;
  foreach(file($file,FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES) as $line){
    $line=trim($line); if(strpos($line,'CLIENT_LIST')!==0) continue;
    $p=preg_split('/[,\t]/',$line); if(count($p)<3) continue;
    if(count($p)>=10){
      $rows[]=['username'=>$p[9]??($p[1]??''),'common_name'=>$p[1]??'','real_address'=>$p[2]??'','virtual_address'=>$p[3]??'','bytes_received'=>(int)($p[5]??0),'bytes_sent'=>(int)($p[6]??0),'connected_since'=>$p[7]??''];
    } else {
      $rows[]=['username'=>$p[1]??'','common_name'=>$p[1]??'','real_address'=>$p[2]??'','virtual_address'=>'','bytes_received'=>(int)($p[3]??0),'bytes_sent'=>(int)($p[4]??0),'connected_since'=>$p[5]??''];
    }
  }
  return $rows;
}
function ms_openvpn_sessions(){
  $rows=[];
  foreach(['/var/log/openvpn/openvpn-status-udp.log'=>'UDP','/var/log/openvpn/openvpn-status-tcp.log'=>'TCP'] as $file=>$proto){
    foreach(ms_parse_ovpn_status_file($file) as $r){ $r['protocol']=$proto; $rows[]=$r; }
  }
  return $rows;
}
function ms_oc_session_ip_from_token($token){
  $token=trim((string)$token," \t\n\r\0\x0B[](),;");
  if(preg_match('/^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/',$token,$m)) $token=$m[1];
  if(preg_match('/^(\d{1,3}(?:\.\d{1,3}){3})(?::\d+)?$/',$token,$m)) $token=$m[1];
  return filter_var($token,FILTER_VALIDATE_IP) ? $token : '';
}
function ms_oc_known_users(){
  $known=[]; $f=DATA_DIR.'/oc_users.csv';
  if(is_readable($f)){
    foreach(file($f,FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES) as $line){
      $p=explode('|',$line); $u=trim($p[0]??''); $blocked=(int)($p[1]??0);
      if($u!=='' && $blocked===0) $known[$u]=true;
    }
  }
  return $known;
}
function ms_openconnect_sessions(){
  $out=shell_exec('sudo -n /usr/local/bin/oc-active-sessions.sh 2>/dev/null');
  $rows=[]; if(!$out) return $rows;
  $known=ms_oc_known_users(); $seen=[];
  foreach(explode("\n",trim($out)) as $line){
    $line=trim($line); if($line===''||stripos($line,'id')===0||$line[0]=='('||strpos($line,'---')===0) continue;
    if(!preg_match('/^\d+\s+/',$line)) continue;
    $p=preg_split('/\s+/',$line); $id=$p[0]??'-'; $user=$p[1]??'';
    if(!preg_match('/^[A-Za-z0-9._-]{3,32}$/',$user)) continue;
    if($known && empty($known[$user])) continue;
    if(preg_match('/\b(disconnected|disconnect|offline|logout|closed)\b/i',$line)) continue;
    $ips=[]; foreach($p as $tok){ $ip=ms_oc_session_ip_from_token($tok); if($ip!=='' && !in_array($ip,$ips,true)) $ips[]=$ip; }
    $vpn='-'; $real='-';
    foreach($ips as $ip){ if(strpos($ip,'10.20.30.')===0){ $vpn=$ip; break; } }
    foreach($ips as $ip){ if($ip!==$vpn){ $real=$ip; break; } }
    if($real==='-' && isset($p[3])){ $ip=ms_oc_session_ip_from_token($p[3]); if($ip!=='') $real=$ip; }
    if($vpn==='-' && isset($p[4])){ $ip=ms_oc_session_ip_from_token($p[4]); if($ip!=='') $vpn=$ip; }
    $device='-'; foreach($p as $tok){ if(preg_match('/^(vpns|tun|vpn|oc|ppp)[A-Za-z0-9_.:-]*$/i',$tok)){ $device=$tok; break; } }
    if($device==='-' && isset($p[5]) && ms_oc_session_ip_from_token($p[5])==='' && !preg_match('/^[()\-]+$/',$p[5])) $device=$p[5];
    $since='live'; if(isset($p[6]) && !preg_match('/^[-()]+$/',$p[6])) $since=implode(' ',array_slice($p,6));
    $key=$user.'|'.$real.'|'.$vpn.'|'.$device; if(isset($seen[$key])) continue; $seen[$key]=1;
    $rows[]=['id'=>$id,'username'=>$user,'real_ip'=>$real,'vpn_ip'=>$vpn,'device'=>$device,'since'=>$since];
  }
  return $rows;
}
function ms_v2ray_sessions($port){
  $port=(int)$port; $rows=[]; if($port<1) return $rows;
  $cmd="ss -Htn state established '( sport = :$port )' 2>/dev/null | awk '{print \$5}' | sed 's/::ffff://' | sed 's/]:/:/' | awk -F: '{print \$1}' | sort -u";
  $out=shell_exec($cmd);
  foreach(explode("\n",trim((string)$out)) as $ip){ $ip=trim($ip); if($ip!=='') $rows[]=['ip'=>$ip]; }
  return $rows;
}
function ms_v2ray_env(){
  $env=[]; $f=DATA_DIR.'/v2ray.env';
  if(is_file($f)){ foreach(file($f,FILE_IGNORE_NEW_LINES|FILE_SKIP_EMPTY_LINES) as $line){ if(strpos($line,'=')!==false){[$k,$v]=explode('=',$line,2); $env[$k]=$v; } } }
  return $env;
}
function ms_local_status(){
  $ovpn=ms_openvpn_sessions();
  $oc=ms_openconnect_sessions();
  $v2env=ms_v2ray_env(); $v2port=(int)($v2env['V2_PORT']??cfgv('V2_PORT','4443')); $v2=ms_v2ray_sessions($v2port);
  $ip=$_SERVER['SERVER_ADDR'] ?? trim((string)shell_exec("hostname -I 2>/dev/null | awk '{print $1}'"));
  return [
    'ok'=>true,
    'server_name'=>server_name(),
    'server_ip'=>$ip ?: 'SERVER_IP',
    'panel_url'=>public_base_url(),
    'role'=>panel_role(),
    'updated_at'=>date('Y-m-d H:i:s'),
    'openvpn'=>['installed'=>proto_enabled('OPENVPN'),'running'=>ms_svc_running('openvpn'),'active'=>count($ovpn),'sessions'=>array_slice($ovpn,0,50)],
    'openconnect'=>['installed'=>proto_enabled('OPENCONNECT'),'running'=>ms_svc_running('openconnect'),'active'=>count($oc),'sessions'=>array_slice($oc,0,50)],
    'v2ray'=>['installed'=>proto_enabled('V2RAY'),'running'=>ms_svc_running('v2ray'),'port'=>$v2port,'active'=>count($v2),'sessions'=>array_slice($v2,0,50)],
    'total_active'=>count($ovpn)+count($oc)+count($v2)
  ];
}
function ms_fetch_node_status($panel_url,$token,$timeout=4){
  $url=normalized_panel_url($panel_url).'/api/node_status.php?token='.rawurlencode($token).'&_='.time();
  $ctx=stream_context_create(['http'=>['timeout'=>$timeout,'ignore_errors'=>true], 'ssl'=>['verify_peer'=>false,'verify_peer_name'=>false]]);
  $raw=@file_get_contents($url,false,$ctx);
  if($raw===false || trim($raw)==='') return ['ok'=>false,'error'=>'No response','url'=>$url];
  $data=json_decode($raw,true);
  if(!is_array($data)) return ['ok'=>false,'error'=>'Invalid JSON','url'=>$url];
  return $data;
}
function ms_remote_servers(){
  ensure_multirole_schema(); $rows=[];
  $res=db()->query('SELECT * FROM servers WHERE enabled=1 ORDER BY sort_order ASC,id ASC');
  while($res && $row=$res->fetchArray(SQLITE3_ASSOC)) $rows[]=$row;
  return $rows;
}
function ms_cluster_status(){
  $servers=[]; $local=ms_local_status(); $local['source']='local'; $servers[]=$local;
  foreach(ms_remote_servers() as $srv){
    $d=ms_fetch_node_status($srv['panel_url'],$srv['api_token']);
    if(!($d['ok']??false)){
      $d=['ok'=>false,'source'=>'remote','server_name'=>$srv['name'],'server_ip'=>$srv['ip_address'],'panel_url'=>$srv['panel_url'],'updated_at'=>date('Y-m-d H:i:s'),'error'=>$d['error']??'Offline','openvpn'=>['active'=>0,'running'=>false,'installed'=>false,'sessions'=>[]],'openconnect'=>['active'=>0,'running'=>false,'installed'=>false,'sessions'=>[]],'v2ray'=>['active'=>0,'running'=>false,'installed'=>false,'sessions'=>[]],'total_active'=>0];
    } else {
      $d['source']='remote';
      $d['server_name']=$d['server_name'] ?: $srv['name'];
      $d['server_ip']=$d['server_ip'] ?: $srv['ip_address'];
      $d['panel_url']=$srv['panel_url'];
    }
    $servers[]=$d;
  }
  return ['ok'=>true,'updated_at'=>date('Y-m-d H:i:s'),'role'=>panel_role(),'servers'=>$servers];
}
