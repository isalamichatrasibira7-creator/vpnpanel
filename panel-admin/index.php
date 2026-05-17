<?php
require __DIR__.'/config.php'; require_login();
set_time_limit(0); ini_set('max_execution_time','0');
function svc_on($p){ exec('sudo -n /usr/local/bin/vpn-control.sh status '.escapeshellarg($p).' >/dev/null 2>&1',$o,$c); return $c===0; }
function run_control($args){ return cli('sudo -n /usr/local/bin/vpn-control.sh '.$args); }
function run_bg_control($args,$proto){
  $safe=preg_replace('/[^a-z0-9_-]/i','',$proto);
  $dir=DATA_DIR.'/install-logs'; if(!is_dir($dir)) @mkdir($dir,0775,true);
  $log=$dir.'/'.$safe.'.log';
  @file_put_contents($log, "===== [".date('Y-m-d H:i:s')."] Panel install started: ".$safe." =====\nCommand: vpn-control.sh ".$args."\n\n", LOCK_EX);
  @chmod($log,0664);
  $cmd='nohup sudo -n /usr/local/bin/vpn-control.sh '.$args.' >> '.escapeshellarg($log).' 2>&1 < /dev/null & echo $!';
  exec($cmd,$out,$code); $pid=trim($out[0]??''); if($pid!=='') @file_put_contents(DATA_DIR.'/vpn-panel-install-'.$safe.'.pid',$pid,LOCK_EX); return [$code,$pid,$log];
}
function valid_port($p){ return is_numeric($p) && (int)$p>=1 && (int)$p<=65535; }
$msg='';$err='';
if($_SERVER['REQUEST_METHOD']==='POST'){
  $action=$_POST['action']??''; $proto=$_POST['proto']??'';
  if(in_array($action,['start','stop','restart'],true) && in_array($proto,['openvpn','openconnect','v2ray'],true)){ [$c,$o]=run_control($action.' '.escapeshellarg($proto)); $c===0?$msg=$o:$err=$o; }
  if($action==='quick_install' && in_array($proto,['openvpn','openconnect','v2ray'],true)){
    if($proto==='openvpn'){
      $udp=$_POST['udp_port']??1194; $tcp=$_POST['tcp_port']??8443;
      if(!valid_port($udp)||!valid_port($tcp)||((int)$udp===(int)$tcp)) $err='Invalid OpenVPN ports.'; else [$c,$pid,$log]=run_bg_control('install openvpn '.(int)$udp.' '.(int)$tcp,'openvpn');
    } elseif($proto==='openconnect'){
      $port=$_POST['port']??443; if(!valid_port($port)) $err='Invalid OpenConnect port.'; else [$c,$pid,$log]=run_bg_control('install openconnect '.(int)$port,'openconnect');
    } else {
      $port=$_POST['port']??4443; if(!valid_port($port)) $err='Invalid V2Ray port.'; else [$c,$pid,$log]=run_bg_control('install v2ray '.(int)$port,'v2ray');
    }
    if(!$err) $c===0?$msg='Install started'.($pid?' (PID '.$pid.')':'').'. Open System Control to watch mini live logs.':$err='Failed to start install job. Check sudo permission and Apache error log.';
  }
}
$bw=vps_bandwidth();
$cards=[['OPENVPN','openvpn','OpenVPN','ovpn-card'],['OPENCONNECT','openconnect','OpenConnect','oc-card'],['V2RAY','v2ray','V2Ray/Xray','v2-card']];
render_header('VPN Panel'); ?>
<?php if($msg): ?><div class="flash"><?=esc($msg)?></div><?php endif; ?><?php if($err): ?><div class="flash error"><?=esc($err)?></div><?php endif; ?>
<div class="panel-banner"><div class="toolbar"><div><h2 class="section-title">Modern Live VPN Dashboard</h2><div class="small"><span class="live-dot"></span> Cards update every 5 seconds in background.</div></div><div class="actions"><a class="btn" href="system_control.php">System Control</a><?php if(is_main_panel()): ?><a class="btn green" href="servers.php">+ Add VPS</a><?php endif; ?><a class="btn gray" href="settings.php">Role Settings</a></div></div></div>
<?php if(is_main_panel()): ?>
<div class="card" style="margin-bottom:18px"><div class="toolbar"><div><h2 class="section-title">Multi VPS Realtime Dashboard</h2><div id="clusterUpdated" class="small">Background update every 5 seconds.</div></div><a class="btn" href="servers.php">Manage VPS</a></div><div id="clusterServerCards" class="cluster-grid"><div class="card empty">Loading VPS data...</div></div></div>
<div class="grid" style="margin-bottom:18px"><div class="card chart-card"><canvas id="chartOpenvpn"></canvas></div><div class="card chart-card"><canvas id="chartOpenconnect"></canvas></div><div class="card chart-card"><canvas id="chartV2ray"></canvas></div></div>
<?php endif; ?>
<div class="hero-grid">
<?php foreach($cards as $c): $installed=proto_enabled($c[0]); $running=svc_on($c[1]); ?>
  <div class="card gradient-card protocol-card <?=esc($c[3])?>" data-dash-card="<?=esc($c[1])?>">
    <div class="toolbar"><div><div class="muted"><?=esc($c[2])?></div><div id="dashInstalled-<?=esc($c[1])?>" class="kpi <?=$installed?'status-on':'status-off'?>"><?=$installed?'ON':'OFF'?></div></div><span id="dashBadge-<?=esc($c[1])?>" class="badge <?=$running?'green':'red'?>"><?=$running?'RUNNING':'STOPPED'?></span></div>
    <div class="small">Port: <strong id="dashPort-<?=esc($c[1])?>"><?php if($c[1]==='openvpn') echo 'UDP '.esc(cfgv('OVPN_UDP_PORT','1194')).' / TCP '.esc(cfgv('OVPN_TCP_PORT','8443')); elseif($c[1]==='openconnect') echo esc(cfgv('OC_PORT','443')); else echo esc(cfgv('V2_PORT','4443')); ?></strong></div>
    <div class="small">Live count: <strong id="dashCount-<?=esc($c[1])?>">-</strong></div><br>
    <form method="post" class="actions"><input type="hidden" name="proto" value="<?=esc($c[1])?>"><button class="btn green" name="action" value="start">Start</button><button class="btn yellow" name="action" value="restart">Restart</button><button class="btn red" name="action" value="stop">Stop</button></form>
    <br><?php if(!$installed): ?><a class="btn" href="system_control.php?log=<?=esc($c[1])?>">Install / Set Port / Mini Log</a><?php else: ?><a class="btn" href="<?=esc($c[1]==='v2ray'?'v2ray.php':($c[1].'.php'))?>">Open Panel</a><?php endif; ?>
  </div>
