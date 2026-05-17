<?php
require __DIR__.'/config.php'; require_login();
header('Content-Type: application/json; charset=utf-8');
$proto = $_GET['proto'] ?? 'openvpn';
$allowed = ['openvpn','openconnect','v2ray'];
if(!in_array($proto, $allowed, true)){
  http_response_code(400);
  echo json_encode(['ok'=>false,'error'=>'Invalid protocol']);
  exit;
}
$lines = isset($_GET['lines']) ? (int)$_GET['lines'] : (isset($_GET['tail']) ? (int)$_GET['tail'] : 250);
if($lines < 1) $lines = 1;
if($lines > 1000) $lines = 1000;
$safe = preg_replace('/[^a-z0-9_-]/i','', $proto);
$preferredDir = DATA_DIR.'/install-logs';
if(!is_dir($preferredDir)) @mkdir($preferredDir,0775,true);
$candidates = [
  $preferredDir.'/'.$safe.'.log',
  DATA_DIR.'/vpn-panel-install-'.$safe.'.log',
  '/var/log/vpn-panel-install-'.$safe.'.log'
];
$logFile = $candidates[0];
$logExists = false;
$newestMtime = -1;
foreach($candidates as $f){
  if(is_file($f) && is_readable($f)){
    $mtime = @filemtime($f) ?: 0;
    if($mtime > $newestMtime){ $newestMtime = $mtime; $logFile = $f; $logExists = true; }
  }
}
$pidFile = DATA_DIR.'/vpn-panel-install-'.$safe.'.pid';
$pid = is_file($pidFile) ? trim((string)@file_get_contents($pidFile)) : '';
$running = false;
if($pid !== '' && ctype_digit($pid)){
  $cmd = 'ps -p '.(int)$pid.' -o args= 2>/dev/null';
  $args = trim((string)shell_exec($cmd));
  $running = ($args !== '' && strpos($args, 'vpn-control.sh') !== false && strpos($args, 'install '.$safe) !== false);
}
$log = '';
if($logExists){
  $cmd = 'tail -n '.(int)$lines.' '.escapeshellarg($logFile).' 2>/dev/null';
  $log = (string)shell_exec($cmd);
} else {
  $log = "No recent install log for {$safe}.\nClick Install and this card will start showing logs automatically.";
}
$status = 'idle';
if($running){
  $status = 'running';
} elseif($logExists && preg_match('/INSTALL\s+SUCCESSFULLY\s+COMPLETED|SUCCESSFULLY\s+COMPLETED/i', $log)){
  $status = 'success';
} elseif($logExists && preg_match('/INSTALL\s+FAILED|ERROR:|FAILED|did not start|exit code/i', $log)){
  $status = 'failed';
} elseif($logExists && trim($log) !== ''){
  $status = 'ready';
}
echo json_encode([
  'ok'=>true,
  'proto'=>$safe,
  'status'=>$status,
  'running'=>$running,
  'pid'=>$pid,
  'log_file'=>$logFile,
  'log'=>$log,
  'updated_at'=>date('Y-m-d H:i:s')
]);
