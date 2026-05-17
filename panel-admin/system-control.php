<?php
require __DIR__.'/config.php'; require_login();
set_time_limit(0); ini_set('max_execution_time','0');

function run_control($args){ return cli('sudo -n /usr/local/bin/vpn-control.sh '.$args); }
function valid_port($p){ return is_numeric($p) && (int)$p>=1 && (int)$p<=65535; }
function is_ajax_request(){ return ($_POST['ajax'] ?? '') === '1' || strtolower($_SERVER['HTTP_X_REQUESTED_WITH'] ?? '') === 'xmlhttprequest'; }
function install_log_dir(){ $dir = DATA_DIR.'/install-logs'; if(!is_dir($dir)) @mkdir($dir,0775,true); return $dir; }
function run_bg_control($args,$proto){
  $safe=preg_replace('/[^a-z0-9_-]/i','',$proto);
  $dir=install_log_dir();
  $log=$dir.'/'.$safe.'.log';
  @file_put_contents($log, "===== [".date('Y-m-d H:i:s')."] Panel install started: ".$safe." =====\nCommand: vpn-control.sh ".$args."\n\n", LOCK_EX);
  @chmod($log,0664);
  $cmd='nohup sudo -n /usr/local/bin/vpn-control.sh '.$args.' >> '.escapeshellarg($log).' 2>&1 < /dev/null & echo $!';
  exec($cmd,$out,$code);
  $pid=trim($out[0]??'');
  if($pid!=='') @file_put_contents(DATA_DIR.'/vpn-panel-install-'.$safe.'.pid',$pid,LOCK_EX);
  return [$code, $pid, $log];
}
function svc_on($p){ exec('sudo -n /usr/local/bin/vpn-control.sh status '.escapeshellarg($p).' >/dev/null 2>&1',$o,$c); return $c===0; }
function installed($key){ return proto_enabled($key); }

function handle_panel_action(){
  $msg=''; $err=''; $payload=[];
  $action=$_POST['action']??''; $proto=$_POST['proto']??'';
  if(!in_array($proto,['openvpn','openconnect','v2ray'],true)) return ['ok'=>false,'message'=>'','error'=>'Invalid protocol','proto'=>$proto];
  if(in_array($action,['start','stop','restart'],true)){
    [$c,$o]=run_control($action.' '.escapeshellarg($proto));
    return ['ok'=>$c===0,'message'=>$c===0?$o:'','error'=>$c===0?'':$o,'proto'=>$proto,'action'=>$action];
  }
  if($action==='install'){
    if($proto==='openvpn'){
      $udp=$_POST['udp_port']??1194; $tcp=$_POST['tcp_port']??8443;
      if(!valid_port($udp)||!valid_port($tcp)||((int)$udp===(int)$tcp)) $err='Invalid OpenVPN ports. Use 1-65535 and UDP/TCP must be different.';
      else { $udp=(int)$udp; $tcp=(int)$tcp; [$c,$pid,$log]=run_bg_control('install openvpn '.$udp.' '.$tcp,'openvpn'); $payload=['pid'=>$pid??'','log'=>$log??'']; }
    } elseif($proto==='openconnect'){
      $port=$_POST['port']??443;
      if(!valid_port($port)) $err='Invalid OpenConnect port.';
      else { $port=(int)$port; [$c,$pid,$log]=run_bg_control('install openconnect '.$port,'openconnect'); $payload=['pid'=>$pid??'','log'=>$log??'']; }
    } else {
      $port=$_POST['port']??4443;
      if(!valid_port($port)) $err='Invalid V2Ray port.';
      else { $port=(int)$port; [$c,$pid,$log]=run_bg_control('install v2ray '.$port,'v2ray'); $payload=['pid'=>$pid??'','log'=>$log??'']; }
    }
    if($err) return ['ok'=>false,'message'=>'','error'=>$err,'proto'=>$proto,'action'=>$action];
    return ['ok'=>$c===0,'message'=>$c===0?'Install started'.(!empty($pid)?' (PID '.$pid.')':'').'. Live mini log is now active.':'','error'=>$c===0?'':'Failed to start install job. Check sudo permission and Apache error log.','proto'=>$proto,'action'=>$action] + $payload;
  }
  if($action==='change_port'){
    if($proto==='openvpn'){
      $udp=$_POST['udp_port']??cfgv('OVPN_UDP_PORT','1194'); $tcp=$_POST['tcp_port']??cfgv('OVPN_TCP_PORT','8443');
      if(!valid_port($udp)||!valid_port($tcp)||((int)$udp===(int)$tcp)) $err='Invalid OpenVPN ports. Use 1-65535 and UDP/TCP must be different.';
      else { $udp=(int)$udp; $tcp=(int)$tcp; [$c,$o]=run_control('change-port openvpn '.$udp.' '.$tcp); }
    } elseif($proto==='openconnect'){
      $port=$_POST['port']??cfgv('OC_PORT','443'); if(!valid_port($port)) $err='Invalid OpenConnect port.'; else { $port=(int)$port; [$c,$o]=run_control('change-port openconnect '.$port); }
    } else {
      $port=$_POST['port']??cfgv('V2_PORT','4443'); if(!valid_port($port)) $err='Invalid V2Ray port.'; else { $port=(int)$port; [$c,$o]=run_control('change-port v2ray '.$port); }
    }
    if($err) return ['ok'=>false,'message'=>'','error'=>$err,'proto'=>$proto,'action'=>$action];
    return ['ok'=>$c===0,'message'=>$c===0?$o:'','error'=>$c===0?'':$o,'proto'=>$proto,'action'=>$action];
  }
  return ['ok'=>false,'message'=>'','error'=>'Invalid action','proto'=>$proto,'action'=>$action];
}