<?php endforeach; ?>
</div>
<div class="card bandwidth-card" style="margin-top:18px"><div class="toolbar"><div><h2 class="section-title" style="margin-bottom:6px">Total VPS Bandwidth</h2><div class="small">System bandwidth from vnStat.</div></div><span class="badge green"><?= $bw['ready']?'Tracking ON':'Waiting for data'?></span></div><div class="grid"><div class="card soft-card"><div class="muted">Today</div><div class="kpi small-kpi"><?=esc(human_bytes($bw['today']))?></div></div><div class="card soft-card"><div class="muted">This Month</div><div class="kpi small-kpi"><?=esc(human_bytes($bw['month']))?></div></div><div class="card soft-card"><div class="muted">All Time</div><div class="kpi small-kpi"><?=esc(human_bytes($bw['total']))?></div></div></div></div>
<div class="card" style="margin-top:18px"><div class="toolbar"><div><h2 class="section-title" style="margin-bottom:6px">Installed Ports</h2><div class="small">Vertical cards for clean pro view.</div></div><a class="btn" href="system_control.php">System Control</a></div><div class="port-list"><div class="port-item"><strong>OpenVPN UDP</strong><span class="port-value" id="portOvpnUdp"><?=esc(cfgv('OVPN_UDP_PORT','1194'))?></span></div><div class="port-item"><strong>OpenVPN TCP</strong><span class="port-value" id="portOvpnTcp"><?=esc(cfgv('OVPN_TCP_PORT','8443'))?></span></div><div class="port-item"><strong>OpenConnect</strong><span class="port-value" id="portOc"><?=esc(cfgv('OC_PORT','443'))?></span></div><div class="port-item"><strong>V2Ray/Xray</strong><span class="port-value" id="portV2"><?=esc(cfgv('V2_PORT','4443'))?></span></div></div></div>
<script>
async function refreshDashboard(){try{const r=await fetch('api_status.php?proto=all&_='+Date.now(),{cache:'no-store'});const d=await r.json();if(!d.ok)return;const p=d.protocols;function set(proto,obj,port,count){const ins=document.getElementById('dashInstalled-'+proto), b=document.getElementById('dashBadge-'+proto), po=document.getElementById('dashPort-'+proto), co=document.getElementById('dashCount-'+proto); if(ins){ins.textContent=obj.installed?'ON':'OFF';ins.className='kpi '+(obj.installed?'status-on':'status-off')} if(b){b.className='badge '+(obj.running?'green':'red');b.textContent=obj.running?'RUNNING':'STOPPED'} if(po)po.textContent=port; if(co)co.textContent=count;} set('openvpn',p.openvpn,'UDP '+p.openvpn.ports.udp+' / TCP '+p.openvpn.ports.tcp,p.openvpn.counts.active+' active'); set('openconnect',p.openconnect,p.openconnect.port,p.openconnect.counts.active+' active'); set('v2ray',p.v2ray,p.v2ray.port,(p.v2ray.active_ips||0)+' active IPs'); document.getElementById('portOvpnUdp').textContent=p.openvpn.ports.udp;document.getElementById('portOvpnTcp').textContent=p.openvpn.ports.tcp;document.getElementById('portOc').textContent=p.openconnect.port;document.getElementById('portV2').textContent=p.v2ray.port;}catch(e){}}
refreshDashboard();setInterval(refreshDashboard,5000);
</script>
<script src="assets/multirole.js"></script>
<?php render_footer(); ?>
