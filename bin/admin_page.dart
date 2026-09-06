/// 网页管理后台（单文件 HTML，由 /admin 返回）。
/// 用浏览器打开 http://服务器IP:8080/admin → 粘贴密钥（data/secret.key）→ 管理：
/// ① 四档收款码配置（粘贴图片链接 或 直接选择本地图片上传）
/// ② 订单列表 + 人工确认
/// ③ 账号列表 + 重置密码
const String adminPageHtml = '''
<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>小马达能量营 · 管理后台</title>
<style>
body{font-family:system-ui,-apple-system,"Microsoft YaHei";margin:0;background:#FFF8F0;color:#3A3430}
.wrap{max-width:860px;margin:0 auto;padding:20px}
h1{font-size:20px;border-bottom:3px solid #3EC2A8;padding-bottom:8px}
.card{background:#fff;border:1px solid #F0E6DA;border-radius:14px;padding:14px;margin:12px 0}
input{padding:8px;border:1px solid #E0D5C5;border-radius:8px;font-size:13px;width:100%;box-sizing:border-box}
button{background:#F0713A;color:#fff;border:0;border-radius:8px;padding:8px 16px;font-size:13px;cursor:pointer}
button.gray{background:#8A8078}
table{border-collapse:collapse;width:100%;font-size:12px}
td,th{border:1px solid #EFE3D3;padding:5px 7px;text-align:left}
.status-ok{color:#2E9E63;font-weight:700}.status-pending{color:#F0713A;font-weight:700}
#msg{position:fixed;top:12px;left:50%;transform:translateX(-50%);background:#3A3430;color:#fff;
padding:8px 18px;border-radius:20px;font-size:13px;display:none}
.plans{display:grid;grid-template-columns:1fr 1fr;gap:10px}
small{color:#8A8078}
</style></head><body><div class="wrap">
<h1>🔋 小马达能量营 · 管理后台</h1>
<div class="card"><b>管理密钥</b>（data/secret.key 的内容）：
<input id="key" placeholder="粘贴 secret.key 内容"><button onclick="saveKey()">保存</button>
<button class="gray" onclick="loadData()">刷新数据</button></div>

<div class="card"><b>💰 收款码配置</b>（改完立即生效，App 内下单自动使用新码）<br>
<small>两种方式：粘贴图片链接，或点「选图」直接上传本地收款码截图（推荐，收款码换图不用重新打包 App）</small>
<div class="plans" id="plans"></div></div>

<div class="card"><b>📦 订单</b> <button class="gray" onclick="loadData()">刷新</button>
<div id="orders"></div></div>

<div class="card"><b>👤 账号</b>
<div id="accounts"></div>
<div style="margin-top:8px">重置密码：账号 <input id="rpAcc" style="width:200px"> 新密码 <input id="rpPwd" style="width:140px">
<button onclick="resetpw()">重置</button></div></div>

<div id="msg"></div>
</div>
<script>
const PLANS=[['month','月卡 ¥58'],['quarter','季卡 ¥138'],['year','年卡 ¥288'],['trial','体验 ¥1']];
let KEY=localStorage.getItem('adminKey')||'';
document.getElementById('key').value=KEY;
function saveKey(){KEY=document.getElementById('key').value;localStorage.setItem('adminKey',KEY);msg('密钥已保存');loadData()}
function msg(t){const m=document.getElementById('msg');m.textContent=t;m.style.display='block';setTimeout(()=>m.style.display='none',2600)}
async function api(path,body){const r=await fetch(path,{method:body?'POST':'GET',
 headers:{'Content-Type':'application/json','x-admin-key':KEY},
 body:body?JSON.stringify(body):undefined});
 if(r.status===403)throw new Error('管理密钥错误');
 const t=await r.text();try{return JSON.parse(t)}catch(e){return t}}
function esc(s){return (s==null?'':String(s)).replace(/</g,'&lt;')}

function renderPlans(cfg){const el=document.getElementById('plans');el.innerHTML='';
 for(const [id,label] of PLANS){const c=(cfg&&cfg[id])||{};
  const div=document.createElement('div');div.className='card';div.style.margin='0';
  div.innerHTML='<b>'+label+'</b><br><small>当前：'+(c.dataUrl?'本地图片':esc(c.qrUrl||'未配置'))+'</small><br>';
  const inp=document.createElement('input');inp.placeholder='粘贴收款码图片链接…';inp.value=c.qrUrl&&c.qrUrl.startsWith('http')?c.qrUrl:'';
  const file=document.createElement('input');file.type='file';file.accept='image/*';file.style.marginTop='6px';
  const btn=document.createElement('button');btn.textContent='保存';btn.style.marginTop='6px';
  const up=document.createElement('button');up.textContent='上传本地图片';up.className='gray';up.style.marginTop='6px';
  btn.onclick=async()=>{await api('/admin/setqr',{plan:id,url:inp.value});msg(label+' 收款码已更新');loadData()};
  file.onchange=()=>{const f=file.files[0];if(!f)return;const rd=new FileReader();
    rd.onload=async()=>{await api('/admin/setqr',{plan:id,dataUrl:rd.result});msg(label+' 本地收款码已上传');loadData()};
    rd.readAsDataURL(f)};
  up.onclick=()=>file.click();
  div.append(inp,document.createElement('br'),file,up,btn);el.append(div)}}

function renderOrders(orders){const el=document.getElementById('orders');
 const keys=Object.keys(orders||{}).reverse();
 if(!keys.length){el.innerHTML='<small>暂无订单</small>';return}
 let h='<table><tr><th>订单号</th><th>账号</th><th>套餐</th><th>金额</th><th>状态</th><th></th></tr>';
 for(const k of keys){const o=orders[k];
  const st=o.status==='paid'?'<span class=status-ok>已支付</span>':(o.status==='expired'?'已过期':'<span class=status-pending>待支付</span>');
  h+='<tr><td>'+esc(k)+'</td><td>'+esc(o.email)+'</td><td>'+esc(o.plan)+'</td><td>¥'+o.amount+'</td><td>'+st+'</td><td>'+
    (o.status==='pending'?'<button onclick=\\'confirmOrder("'+k+'")\\'>确认收款</button>':'')+'</td></tr>'}
 el.innerHTML=h+'</table>'}
async function confirmOrder(id){await api('/admin/confirm',{orderId:id});msg('已确认并开通会员');loadData()}

function renderAccounts(accounts){const el=document.getElementById('accounts');
 const keys=Object.keys(accounts||{});
 if(!keys.length){el.innerHTML='<small>暂无账号</small>';return}
 let h='<table><tr><th>账号</th><th>会员至</th><th>状态</th></tr>';
 for(const k of keys){const a=accounts[k];
  h+='<tr><td>'+esc(k)+'</td><td>'+esc(a.vipExpire||'未开通')+'</td><td>'+(a.locked?'<span class=status-pending>已锁定</span>':'正常')+'</td></tr>'}
 el.innerHTML=h+'</table>'}
async function resetpw(){const a=document.getElementById('rpAcc').value.trim(),p=document.getElementById('rpPwd').value;
 if(!a||p.length<8){msg('账号与新密码(8位+)必填');return}
 await api('/admin/resetpw',{account:a,newPassword:p});msg('密码已重置');loadData()}

async function loadData(){try{const d=await api('/admin/data');renderPlans(d.payconfig);renderOrders(d.orders);renderAccounts(d.accounts)}catch(e){msg(e.message)}}
if(KEY)loadData();
</script></body></html>
''';
