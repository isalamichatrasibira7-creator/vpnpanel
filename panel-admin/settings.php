<?php
require __DIR__.'/config.php'; require_login(); ensure_multirole_schema();
$msg=''; $err='';
if($_SERVER['REQUEST_METHOD']==='POST'){
  $action=$_POST['action'] ?? 'save';
  if($action==='regen_token'){
    setting_set('node_api_token', random_token(32));
    $msg='New node API token generated. Update this token on any main panel where this VPS was added.';
  } else {
    $role=$_POST['panel_role'] ?? 'hybrid';
    $name=trim((string)($_POST['server_name'] ?? ''));
    if(!in_array($role,['main','node','hybrid'],true)) $err='Invalid role selected.';
    elseif($name==='') $err='Server name is required.';
    else { setting_set('panel_role',$role); setting_set('server_name',$name); $msg='Panel settings saved.'; }
  }
}
$role=panel_role(); $token=setting_get('node_api_token',''); $name=server_name(); $base=public_base_url();
render_header('Panel Role / API Token'); ?>
<?php if($msg): ?><div class="flash"><?=esc($msg)?></div><?php endif; ?><?php if($err): ?><div class="flash error"><?=esc($err)?></div><?php endif; ?>
<div class="panel-banner"><div class="toolbar"><div><h2 class="section-title">Panel Role System</h2><div class="small">Same files can run as Main, Node, or Hybrid. Hybrid is best for a main VPS that also hosts VPN services.</div></div><span class="badge green">Current: <?=esc(strtoupper($role))?></span></div></div>
<div class="grid">
  <div class="card"><h2 class="section-title">Role Settings</h2>
    <form method="post" class="form-grid">
      <input type="hidden" name="action" value="save">
      <label>Server Name<input name="server_name" value="<?=esc($name)?>" required></label>
      <label>Panel Role<select name="panel_role">
        <option value="hybrid" <?=$role==='hybrid'?'selected':''?>>Hybrid - Main dashboard + local node API</option>
        <option value="main" <?=$role==='main'?'selected':''?>>Main - Central dashboard only</option>
        <option value="node" <?=$role==='node'?'selected':''?>>Node - Local VPN API only</option>
      </select></label>
      <button class="btn" type="submit">Save Settings</button>
    </form>
  </div>
  <div class="card"><h2 class="section-title">Node Connection Details</h2>
    <div class="small">In the Main Panel, use the Base Panel URL for “Panel URL” and the token for “Node API Token”. Do not use root password.</div><br>
    <div class="small">Base Panel URL:</div>
    <div class="copy-row"><input readonly value="<?=esc($base)?>"><button class="btn copy-btn" data-copy="<?=esc($base)?>" type="button">⧉</button></div><br>
    <div class="small">Node API Token:</div>
    <div class="copy-row"><input readonly value="<?=esc($token)?>"><button class="btn copy-btn" data-copy="<?=esc($token)?>" type="button">⧉</button></div><br>
    <div class="small">Direct Node Status API URL for browser test:</div>
    <div class="copy-row"><input readonly value="<?=esc($base.'/api/node_status.php?token='.$token)?>"><button class="btn copy-btn" data-copy="<?=esc($base.'/api/node_status.php?token='.$token)?>" type="button">⧉</button></div><br>
    <form method="post" onsubmit="return confirm('Regenerate token? Existing main panels must be updated.')"><input type="hidden" name="action" value="regen_token"><button class="btn red" type="submit">Regenerate Token</button></form>
  </div>
</div>
<div class="card" style="margin-top:18px"><h2 class="section-title">Recommended Setup</h2><div class="table-wrap"><table><tr><th>Use case</th><th>Role</th><th>Meaning</th></tr><tr><td>Main VPS with VPN installed</td><td><span class="badge green">Hybrid</span></td><td>Shows multi-VPS dashboard and exposes local node status.</td></tr><tr><td>Only central monitoring VPS</td><td><span class="badge">Main</span></td><td>Can add other VPS nodes but does not expose node API.</td></tr><tr><td>Remote VPS server</td><td><span class="badge yellow">Node</span></td><td>Only exposes local status API for a main panel.</td></tr></table></div></div>
<?php render_footer(); ?>
