import React from 'react';
import ReactDOM from 'react-dom/client';
import { invoke } from '@tauri-apps/api/core';
import { Store } from '@tauri-apps/plugin-store';
import { writeText } from '@tauri-apps/plugin-clipboard-manager';
import { enable, disable, isEnabled } from '@tauri-apps/plugin-autostart';
import QRCode from 'qrcode';
import { BarChart3, Brain, CalendarDays, ChevronDown, ChevronUp, CircleDollarSign, Copy, Lightbulb, RefreshCw, Settings, Smartphone, Sparkles, Target, Terminal, Zap } from 'lucide-react';
import { Bar, BarChart, CartesianGrid, Legend, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts';
import './styles.css';
import appIcon from './app-icon.png';

type Day={date:string;claude:number;cursor:number;codex:number;total:number}; type Model={model:string;claude:number;cursor:number;codex:number;total:number};
type Session={id:string;tool:string;cost:number;dominant_model:string;messages:number;title:string;tips:string[];issue_key?:string|null};
type Jira={url:string;email:string;token:string};
type RemoteStatus={running:boolean;localUrl?:string|null;token?:string|null;tunnelUrl?:string|null};
type Tip={rank:number;title:string;detail:string;wrong:string;right:string};
type Snapshot={asOfDate:string;today:number;month:number;yesterday:number;claudeToday:number;cursorToday:number;codexToday:number;claudeMonth:number;cursorMonth:number;codexMonth:number;sessionsToday:number;messagesToday:number;productBreakdown:Record<string,number>;modelBreakdown:Model[];days:Day[];topSessions:Session[];tips:Tip[];insight?:string;claudePath:string;cursorPath:string;codexPath:string};
const money=(n:number)=>n.toLocaleString('en-US',{style:'currency',currency:'USD',minimumFractionDigits:2});
const modelName=(s:string)=>s.replace('claude-','').replaceAll('-',' ').replace(/\b\w/g,c=>c.toUpperCase());

function App(){
 const [tab,setTab]=React.useState<'dashboard'|'coach'|'settings'>('dashboard'); const [range,setRange]=React.useState('7days'); const [data,setData]=React.useState<Snapshot>(); const [loading,setLoading]=React.useState(false); const [error,setError]=React.useState('');
 const [budget,setBudget]=React.useState(0); const [startup,setStartup]=React.useState(false); const [expanded,setExpanded]=React.useState<number[]>([]);
 const [jira,setJira]=React.useState<Jira>({url:'',email:'',token:''}); const [pushed,setPushed]=React.useState<Record<string,string>>({});
 const [remote,setRemote]=React.useState<RemoteStatus>({running:false}); const [remoteWanted,setRemoteWanted]=React.useState(false); const [ngrokToken,setNgrokToken]=React.useState(''); const [tunnelBusy,setTunnelBusy]=React.useState(false); const [tunnelErr,setTunnelErr]=React.useState('');
 const load=React.useCallback(async()=>{setLoading(true);setError('');try{setData(await invoke<Snapshot>('scan_usage',{range}));}catch(e){setError(String(e))}finally{setLoading(false)}},[range]);
 React.useEffect(()=>{load()},[load]); React.useEffect(()=>{(async()=>{
  const s=await Store.load('settings.json');
  setBudget(await s.get<number>('budget')??0);setJira(await s.get<Jira>('jira')??{url:'',email:'',token:''});setPushed(await s.get<Record<string,string>>('jiraPushed')??{});setStartup(await isEnabled());
  const wanted=await s.get<boolean>('remoteEnabled')??false; setRemoteWanted(wanted); setNgrokToken(await s.get<string>('ngrokAuthtoken')??'');
  if(wanted){try{
   const status=await invoke<RemoteStatus>('remote_enable',{existingToken:await s.get<string>('remoteToken')??''});
   setRemote(status);
   if(status.token){await s.set('remoteToken',status.token);await s.save();}
  }catch{setRemote({running:false})}}
 })()},[]);
 const saveBudget=async(n:number)=>{setBudget(n);const s=await Store.load('settings.json');await s.set('budget',n);await s.save()};
 const saveJira=async(j:Jira)=>{setJira(j);const s=await Store.load('settings.json');await s.set('jira',j);await s.save()};
 const markPushed=async(id:string,issue:string)=>{const next={...pushed,[id]:issue};setPushed(next);const s=await Store.load('settings.json');await s.set('jiraPushed',next);await s.save()};
 const toggleRemote=async(v:boolean)=>{
  setRemoteWanted(v);
  const s=await Store.load('settings.json'); await s.set('remoteEnabled',v); await s.save();
  if(v){
   const status=await invoke<RemoteStatus>('remote_enable',{existingToken:await s.get<string>('remoteToken')??''});
   setRemote(status);
   if(status.token){await s.set('remoteToken',status.token);await s.save();}
  }else{
   await invoke('remote_disable'); await invoke('remote_stop_tunnel'); setRemote({running:false});
  }
 };
 const regenerateToken=async()=>{
  const status=await invoke<RemoteStatus>('remote_regenerate_token'); setRemote(status);
  const s=await Store.load('settings.json'); if(status.token){await s.set('remoteToken',status.token);await s.save();}
 };
 const saveNgrokToken=async(v:string)=>{setNgrokToken(v);const s=await Store.load('settings.json');await s.set('ngrokAuthtoken',v);await s.save()};
 const startTunnel=async()=>{
  setTunnelBusy(true);setTunnelErr('');
  try{const url=await invoke<string>('remote_start_tunnel',{authtoken:ngrokToken});setRemote(r=>({...r,tunnelUrl:url}))}
  catch(e){setTunnelErr(String(e))}
  finally{setTunnelBusy(false)}
 };
 const stopTunnel=async()=>{await invoke('remote_stop_tunnel');setRemote(r=>({...r,tunnelUrl:null}))};
 const toggleStartup=async(v:boolean)=>{v?await enable():await disable();setStartup(v)};
 const projection=data?data.month/(new Date().getDate())*new Date(new Date().getFullYear(),new Date().getMonth()+1,0).getDate():0;
 return <div className="shell"><aside><div className="brand"><div className="brandmark"><img src={appIcon} alt=""/></div><div><strong>AI Usage</strong><small>LOCAL TRACKER</small></div></div><nav>
  <button className={tab==='dashboard'?'active':''} onClick={()=>setTab('dashboard')}><BarChart3/>Dashboard</button><button className={tab==='coach'?'active':''} onClick={()=>setTab('coach')}><Lightbulb/>Cost coach</button><button className={tab==='settings'?'active':''} onClick={()=>setTab('settings')}><Settings/>Settings</button>
 </nav><div className="local"><span className="dot"/>Local only<small>Your data never leaves this PC</small></div></aside>
 <main><header><div><h1>{tab==='dashboard'?'Usage dashboard':tab==='coach'?'Cost coach':'Settings'}</h1><p>{tab==='dashboard'?'Claude Code + Cursor + OpenAI Codex from local sessions':tab==='coach'?'Same results, fewer turns.':'Configure your local tracker'}</p></div><button className="refresh" onClick={load} disabled={loading}><RefreshCw className={loading?'spin':''}/>{loading?'Scanning…':'Refresh'}</button></header>
 {error&&<div className="error">{error}</div>}{!data?<div className="loading">Scanning local AI sessions…</div>:tab==='dashboard'?<Dashboard data={data} range={range} setRange={setRange} budget={budget} projection={projection}/>:tab==='coach'?<Coach data={data} budget={budget} saveBudget={saveBudget} projection={projection} expanded={expanded} setExpanded={setExpanded} jira={jira} pushed={pushed} markPushed={markPushed}/>:<SettingsPage data={data} startup={startup} toggleStartup={toggleStartup} jira={jira} saveJira={saveJira} remote={remote} remoteWanted={remoteWanted} toggleRemote={toggleRemote} regenerateToken={regenerateToken} ngrokToken={ngrokToken} saveNgrokToken={saveNgrokToken} tunnelBusy={tunnelBusy} tunnelErr={tunnelErr} startTunnel={startTunnel} stopTunnel={stopTunnel}/>}</main></div>
}

function Dashboard({data,range,setRange,budget,projection}:{data:Snapshot;range:string;setRange:(x:string)=>void;budget:number;projection:number}){const delta=data.yesterday?((data.today-data.yesterday)/data.yesterday)*100:0;return <>
 <div className="toolbar"><div className="asof"><CalendarDays/>Data as of <b>{data.asOfDate}</b></div><div className="segments">{[['today','Today'],['7days','7 Days'],['month','This Month']].map(([v,l])=><button key={v} className={range===v?'active':''} onClick={()=>setRange(v)}>{l}</button>)}</div></div>
 {budget>0&&projection>budget&&<div className="budget-alert"><Target/>Projected {money(projection)} this month — above your {money(budget)} budget.</div>}
 <section className="cards"><Card icon={<CircleDollarSign/>} label="TODAY" value={money(data.today)} note={data.yesterday?`${delta>=0?'↑':'↓'} ${Math.abs(delta).toFixed(0)}% vs yesterday`:'No previous-day baseline'}/><Card icon={<CalendarDays/>} label="THIS MONTH" value={money(data.month)} note={`Claude ${money(data.claudeMonth)} · Cursor ${money(data.cursorMonth)} · Codex ${money(data.codexMonth)}`}/><Card icon={<Brain/>} label="CLAUDE TODAY" value={money(data.claudeToday)} note="Estimated at list price" accent="purple"/><Card icon={<Zap/>} label="CODEX TODAY" value={money(data.codexToday)} note="API-equivalent estimate" accent="green"/><Card icon={<Terminal/>} label="SESSIONS TODAY" value={String(data.sessionsToday)} note={`${data.messagesToday} priced usage events`} accent="orange"/></section>
 <section className="panel chart"><div className="panel-title"><div><h2>Spend over time</h2><p>Daily estimated cost by tool</p></div><div className="legend-note">USD</div></div><ResponsiveContainer width="100%" height={265}><BarChart data={data.days} barGap={2}><CartesianGrid strokeDasharray="3 3" vertical={false}/><XAxis dataKey="date" tickFormatter={v=>v.slice(5)} /><YAxis tickFormatter={v=>`$${v}`}/><Tooltip formatter={(v)=>money(Number(v))}/><Legend/><Bar dataKey="claude" name="Claude" fill="#7357e8" radius={[4,4,0,0]}/><Bar dataKey="cursor" name="Cursor" fill="#ef9b45" radius={[4,4,0,0]}/><Bar dataKey="codex" name="Codex" fill="#2eaa78" radius={[4,4,0,0]}/></BarChart></ResponsiveContainer></section>
 <section className="panel"><div className="panel-title"><div><h2>Spend by model</h2><p>Cost attribution across local sessions</p></div></div><table><thead><tr><th>MODEL</th><th>CLAUDE</th><th>CURSOR</th><th>CODEX</th><th>TOTAL</th></tr></thead><tbody>{data.modelBreakdown.length?data.modelBreakdown.sort((a,b)=>b.total-a.total).map(m=><tr key={m.model}><td><span className="model-dot"/>{modelName(m.model)}</td><td>{money(m.claude)}</td><td>{money(m.cursor)}</td><td>{money(m.codex)}</td><td><b>{money(m.total)}</b></td></tr>):<tr><td colSpan={5} className="empty">No priced sessions in this range.</td></tr>}</tbody></table></section><p className="estimate-note">Claude and Codex are API-equivalent list-price estimates. Cursor is estimated from locally available token data.</p></>}
function Card({icon,label,value,note,accent='blue'}:{icon:React.ReactNode;label:string;value:string;note:string;accent?:string}){return <div className="card"><div className={`card-icon ${accent}`}>{icon}</div><small>{label}</small><strong>{value}</strong><p>{note}</p></div>}

function JiraPush({s,asOf,jira,pushed,markPushed}:{s:Session;asOf:string;jira:Jira;pushed:Record<string,string>;markPushed:(id:string,issue:string)=>void}){
 const [key,setKey]=React.useState(s.issue_key??''); const [busy,setBusy]=React.useState(false); const [err,setErr]=React.useState('');
 const done=pushed[s.id]; const configured=jira.url&&jira.email&&jira.token;
 const push=async()=>{setBusy(true);setErr('');try{
  const summary=`AI usage ${money(s.cost)} — ${s.title} · ${s.tool} · ${modelName(s.dominant_model)} · ${s.messages} turns (${asOf})`;
  const issue=await invoke<string>('jira_push_cost',{baseUrl:jira.url,email:jira.email,apiToken:jira.token,issueKey:key,summary});
  markPushed(s.id,issue);
 }catch(e){setErr(String(e))}finally{setBusy(false)}};
 if(done)return <div className="jira-row"><span className="jira-done">✓ Cost pushed to {done}</span></div>;
 return <div className="jira-row"><input value={key} placeholder="PROJ-123" onChange={e=>setKey(e.target.value)}/><button disabled={busy||!key||!configured} title={configured?'':'Set Jira URL, email, and API token in Settings first'} onClick={push}>{busy?'Pushing…':'Push to Jira'}</button>{err&&<span className="jira-err">{err}</span>}</div>;
}

function Coach({data,budget,saveBudget,projection,expanded,setExpanded,jira,pushed,markPushed}:{data:Snapshot;budget:number;saveBudget:(n:number)=>void;projection:number;expanded:number[];setExpanded:(n:number[])=>void;jira:Jira;pushed:Record<string,string>;markPushed:(id:string,issue:string)=>void}){return <div className="coach-grid"><div><section className="panel"><div className="panel-title"><div><h2>Today's most expensive sessions</h2><p>Where your tokens went</p></div></div>{data.topSessions.length?data.topSessions.map((s,i)=><div className="session" key={s.id}><span className="rank">{i+1}</span><div><b>{s.title}</b><div className="tags"><i>{s.tool}</i><i>{modelName(s.dominant_model)}</i><i>{s.messages} messages</i>{s.issue_key&&<i>{s.issue_key}</i>}</div>{(s.tips??[]).map((t,j)=><p key={j}><Lightbulb/> {t}</p>)}<JiraPush s={s} asOf={data.asOfDate} jira={jira} pushed={pushed} markPushed={markPushed}/></div><strong>{money(s.cost)}</strong></div>):<div className="empty">No priced sessions found for today.</div>}</section>
 <section className="panel tips"><div className="panel-title"><div><h2>Top ways to cut cost</h2><p>Rotates daily</p></div></div>{data.insight&&<div className="insight"><Sparkles/>{data.insight}</div>}{data.tips.map(t=><div className="tip"><span className="rank">{t.rank}</span><div><b>{t.title}</b><p>{t.detail}</p>{expanded.includes(t.rank)&&<div className="examples"><span>✕ {t.wrong}</span><span>✓ {t.right}</span></div>}</div><button onClick={()=>setExpanded(expanded.includes(t.rank)?expanded.filter(x=>x!==t.rank):[...expanded,t.rank])}>{expanded.includes(t.rank)?<ChevronUp/>:<ChevronDown/>}</button></div>)}</section></div>
 <aside className="right"><section className="panel budget"><Target/><h2>Monthly budget</h2><p>Get warned when projected usage runs over your cap.</p><label>MONTHLY CAP (USD)<input type="number" min="0" step="5" value={budget||''} placeholder="0" onChange={e=>saveBudget(Number(e.target.value))}/></label>{budget>0&&<div className="projection"><span>Month to date <b>{money(data.month)}</b></span><span>Projected <b>{money(projection)}</b></span><progress max={budget} value={Math.min(projection,budget)}/></div>}</section></aside></div>}

type RemoteProps={remote:RemoteStatus;remoteWanted:boolean;toggleRemote:(v:boolean)=>void;regenerateToken:()=>void;ngrokToken:string;saveNgrokToken:(v:string)=>void;tunnelBusy:boolean;tunnelErr:string;startTunnel:()=>void;stopTunnel:()=>void};
function SettingsPage({data,startup,toggleStartup,jira,saveJira,remote,remoteWanted,toggleRemote,regenerateToken,ngrokToken,saveNgrokToken,tunnelBusy,tunnelErr,startTunnel,stopTunnel}:{data:Snapshot;startup:boolean;toggleStartup:(v:boolean)=>void;jira:Jira;saveJira:(j:Jira)=>void}&RemoteProps){return <div className="settings-grid"><section className="panel settings-panel"><h2>Data sources</h2><p>The tracker scans local files in read-only mode.</p><PathRow title="Claude Code sessions" path={data.claudePath} ok/><PathRow title="Cursor local database" path={data.cursorPath} ok={data.cursorToday>0||data.cursorMonth>0}/><PathRow title="OpenAI Codex sessions" path={data.codexPath} ok={data.codexToday>0||data.codexMonth>0}/></section><section className="panel settings-panel"><h2>Desktop</h2><label className="toggle-row"><div><b>Start at login</b><p>Keep usage available from the menu bar or system tray.</p></div><input type="checkbox" checked={startup} onChange={e=>toggleStartup(e.target.checked)}/></label><div className="notice">Closing the window keeps AI Usage Tracker running in the menu bar / system tray (macOS, Windows, and Linux). Use the tray menu to quit.</div></section>
 <section className="panel settings-panel">
  <h2><Smartphone size={16}/> Phone access</h2>
  <p>View today's cost and coach tips from your phone. Your computer serves the data directly — nothing is uploaded unless you turn on the remote link below.</p>
  <label className="toggle-row"><div><b>Enable phone access</b><p>Starts a small local server on this computer.</p></div><input type="checkbox" checked={remoteWanted} onChange={e=>toggleRemote(e.target.checked)}/></label>
  {remote.running&&remote.localUrl&&<>
   <QrLink label="On the same Wi-Fi" url={remote.localUrl}/>
   <button className="link-btn" onClick={regenerateToken}>Regenerate access link</button>
   <div className="notice"><b>From anywhere (optional):</b> paste an <a href="https://dashboard.ngrok.com/get-started/your-authtoken" target="_blank" rel="noreferrer">ngrok authtoken</a> (free account) to get a link that works outside your home network. Traffic then passes through ngrok's servers instead of staying only on your LAN.</div>
   <label className="jira-field">NGROK AUTHTOKEN<input type="password" placeholder="Paste your ngrok authtoken" value={ngrokToken} onChange={e=>saveNgrokToken(e.target.value)}/></label>
   {remote.tunnelUrl?<>
     <QrLink label="From anywhere" url={`${remote.tunnelUrl}?token=${remote.token??''}`}/>
     <button className="link-btn" onClick={stopTunnel}>Stop remote link</button>
    </>:<button className="link-btn primary" disabled={tunnelBusy||!ngrokToken} onClick={startTunnel}>{tunnelBusy?'Starting…':'Start remote link'}</button>}
   {tunnelErr&&<div className="jira-err">{tunnelErr}</div>}
  </>}
 </section>
 <section className="panel settings-panel"><h2>Jira integration</h2><p>Push a session's cost summary as a comment on a Jira Cloud issue. Tickets are auto-detected from git branch names like feature/PROJ-123.</p><label className="jira-field">SITE URL<input placeholder="https://yourteam.atlassian.net" value={jira.url} onChange={e=>saveJira({...jira,url:e.target.value})}/></label><label className="jira-field">ACCOUNT EMAIL<input placeholder="you@company.com" value={jira.email} onChange={e=>saveJira({...jira,email:e.target.value})}/></label><label className="jira-field">API TOKEN<input type="password" placeholder="Create at id.atlassian.com → Security → API tokens" value={jira.token} onChange={e=>saveJira({...jira,token:e.target.value})}/></label><div className="notice">Credentials are stored only in this app's local settings file. Nothing is sent until you click "Push to Jira" on a session.</div></section><section className="panel settings-panel"><h2>Privacy</h2><p>No analytics or cloud sync. Session contents are never displayed or uploaded; only local token counts and metadata are aggregated. Outbound calls are the optional "Push to Jira" button and the optional phone remote link, both off by default.</p></section></div>}
function QrLink({label,url}:{label:string;url:string}){
 const [qr,setQr]=React.useState(''); const [copied,setCopied]=React.useState(false);
 React.useEffect(()=>{QRCode.toDataURL(url,{margin:1,width:180}).then(setQr).catch(()=>setQr(''))},[url]);
 const copy=async()=>{await writeText(url);setCopied(true);setTimeout(()=>setCopied(false),1500)};
 return <div className="qr-link"><div><small>{label.toUpperCase()}</small><code className="qr-url">{url}</code><button className="link-btn" onClick={copy}><Copy size={14}/>{copied?'Copied!':'Copy link'}</button></div>{qr&&<img className="qr-img" src={qr} alt="QR code"/>}</div>;
}
function PathRow({title,path,ok}:{title:string;path:string;ok:boolean}){return <div className="pathrow"><span className={ok?'status ok':'status'}/><div><b>{title}</b><code>{path}</code></div></div>}
ReactDOM.createRoot(document.getElementById('root')!).render(<React.StrictMode><App/></React.StrictMode>);