$msg=''; $err='';
$active_log_proto = $_GET['log'] ?? 'openvpn';
if(!in_array($active_log_proto,['openvpn','openconnect','v2ray'],true)) $active_log_proto='openvpn';
if($_SERVER['REQUEST_METHOD']==='POST'){
  $result = handle_panel_action();
  if(!empty($result['proto']) && in_array($result['proto'],['openvpn','openconnect','v2ray'],true)) $active_log_proto=$result['proto'];
  if(is_ajax_request()){
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($result);
    exit;
  }
  if($result['ok']) $msg=$result['message']; else $err=$result['error'];
}
$items=[
 ['key'=>'OPENVPN','proto'=>'openvpn','name'=>'OpenVPN','ports'=>'UDP '.cfgv('OVPN_UDP_PORT','1194').' / TCP '.cfgv('OVPN_TCP_PORT','8443'),'class'=>'ovpn-card'],
 ['key'=>'OPENCONNECT','proto'=>'openconnect','name'=>'OpenConnect','ports'=>cfgv('OC_PORT','443'),'class'=>'oc-card'],
 ['key'=>'V2RAY','proto'=>'v2ray','name'=>'V2Ray/Xray','ports'=>cfgv('V2_PORT','4443'),'class'=>'v2-card'],
];
render_header('System Control'); ?>
<div id="ajaxMessage"><?php if($msg): ?><div class="flash"><?=esc($msg)?></div><?php endif; ?><?php if($err): ?><div class="flash error"><?=esc($err)?></div><?php endif; ?></div>
<div class="grid protocol-control-grid">
<?php foreach($items as $it): $is=installed($it['key']); $running=svc_on($it['proto']); ?>
  <div class="card gradient-card protocol-card <?=esc($it['class'])?>" data-proto-card="<?=esc($it['proto'])?>">
    <div class="toolbar"><h2 class="section-title"><?=esc($it['name'])?></h2><span id="svcBadge-<?=esc($it['proto'])?>" class="badge <?=$running?'green':'red'?>"><?=$running?'RUNNING':'STOPPED'?></span></div>
    <div class="small">Installed: <strong id="installed-<?=esc($it['proto'])?>"><?=$is?'YES':'NO'?></strong></div>
    <div class="small">Port: <strong id="portText-<?=esc($it['proto'])?>"><?=esc($it['ports'])?></strong></div><br>
    <form method="post" class="actions ajax-action-form" data-proto="<?=esc($it['proto'])?>">
      <input type="hidden" name="proto" value="<?=esc($it['proto'])?>"><input type="hidden" name="action" value="">
      <button type="submit" class="btn green" data-action="start">Start</button><button type="submit" class="btn yellow" data-action="restart">Restart</button><button type="submit" class="btn red" data-action="stop">Stop</button>
    </form><br>
    <form method="post" class="install-form ajax-action-form" data-proto="<?=esc($it['proto'])?>">
      <input type="hidden" name="proto" value="<?=esc($it['proto'])?>"><input type="hidden" name="action" value="<?=$is?'change_port':'install'?>">
      <?php if($it['proto']==='openvpn'): ?>
        <label>UDP Port</label><input name="udp_port" value="<?=esc(cfgv('OVPN_UDP_PORT','1194'))?>"><br><br><label>TCP Port</label><input name="tcp_port" value="<?=esc(cfgv('OVPN_TCP_PORT','8443'))?>">
      <?php else: ?>
        <label>Port</label><input name="port" value="<?=esc($it['proto']==='openconnect'?cfgv('OC_PORT','443'):cfgv('V2_PORT','4443'))?>">
      <?php endif; ?><br><br>
      <?php if(!$is): ?><button type="submit" class="btn green install-btn">Install <?=esc($it['name'])?></button><?php else: ?><button type="submit" class="btn">Change Port</button><?php endif; ?>
    </form>
    <div class="mini-log-wrap">
      <div class="mini-log-head"><span>Live install log</span><span id="miniLogBadge-<?=esc($it['proto'])?>" class="badge">IDLE</span></div>
      <pre class="mini-log" id="miniLog-<?=esc($it['proto'])?>">No recent install log</pre>
    </div>
  </div>
