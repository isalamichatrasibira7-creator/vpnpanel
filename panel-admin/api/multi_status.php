<?php
require __DIR__.'/../config.php';
require __DIR__.'/../status_lib.php';
require_login();
header('Content-Type: application/json; charset=utf-8');
if(!is_main_panel()){
  http_response_code(403);
  echo json_encode(['ok'=>false,'error'=>'This panel is not in main/hybrid mode']);
  exit;
}
echo json_encode(ms_cluster_status());
