const API = `${location.origin}/web-api/api/couple-schedule`;
const headers = {"X-App-Module":"couple_schedule"};
const $ = id => document.getElementById(id);
let monday = startOfWeek(new Date());
let outgoingInvitationId = "";
let searchTimer = null;
const CODE_STORAGE = "hanshang_shared_availability_code_v1";

function startOfWeek(value){const d=new Date(value);d.setHours(12,0,0,0);const day=d.getDay()||7;d.setDate(d.getDate()-day+1);return d}
function isoDate(value){return value.toISOString().slice(0,10)}
function message(text,error=false){$("message").textContent=text||"";$("message").className=error?"message-error":""}
function show(id){["loading","disconnected","waiting","connected"].forEach(x=>$(x).classList.toggle("hidden",x!==id))}
async function request(path,options={}){const response=await fetch(API+path,{credentials:"include",cache:"no-store",...options,headers:{...headers,...(options.headers||{})}});let body={};try{body=await response.json()}catch{}if(!response.ok)throw new Error(body.message||"请求失败，请稍后重试");return body.data}

function storedCode(){try{const item=JSON.parse(sessionStorage.getItem(CODE_STORAGE)||"null");if(item&&item.code&&Date.parse(item.expires_at)>Date.now())return item}catch{}sessionStorage.removeItem(CODE_STORAGE);return null}
function showUsernameWaiting(data){$("usernameWaiting").classList.remove("hidden");$("codeWaiting").classList.add("hidden");$("codeMissing").classList.add("hidden");outgoingInvitationId=data.outgoing.invitation_id;$("waitingName").textContent=data.outgoing.username||"对方";show("waiting")}
function showCodeWaiting(item){$("usernameWaiting").classList.add("hidden");$("codeMissing").classList.add("hidden");$("codeWaiting").classList.remove("hidden");$("inviteCode").textContent=item.code;const minutes=Math.max(1,Math.ceil((Date.parse(item.expires_at)-Date.now())/60000));$("codeExpiry").textContent=`约 ${minutes} 分钟后失效。对方输入即表示同意建立连接。`;show("waiting")}
function showMissingCode(){$("usernameWaiting").classList.add("hidden");$("codeWaiting").classList.add("hidden");$("codeMissing").classList.remove("hidden");show("waiting")}
async function refresh(){show("loading");message("");try{const data=await request("/status");if(data.state==="connected"){sessionStorage.removeItem(CODE_STORAGE);show("connected");$("partnerName").textContent=data.partner.username;$("partnerAvatar").textContent=(data.partner.username||"?").trim().charAt(0)||"?";await loadWeek()}else if(data.state==="waiting"&&data.invite_type==="username"&&data.outgoing){showUsernameWaiting(data)}else if(data.state==="waiting"&&data.invite_type==="code"){const item=storedCode();item?showCodeWaiting(item):showMissingCode()}else{sessionStorage.removeItem(CODE_STORAGE);show("disconnected");renderIncoming(data.invitations||[])}}catch(error){show("disconnected");message(error.message,true)}}

function renderIncoming(invitations){const panel=$("incomingPanel"),list=$("incomingList");list.replaceChildren();panel.classList.toggle("hidden",!invitations.length);for(const invite of invitations){const row=document.createElement("div");row.className="incoming-row";const label=document.createElement("strong");label.textContent=`${invite.username} 邀请你查看共同空闲`;const actions=document.createElement("div");for(const [text,accept,cls] of [["拒绝",false,"btn text danger"],["接受",true,"btn primary"]]){const button=document.createElement("button");button.type="button";button.className=cls;button.textContent=text;button.addEventListener("click",()=>respond(invite.invitation_id,accept));actions.append(button)}row.append(label,actions);list.append(row)}}

function clearSearch(){const results=$("userSearchResults");results.replaceChildren();results.classList.add("hidden")}
function renderSearch(items){const results=$("userSearchResults");results.replaceChildren();results.classList.remove("hidden");if(!items.length){const empty=document.createElement("div");empty.className="search-empty";empty.textContent="没有找到匹配的用户名";results.append(empty);return}for(const item of items){const row=document.createElement("div");row.className="search-result";row.setAttribute("role","option");const icon=document.createElement("span");icon.innerHTML='<svg class="icon" aria-hidden="true"><use href="#i-person"/></svg>';const name=document.createElement("strong");name.textContent=item.username;const button=document.createElement("button");button.type="button";button.textContent="邀请";button.addEventListener("click",()=>sendInvite(item.username));row.append(icon,name,button);results.append(row)}}
async function searchUsers(){const query=$("inviteUsername").value.trim();if(query.length<2){clearSearch();return}try{const data=await request(`/users/search?q=${encodeURIComponent(query)}`);renderSearch(data.items||[])}catch(error){clearSearch();message(error.message,true)}}
async function sendInvite(username){message("");$("inviteUsername").value=username;clearSearch();try{await request("/invites",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({username})});message("邀请已发送，等待对方确认");await refresh()}catch(error){message(error.message,true)}}
async function createInvite(event){event.preventDefault();const username=$("inviteUsername").value.trim();if(username)await sendInvite(username)}
async function respond(invitationId,accept){try{await request("/invites/respond",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({invitation_id:invitationId,accept})});message(accept?"已接受邀请":"已拒绝邀请");await refresh()}catch(error){message(error.message,true)}}
async function cancelInvite(){if(!outgoingInvitationId)return;try{await request(`/invites/${encodeURIComponent(outgoingInvitationId)}`,{method:"DELETE"});message("已撤回邀请");await refresh()}catch(error){message(error.message,true)}}
async function createCode(){try{const data=await request("/invites",{method:"POST"});const item={code:data.code,expires_at:data.expires_at};sessionStorage.setItem(CODE_STORAGE,JSON.stringify(item));message("邀请码已生成，15 分钟内有效");showCodeWaiting(item)}catch(error){message(error.message,true)}}
async function claimCode(event){event.preventDefault();const code=$("claimCode").value.trim().toUpperCase();if(!code)return;try{await request("/claim",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({code})});sessionStorage.removeItem(CODE_STORAGE);message("连接成功，只会共享忙闲状态");await refresh()}catch(error){message(error.message,true)}}
async function cancelCode(){try{await request("/invite-code",{method:"DELETE"});sessionStorage.removeItem(CODE_STORAGE);message("邀请码已取消");await refresh()}catch(error){message(error.message,true)}}
async function shareCode(){const code=$("inviteCode").textContent.trim();if(!code)return;const text=`我的邗上课表共同空闲邀请码：${code}（15 分钟内有效）`;try{if(navigator.share){await navigator.share({title:"共同空闲邀请",text})}else{await navigator.clipboard.writeText(text);message("邀请码已复制")}}catch(error){if(error?.name!=="AbortError")message("暂时无法分享，请点邀请码复制",true)}}
async function copyCode(){const code=$("inviteCode").textContent.trim();if(!code)return;try{await navigator.clipboard.writeText(code);message("邀请码已复制")}catch{message("请长按邀请码复制",true)}}

