<?php
require __DIR__.'/config.php';
require __DIR__.'/status_lib.php';
require_login(); ensure_multirole_schema();
if(!is_main_panel()){ render_header('Multi VPS Servers'); echo '<div class="flash error">This panel is in Node mode. Change role to Main or Hybrid from Settings to manage servers.</div>'; render_footer(); exit; }
$msg=''; $err='';
function find_server($id){ $st=db()->prepare('SELECT * FROM servers WHERE id=:id'); $st->bindValue(':id',(int)$id,SQLITE3_INTEGER); $r=$st->execute(); return $r?$r->fetchArray(SQLITE3_ASSOC):false; }
if($_SERVER['REQUEST_METHOD']==='POST'){
  $action=$_POST['action'] ?? '';
  if($action==='save'){
    $id=(int)($_POST['id'] ?? 0); $name=trim((string)($_POST['name'] ?? '')); $ip=trim((string)($_POST['ip_address'] ?? '')); $rawUrl=trim((string)($_POST['panel_url'] ?? '')); $rawToken=trim((string)($_POST['api_token'] ?? '')); $urlToken=node_token_from_url($rawUrl); $tokenToken=node_token_from_url($rawToken); if($tokenToken!=='') $rawToken=$tokenToken; if($rawToken==='' && $urlToken!=='') $rawToken=$urlToken; $url=normalized_panel_url($rawUrl); $token=$rawToken; if($ip===''){ $parts=@parse_url($url); if(is_array($parts) && !empty($parts['host'])) $ip=$parts['host']; } $enabled=!empty($_POST['enabled'])?1:0; $sort=(int)($_POST['sort_order'] ?? 0);
    if($name===''||$ip===''||$url===''||$token==='') $err='Name, IP, panel URL, and API token are required.';
    elseif(!preg_match('#^https?://#i',$url)) $err='Panel URL must start with http:// or https://';
    else{
      $test=ms_fetch_node_status($url,$token,6);
      if(!($test['ok']??false)){
        $err='Node test failed: '.($test['error']??'Invalid response').'. Use the node Base Panel URL and Node API Token, or paste the full Node Status API URL into Panel URL.';
      } else {
        if($id>0){ $st=db()->prepare('UPDATE servers SET name=:n,ip_address=:ip,panel_url=:url,api_token=:t,enabled=:e,sort_order=:s,updated_at=CURRENT_TIMESTAMP WHERE id=:id'); $st->bindValue(':id',$id,SQLITE3_INTEGER); }
        else { $st=db()->prepare('INSERT INTO servers(name,ip_address,panel_url,api_token,enabled,sort_order) VALUES(:n,:ip,:url,:t,:e,:s)'); }
        $st->bindValue(':n',$name,SQLITE3_TEXT); $st->bindValue(':ip',$ip,SQLITE3_TEXT); $st->bindValue(':url',$url,SQLITE3_TEXT); $st->bindValue(':t',$token,SQLITE3_TEXT); $st->bindValue(':e',$enabled,SQLITE3_INTEGER); $st->bindValue(':s',$sort,SQLITE3_INTEGER); $st->execute(); $msg=$id>0?'Server updated and verified.':'Server added and verified.';
      }
    }
  } elseif($action==='delete'){
    $id=(int)($_POST['id'] ?? 0); $st=db()->prepare('DELETE FROM servers WHERE id=:id'); $st->bindValue(':id',$id,SQLITE3_INTEGER); $st->execute(); $msg='Server deleted.';
  }
}
$edit=null; if(isset($_GET['edit'])) $edit=find_server((int)$_GET['edit']);
$res=db()->query('SELECT * FROM servers ORDER BY sort_order ASC,id ASC'); $servers=[]; while($res && $row=$res->fetchArray(SQLITE3_ASSOC)) $servers[]=$row;
render_header('Multi VPS Servers'); ?>
<?php if($msg): ?><div class="flash"><?=esc($msg)?></div><?php endif; ?><?php if($err): ?><div class="flash error"><?=esc($err)?></div><?php endif; ?>
<div class="panel-banner"><div class="toolbar"><div><h2 class="section-title">Multi VPS Server Manager</h2><div class="small">Add any VPS where this same panel is installed in Node or Hybrid mode. Use API token, not root password.</div></div><a class="btn" href="settings.php">My API Token</a></div></div>
<div class="grid">
  <div class="card"><h2 class="section-title"><?= $edit?'Edit VPS':'Add VPS' ?></h2>
    <form method="post" class="form-grid">
      <input type="hidden" name="action" value="save"><input type="hidden" name="id" value="<?=esc($edit['id'] ?? 0)?>">
      <label>VPS Name<input name="name" value="<?=esc($edit['name'] ?? '')?>" placeholder="VPS2 Singapore" required></label>
      <label>VPS IP<input name="ip_address" value="<?=esc($edit['ip_address'] ?? '')?>" placeholder="Auto from URL if blank"></label>
      <label>Panel URL<input name="panel_url" value="<?=esc($edit['panel_url'] ?? '')?>" placeholder="http://1.2.3.4/vpn-panel" required></label>
      <label>Node API Token<input name="api_token" value="<?=esc($edit['api_token'] ?? '')?>" placeholder="Token, or leave blank if full Node Status URL pasted"></label>
      <label>Sort Order<input type="number" name="sort_order" value="<?=esc($edit['sort_order'] ?? 0)?>"></label>
      <label style="display:flex;align-items:center;gap:10px"><input style="width:auto" type="checkbox" name="enabled" value="1" <?=(!isset($edit['enabled']) || (int)$edit['enabled']===1)?'checked':''?>> Enabled</label>
      <button class="btn" type="submit"><?= $edit?'Update VPS':'Add VPS' ?></button><?php if($edit): ?><a class="btn gray" href="servers.php">Cancel Edit</a><?php endif; ?>
    </form>
  </div>
  <div class="card"><h2 class="section-title">How to Add a VPS</h2><ol class="small" style="line-height:1.8"><li>Install this full project on the remote VPS.</li><li>Open remote panel → Settings.</li><li>Set role to Node or Hybrid.</li><li>Copy Node API Token.</li><li>Add VPS here with the base panel URL and token. You can also paste the full Node Status API URL; the panel will extract the token automatically.</li></ol><div class="flash">Dashboard data refreshes every 5 seconds from <code>/api/node_status.php</code>.</div></div>
