pub mod coach;
mod jira;
mod pricing;
pub mod scanner;

use chrono::{Datelike, Local, NaiveDate};
use serde::Serialize;
use std::collections::{BTreeMap, HashMap};
use tauri::{Manager, WindowEvent};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DayRow { date: String, claude: f64, cursor: f64, codex: f64, total: f64 }

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ModelRow { model: String, claude: f64, cursor: f64, codex: f64, total: f64 }

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct UsageSnapshot {
    as_of_date: String,
    today: f64,
    month: f64,
    yesterday: f64,
    claude_today: f64,
    cursor_today: f64,
    codex_today: f64,
    claude_month: f64,
    cursor_month: f64,
    codex_month: f64,
    sessions_today: usize,
    messages_today: i64,
    product_breakdown: HashMap<String, f64>,
    model_breakdown: Vec<ModelRow>,
    days: Vec<DayRow>,
    top_sessions: Vec<scanner::SessionCost>,
    tips: Vec<coach::CoachTip>,
    insight: Option<String>,
    claude_path: String,
    cursor_path: String,
    codex_path: String,
}

#[tauri::command]
fn scan_usage(range: String) -> UsageSnapshot {
    let data = scanner::compute_by_day();
    let now = Local::now().date_naive();
    let today_key = now.format("%Y-%m-%d").to_string();
    let yesterday_key = (now - chrono::Duration::days(1)).format("%Y-%m-%d").to_string();
    let month_prefix = now.format("%Y-%m").to_string();
    let start = match range.as_str() {
        "today" => now,
        "7days" => now - chrono::Duration::days(6),
        _ => NaiveDate::from_ymd_opt(now.year(), now.month(), 1).unwrap(),
    };
    let empty = scanner::DayUsageAggregate::default();
    let today = data.get(&today_key).unwrap_or(&empty);
    let mut claude_month = 0.0; let mut cursor_month = 0.0; let mut codex_month = 0.0;
    let mut models: BTreeMap<String,(f64,f64,f64)> = BTreeMap::new();
    let mut days = Vec::new();
    for i in 0..=(now-start).num_days() {
        let d = start + chrono::Duration::days(i);
        let key = d.format("%Y-%m-%d").to_string();
        let a = data.get(&key);
        let c = a.map(|x| x.claude_cost).unwrap_or(0.0);
        let u = a.map(|x| x.cursor_cost).unwrap_or(0.0);
        let o = a.map(|x| x.codex_cost).unwrap_or(0.0);
        days.push(DayRow{date:key,claude:c,cursor:u,codex:o,total:pricing::round_cents(c+u+o)});
        if let Some(a)=a {
            for (m,v) in &a.claude_by_model { models.entry(m.clone()).or_default().0 += v; }
            for (m,v) in &a.cursor_by_model { models.entry(m.clone()).or_default().1 += v; }
            for (m,v) in &a.codex_by_model { models.entry(m.clone()).or_default().2 += v; }
        }
    }
    for (key,a) in &data { if key.starts_with(&month_prefix) { claude_month += a.claude_cost; cursor_month += a.cursor_cost; codex_month += a.codex_cost; } }
    let model_breakdown = models.into_iter().map(|(model,(claude,cursor,codex))| ModelRow{model,claude:pricing::round_cents(claude),cursor:pricing::round_cents(cursor),codex:pricing::round_cents(codex),total:pricing::round_cents(claude+cursor+codex)}).collect();
    let yesterday = data.get(&yesterday_key).map(|a| a.claude_cost+a.cursor_cost+a.codex_cost).unwrap_or(0.0);
    // Session-specific coaching from local transcript signals (Claude + Codex; Cursor gets rule-only tips).
    let mut top_sessions = scanner::top_sessions(today, 3);
    for s in &mut top_sessions {
        let signals = coach::load_signals(&s.id);
        s.tips = coach::coaching_tips(s, signals.as_ref(), 3);
        // Jira ticket auto-detect: branch first (e.g. feature/PROJ-123-x), then the title.
        s.issue_key = signals
            .as_ref()
            .and_then(|sig| sig.branch.as_deref())
            .and_then(jira::detect_issue_key)
            .or_else(|| jira::detect_issue_key(&s.title));
    }
    let mut insight_models = today.claude_by_model.clone();
    for (m,v) in &today.codex_by_model { *insight_models.entry(m.clone()).or_default() += v; }
    UsageSnapshot {
        as_of_date: today_key, today: pricing::round_cents(today.claude_cost+today.cursor_cost+today.codex_cost), month: pricing::round_cents(claude_month+cursor_month+codex_month), yesterday: pricing::round_cents(yesterday),
        claude_today:today.claude_cost,cursor_today:today.cursor_cost,codex_today:today.codex_cost,claude_month:pricing::round_cents(claude_month),cursor_month:pricing::round_cents(cursor_month),codex_month:pricing::round_cents(codex_month),sessions_today:today.sessions.len(),messages_today:today.claude_messages+today.cursor_messages+today.codex_messages,
        product_breakdown:today.claude_by_product.clone(),model_breakdown,days,top_sessions,tips:coach::tips(),insight:coach::insight(&today.claude_by_product,&insight_models,today.claude_cost+today.codex_cost),
        claude_path:scanner::claude_root().display().to_string(),cursor_path:scanner::cursor_db().display().to_string(),codex_path:scanner::codex_root().display().to_string()
    }
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_store::Builder::new().build())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_autostart::Builder::new().build())
        .invoke_handler(tauri::generate_handler![scan_usage, jira::jira_push_cost])
        .setup(|app| {
            use tauri::menu::{Menu, MenuItem}; use tauri::tray::TrayIconBuilder;
            let show=MenuItem::with_id(app,"show","Open dashboard",true,None::<&str>)?;
            let quit=MenuItem::with_id(app,"quit","Quit",true,None::<&str>)?;
            let menu=Menu::with_items(app,&[&show,&quit])?;
            let tray_icon = app.default_window_icon().cloned()
                .ok_or("Windows/macOS application icon is missing")?;
            TrayIconBuilder::new().icon(tray_icon).menu(&menu).tooltip("AI Usage Tracker").on_menu_event(|app,e| match e.id.as_ref(){"quit"=>app.exit(0),"show"=>{if let Some(w)=app.get_webview_window("main"){let _=w.show();let _=w.set_focus();}},_=>{}}).on_tray_icon_event(|tray,_|{if let Some(w)=tray.app_handle().get_webview_window("main"){let _=w.show();let _=w.set_focus();}}).build(app)?;
            Ok(())
        })
        .on_window_event(|window,event| if let WindowEvent::CloseRequested{api,..}=event { api.prevent_close(); let _=window.hide(); })
        .run(tauri::generate_context!()).expect("error running AI Usage Tracker");
}
