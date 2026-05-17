<?php
require __DIR__.'/../config.php';
require __DIR__.'/../status_lib.php';
header('Content-Type: application/json; charset=utf-8');
$token=(string)($_GET['token'] ?? $_SERVER['HTTP_X_NODE_TOKEN'] ?? '');
$expected=setting_get('node_api_token','');
if($expected==='' || !hash_equals($expected,$token)){
  http_response_code(403);
  echo json_encode(['ok'=>false,'error'=>'Forbidden']);
  exit;
}
if(!is_node_panel()){
  http_response_code(403);
  echo json_encode(['ok'=>false,'error'=>'This panel is not in node/hybrid mode']);
  exit;
}
echo json_encode(ms_local_status());