</div>
<div class="card" style="margin-top:18px"><div class="toolbar"><h2 class="section-title">Added VPS Nodes</h2><a class="btn" href="index.php">Open Dashboard</a></div><div class="table-wrap"><table><tr><th>ID</th><th>Name</th><th>IP</th><th>Panel URL</th><th>Status</th><th>Actions</th></tr>
<?php foreach($servers as $s): ?><tr><td><?=esc($s['id'])?></td><td><strong><?=esc($s['name'])?></strong></td><td><?=esc($s['ip_address'])?></td><td><a href="<?=esc($s['panel_url'])?>" target="_blank"><?=esc($s['panel_url'])?></a></td><td><?=((int)$s['enabled']===1?'<span class="badge green">Enabled</span>':'<span class="badge red">Disabled</span>')?></td><td class="server-actions"><a class="btn" href="servers.php?edit=<?=esc($s['id'])?>">Edit</a><form method="post" onsubmit="return confirm('Delete this server?')"><input type="hidden" name="action" value="delete"><input type="hidden" name="id" value="<?=esc($s['id'])?>"><button class="btn red" type="submit">Delete</button></form></td></tr><?php endforeach; ?>
<?php if(!$servers): ?><tr><td colspan="6" class="empty">No remote VPS added yet.</td></tr><?php endif; ?></table></div></div>
<?php render_footer(); ?>
