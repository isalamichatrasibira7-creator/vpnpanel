(function(){
  const $ = (id)=>document.getElementById(id);
  function esc(s){return String(s==null?'':s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[c]));}
  function num(v){v=parseInt(v||0,10); return Number.isFinite(v)?v:0;}
  function drawBarChart(canvasId, labels, values, title){
    const c=$(canvasId); if(!c) return; const dpr=window.devicePixelRatio||1; const w=c.clientWidth||500, h=c.clientHeight||190; c.width=w*dpr; c.height=h*dpr; const ctx=c.getContext('2d'); ctx.scale(dpr,dpr); ctx.clearRect(0,0,w,h);
    ctx.font='12px Segoe UI, Arial'; ctx.fillStyle='rgba(244,248,255,.92)'; ctx.fillText(title,14,22);
    const max=Math.max(1,...values); const left=34, right=14, top=38, bottom=34; const areaW=w-left-right, areaH=h-top-bottom; const gap=10; const barW=Math.max(18,(areaW-gap*(values.length-1))/Math.max(1,values.length));
    ctx.strokeStyle='rgba(255,255,255,.12)'; ctx.beginPath(); ctx.moveTo(left,top); ctx.lineTo(left,top+areaH); ctx.lineTo(w-right,top+areaH); ctx.stroke();
    values.forEach((v,i)=>{ const x=left+i*(barW+gap); const bh=Math.round((v/max)*areaH); const y=top+areaH-bh; const grd=ctx.createLinearGradient(0,y,0,top+areaH); grd.addColorStop(0,'rgba(79,140,255,.75)'); grd.addColorStop(1,'rgba(34,199,147,.85)'); ctx.fillStyle=grd; ctx.fillRect(x,y,barW,bh); ctx.fillStyle='rgba(244,248,255,.95)'; ctx.textAlign='center'; ctx.fillText(String(v),x+barW/2,Math.max(top+12,y-6)); let label=String(labels[i]||''); if(label.length>12) label=label.slice(0,11)+'…'; ctx.fillStyle='rgba(156,178,216,.95)'; ctx.fillText(label,x+barW/2,top+areaH+20); });
    ctx.textAlign='start';
  }
  function serverCard(s){
    const ok=!!s.ok; const ov=num(s.openvpn&&s.openvpn.active), oc=num(s.openconnect&&s.openconnect.active), v2=num(s.v2ray&&s.v2ray.active), total=num(s.total_active)||(ov+oc+v2);
    return `<div class="card server-card ${ok?'':'offline'}"><div class="toolbar"><div><div class="muted">${esc(s.source==='local'?'Main / Local':'Remote Node')}</div><div class="section-title" style="margin:2px 0 0">${esc(s.server_name||'VPS')}</div></div><span class="badge ${ok?'green':'red'}"><span class="status-pill ${ok?'':'off'}">${ok?'Online':'Offline'}</span></span></div><div class="server-meta small"><div>IP: <strong>${esc(s.server_ip||'-')}</strong></div><div>Total active: <strong>${total}</strong></div><div>Updated: ${esc(s.updated_at||'-')}</div>${s.error?`<div class="flash error" style="margin-top:8px">${esc(s.error)}</div>`:''}</div><div class="mini-stat-grid"><div class="mini-stat"><span class="small">OpenVPN</span><strong>${ov}</strong></div><div class="mini-stat"><span class="small">OpenConnect</span><strong>${oc}</strong></div><div class="mini-stat"><span class="small">V2Ray</span><strong>${v2}</strong></div></div></div>`;
  }
  async function refreshCluster(){
    const list=$('clusterServerCards'); if(!list) return;
    try{
      const r=await fetch('api/multi_status.php?_='+Date.now(),{cache:'no-store'}); const d=await r.json(); if(!d.ok) throw new Error(d.error||'Failed');
      const servers=d.servers||[]; list.innerHTML=servers.map(serverCard).join('') || '<div class="card empty">No server data.</div>';
      const labels=servers.map(s=>s.server_name||'VPS');
      drawBarChart('chartOpenvpn',labels,servers.map(s=>num(s.openvpn&&s.openvpn.active)),'OpenVPN active devices');
      drawBarChart('chartOpenconnect',labels,servers.map(s=>num(s.openconnect&&s.openconnect.active)),'OpenConnect active sessions');
      drawBarChart('chartV2ray',labels,servers.map(s=>num(s.v2ray&&s.v2ray.active)),'V2Ray/Xray active IPs');
      const total=servers.reduce((a,s)=>a+num(s.total_active),0); const upd=$('clusterUpdated'); if(upd) upd.textContent='Last update: '+(d.updated_at||'-')+' · Total active: '+total;
    }catch(e){ list.innerHTML='<div class="flash error">Multi VPS data failed: '+esc(e.message||e)+'</div>'; }
  }
  window.refreshCluster=refreshCluster;
  document.addEventListener('DOMContentLoaded',function(){ refreshCluster(); setInterval(refreshCluster,5000); window.addEventListener('resize',refreshCluster); });
})();