<?php endforeach; ?>
</div>
<div class="card install-console" style="margin-top:18px">
  <div class="toolbar">
    <div>
      <h2 class="section-title">Full Live Install Console</h2>
      <div class="small">Mini card log only shows last 5 lines. Full log stays here when you need details.</div>
    </div>
    <span id="logBadge" class="badge yellow">LOADING</span>
  </div>
  <div class="actions" style="margin-bottom:12px">
    <button type="button" class="btn gray log-tab" data-proto="openvpn">OpenVPN Log</button>
    <button type="button" class="btn gray log-tab" data-proto="openconnect">OpenConnect Log</button>
    <button type="button" class="btn gray log-tab" data-proto="v2ray">V2Ray Log</button>
  </div>
  <div class="small" id="logMeta">Waiting for log...</div>
  <pre id="installLog" class="log-box">Loading install log...</pre>
</div>
<script>
let currentLogProto = <?=json_encode($active_log_proto)?>;
const protos = ['openvpn','openconnect','v2ray'];
function badgeClass(status){ if(status === 'running') return 'badge yellow'; if(status === 'success') return 'badge green'; if(status === 'failed') return 'badge red'; if(status === 'ready') return 'badge green'; return 'badge'; }
function svcBadge(el, running){ if(!el) return; el.className = 'badge ' + (running ? 'green' : 'red'); el.textContent = running ? 'RUNNING' : 'STOPPED'; }
function flashMessage(msg, ok){ const wrap=document.getElementById('ajaxMessage'); if(!wrap) return; if(!msg){wrap.innerHTML=''; return;} wrap.innerHTML='<div class="flash '+(ok?'':'error')+'"></div>'; wrap.firstElementChild.textContent=msg; }
async function loadMiniLog(proto){
  try{
    const res = await fetch('install_log.php?proto=' + encodeURIComponent(proto) + '&tail=5&_=' + Date.now(), {cache:'no-store'});
    const data = await res.json();
    const box = document.getElementById('miniLog-' + proto);
    const badge = document.getElementById('miniLogBadge-' + proto);
    if(!box || !badge) return;
    if(!data.ok){ box.textContent = data.error || 'Unable to read log'; badge.className='badge red'; badge.textContent='ERROR'; return; }
    box.textContent = (data.log || 'No recent install log').trim();
    badge.className = badgeClass(data.status);
    badge.textContent = data.status.toUpperCase();
  }catch(e){ const box=document.getElementById('miniLog-'+proto); if(box) box.textContent='Log read failed'; }
}
async function loadStatus(){
  try{
    const res = await fetch('api_status.php?proto=all&_=' + Date.now(), {cache:'no-store'});
    const data = await res.json(); if(!data.ok) return;
    const p = data.protocols;
    if(p.openvpn){ svcBadge(document.getElementById('svcBadge-openvpn'), p.openvpn.running); document.getElementById('installed-openvpn').textContent = p.openvpn.installed?'YES':'NO'; document.getElementById('portText-openvpn').textContent = 'UDP ' + p.openvpn.ports.udp + ' / TCP ' + p.openvpn.ports.tcp; }
    if(p.openconnect){ svcBadge(document.getElementById('svcBadge-openconnect'), p.openconnect.running); document.getElementById('installed-openconnect').textContent = p.openconnect.installed?'YES':'NO'; document.getElementById('portText-openconnect').textContent = p.openconnect.port; }
    if(p.v2ray){ svcBadge(document.getElementById('svcBadge-v2ray'), p.v2ray.running); document.getElementById('installed-v2ray').textContent = p.v2ray.installed?'YES':'NO'; document.getElementById('portText-v2ray').textContent = p.v2ray.port; }
  }catch(e){}
}
async function loadInstallLog(){
  try{
    const res = await fetch('install_log.php?proto=' + encodeURIComponent(currentLogProto) + '&lines=350&_=' + Date.now(), {cache:'no-store'});
    const data = await res.json();
    const box = document.getElementById('installLog'); const badge = document.getElementById('logBadge'); const meta = document.getElementById('logMeta');
    if(!data.ok){ box.textContent = data.error || 'Unable to read log'; badge.className='badge red'; badge.textContent='ERROR'; return; }
    box.textContent = data.log || 'No log yet.'; box.scrollTop = box.scrollHeight;
    badge.className = badgeClass(data.status); badge.textContent = data.status.toUpperCase();
    meta.textContent = 'Protocol: ' + data.proto + ' | PID: ' + (data.pid || '-') + ' | File: ' + data.log_file + ' | Updated: ' + data.updated_at;
  }catch(e){ document.getElementById('installLog').textContent = 'Log read failed: ' + e; }
}
function refreshAll(){ loadStatus(); protos.forEach(loadMiniLog); loadInstallLog(); }
document.querySelectorAll('.log-tab').forEach(btn=>btn.addEventListener('click',()=>{ currentLogProto=btn.dataset.proto; loadInstallLog(); }));
document.querySelectorAll('.ajax-action-form').forEach(form=>form.addEventListener('submit',async (e)=>{
  e.preventDefault();
  const submitter = e.submitter || document.activeElement;
  const hiddenAction = form.querySelector('input[name="action"]');
  if(submitter && submitter.dataset && submitter.dataset.action && hiddenAction) hiddenAction.value = submitter.dataset.action;
  const fd = new FormData(form); fd.set('ajax','1');
  const proto = fd.get('proto') || form.dataset.proto || 'openvpn';
  const action = fd.get('action') || '';
  currentLogProto = proto;
  const oldText = submitter ? submitter.textContent : '';
  if(submitter){ submitter.disabled = true; submitter.textContent = action === 'install' ? 'Starting...' : 'Working...'; }
  flashMessage(action === 'install' ? ('Starting '+proto+' install...') : 'Sending command...', true);
  try{
    const res = await fetch(location.pathname, {method:'POST', body:fd, cache:'no-store', headers:{'X-Requested-With':'XMLHttpRequest'}});
    const data = await res.json();
    flashMessage(data.ok ? (data.message || 'Done') : (data.error || 'Action failed'), !!data.ok);
    setTimeout(refreshAll, 500);
    if(action === 'install') { setTimeout(()=>loadMiniLog(proto), 900); setTimeout(()=>loadInstallLog(), 900); }
  }catch(err){ flashMessage('Request failed: '+err, false); }
  finally{ if(submitter){ setTimeout(()=>{ submitter.disabled=false; submitter.textContent=oldText; }, action === 'install' ? 2500 : 700); } }
}));
refreshAll(); setInterval(refreshAll,3000);
</script>
<?php render_footer(); ?>