// 与安卓 _freeRanges 一致：合并连续 both_free 节次为 "1-2节、5节" 文本
function freeRanges(states){const result=[];let start=-1;for(let i=0;i<=states.length;i++){const free=i<states.length&&states[i]==="both_free";if(free&&start<0)start=i+1;if(!free&&start>0){const end=i;result.push(start===end?`第${start}节`:`${start}-${end}节`);start=-1}}return result}
const STATE_LABELS={both_free:"双方都空闲",me_busy:"我有课",partner_busy:"对方有课",both_busy:"双方都有课"};

async function loadWeek(){try{const data=await request(`/week?week_start=${isoDate(monday)}`);renderGrid(data)}catch(error){renderWeekError(error.message||"这一周暂时无法读取，请稍后重试。")}}
function renderWeekError(text){const grid=$("scheduleGrid");grid.replaceChildren();const box=document.createElement("div");box.className="week-error";box.innerHTML='<svg class="icon" aria-hidden="true"><use href="#i-cloud_off"/></svg>';const p=document.createElement("p");p.textContent=text;const retry=document.createElement("button");retry.type="button";retry.className="btn secondary";retry.textContent="重试";retry.addEventListener("click",loadWeek);box.append(p,retry);grid.append(box)}
function renderGrid(data){const end=new Date(monday);end.setDate(end.getDate()+6);$("weekTitle").textContent="共同空闲时间";$("weekRange").textContent=`${monday.getMonth()+1}月${monday.getDate()}日 — ${end.getMonth()+1}月${end.getDate()}日`;const names=["一","二","三","四","五","六","日"];const grid=$("scheduleGrid");grid.replaceChildren();for(const day of data.days){const block=document.createElement("div");block.className="avail-day";const head=document.createElement("div");head.className="avail-day-head";const title=document.createElement("strong");const dayDate=new Date(String(day.date).slice(0,10)+"T00:00:00");title.textContent=Number.isNaN(dayDate.getTime())?`周${names[day.day-1]}`:`周${names[day.day-1]} ${dayDate.getMonth()+1}/${dayDate.getDate()}`;const free=document.createElement("span");const ranges=freeRanges(day.states);free.textContent=ranges.length?`空闲 ${ranges.join("、")}`:"暂无共同空闲";head.append(title,free);const strip=document.createElement("div");strip.className="avail-strip";day.states.forEach((state,index)=>{const cell=document.createElement("div");cell.className=`cell state-${state}`;cell.textContent=String(index+1);cell.setAttribute("aria-label",`第${index+1}节 ${STATE_LABELS[state]||"状态未知"}`);strip.append(cell)});block.append(head,strip);grid.append(block)}}

async function disconnect(){if(!confirm("确认解除连接？双方将立即无法查看彼此忙闲状态。"))return;try{await request("/connection",{method:"DELETE"});message("已解除连接");await refresh()}catch(error){message(error.message,true)}}
$("inviteForm").addEventListener("submit",createInvite);
$("inviteUsername").addEventListener("input",()=>{clearTimeout(searchTimer);searchTimer=setTimeout(searchUsers,280)});
$("claimForm").addEventListener("submit",claimCode);
$("claimCode").addEventListener("input",event=>{event.target.value=event.target.value.toUpperCase().replace(/[^2-9A-HJ-NP-Z]/g,"").slice(0,8)});
$("createCode").addEventListener("click",createCode);
$("regenerateCode").addEventListener("click",createCode);
$("inviteCode").addEventListener("click",copyCode);
$("shareCode").addEventListener("click",shareCode);
$("cancelCode").addEventListener("click",cancelCode);
$("disconnect").addEventListener("click",disconnect);
$("cancelInvite").addEventListener("click",cancelInvite);
$("refreshPage").addEventListener("click",refresh);
$("prevWeek").addEventListener("click",async()=>{monday.setDate(monday.getDate()-7);await loadWeek()});
$("nextWeek").addEventListener("click",async()=>{monday.setDate(monday.getDate()+7);await loadWeek()});
refresh();
