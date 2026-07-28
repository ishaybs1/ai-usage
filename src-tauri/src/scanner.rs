//! Local session scanner — a port of the Swift `LocalUsageScanner`.
//!
//! Reads Claude Code JSONL transcripts and Cursor composer bubbles, aggregates token usage by
//! LOCAL calendar day, and prices each request at the model that was actually used.
//!
//! Cross-platform paths (resolved on Windows, macOS, and Linux via `dirs`):
//!   • Claude:  <home>/.claude/projects/**/*.jsonl
//!   • Cursor:  <config-dir>/Cursor/User/globalStorage/state.vscdb
//!       - Windows: %APPDATA%\Cursor\User\globalStorage\state.vscdb
//!       - macOS:   ~/Library/Application Support/Cursor/User/globalStorage/state.vscdb
//!       - Linux:   ~/.config/Cursor/User/globalStorage/state.vscdb

use crate::pricing::{self, round_cents, TokenUsage};
use chrono::{DateTime, Local, TimeZone};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use walkdir::WalkDir;

/// Running per-session totals within a single day.
#[derive(Debug, Clone, Default)]
pub struct SessionAccum {
    pub tool: String, // "Claude" / "Cursor"
    pub cost: f64,
    pub messages: i64,
    pub by_model: HashMap<String, f64>,
    pub tokens: TokenUsage,
    pub title: Option<String>,
}

/// Everything aggregated for one local day.
#[derive(Debug, Clone, Default)]
pub struct DayUsageAggregate {
    pub claude_cost: f64,
    pub cursor_cost: f64,
    pub codex_cost: f64,
    pub claude_by_model: HashMap<String, f64>,
    pub cursor_by_model: HashMap<String, f64>,
    pub codex_by_model: HashMap<String, f64>,
    pub claude_by_product: HashMap<String, f64>,
    pub claude_tokens: TokenUsage,
    pub cursor_tokens: TokenUsage,
    pub codex_tokens: TokenUsage,
    pub claude_sessions: HashSet<String>,
    pub cursor_sessions: HashSet<String>,
    pub codex_sessions: HashSet<String>,
    pub claude_messages: i64,
    pub cursor_messages: i64,
    pub codex_messages: i64,
    /// keyed by "claude:<sessionId>" / "cursor:<composerId>".
    pub sessions: HashMap<String, SessionAccum>,
}

/// One expensive session, surfaced to the Cost Coach.
#[derive(Debug, Clone, serde::Serialize)]
pub struct SessionCost {
    pub id: String,
    pub tool: String,
    pub cost: f64,
    pub dominant_model: String,
    pub messages: i64,
    pub title: String,
    /// Session-specific coaching lines, filled by the Cost Coach.
    pub tips: Vec<String>,
    /// Jira issue key auto-detected from the session's git branch or title.
    pub issue_key: Option<String>,
}

pub fn claude_root() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_default()
        .join(".claude")
        .join("projects")
}

pub fn cursor_db() -> PathBuf {
    // dirs::config_dir(): %APPDATA% on Windows, ~/Library/Application Support on macOS,
    // ~/.config on Linux — Cursor's user-data root on all three.
    dirs::config_dir()
        .unwrap_or_default()
        .join("Cursor")
        .join("User")
        .join("globalStorage")
        .join("state.vscdb")
}

pub fn codex_root() -> PathBuf {
    dirs::home_dir().unwrap_or_default().join(".codex").join("sessions")
}

/// Local-time day key, "yyyy-MM-dd" (matches the Swift local-time day boundaries).
pub fn day_key(dt: &DateTime<Local>) -> String {
    dt.format("%Y-%m-%d").to_string()
}

fn epoch_ms_to_local(ms: f64) -> DateTime<Local> {
    Local
        .timestamp_millis_opt(ms as i64)
        .single()
        .unwrap_or_else(Local::now)
}

/// Full scan → per-day aggregates keyed by local day.
pub fn compute_by_day() -> HashMap<String, DayUsageAggregate> {
    let mut by_day: HashMap<String, DayUsageAggregate> = HashMap::new();
    scan_claude(&claude_root(), &mut by_day);
    scan_cursor(&cursor_db(), &mut by_day);
    scan_codex(&codex_root(), &mut by_day);
    by_day
}

// ---------------------------------------------------------------------------
// Codex
// ---------------------------------------------------------------------------

fn scan_codex(root: &PathBuf, by_day: &mut HashMap<String, DayUsageAggregate>) {
    if !root.exists() { return; }
    for entry in WalkDir::new(root).into_iter().filter_map(|e| e.ok()) {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) == Some("jsonl") {
            parse_codex_file(path, by_day);
        }
    }
}

fn parse_codex_file(path: &std::path::Path, by_day: &mut HashMap<String, DayUsageAggregate>) {
    let data = match std::fs::read(path) { Ok(d) => d, Err(_) => return };
    let mut session_id = path.file_stem().and_then(|s| s.to_str()).unwrap_or("unknown").to_string();
    let mut title: Option<String> = None;
    let mut model = "codex".to_string();
    let mut previous = TokenUsage::default();

    for line in data.split(|&b| b == b'\n') {
        let obj: Value = match serde_json::from_slice(line) { Ok(v) => v, Err(_) => continue };
        let kind = obj.get("type").and_then(Value::as_str).unwrap_or("");
        let payload = obj.get("payload").unwrap_or(&Value::Null);
        if kind == "session_meta" {
            if let Some(id) = payload.get("session_id").and_then(Value::as_str) { session_id = id.to_string(); }
            if let Some(cwd) = payload.get("cwd").and_then(Value::as_str) {
                title = std::path::Path::new(cwd).file_name().and_then(|s| s.to_str()).map(|s| format!("Codex in {s}"));
            }
            continue;
        }
        if kind == "turn_context" {
            if let Some(m) = payload.get("model").and_then(Value::as_str) { model = m.to_string(); }
            continue;
        }
        if kind != "event_msg" || payload.get("type").and_then(Value::as_str) != Some("token_count") { continue; }
        let total = match payload.get("info").and_then(|v| v.get("total_token_usage")) { Some(v) => v, None => continue };
        let current = TokenUsage {
            input: int_field(total.get("input_tokens")),
            output: int_field(total.get("output_tokens")),
            cache_read: int_field(total.get("cached_input_tokens")),
            ..Default::default()
        };
        let delta = codex_delta(current, previous);
        previous = current;
        if delta.input + delta.output <= 0 { continue; }
        let ts = obj.get("timestamp").and_then(Value::as_str).and_then(parse_iso8601).unwrap_or_else(Local::now);
        let day = day_key(&ts);
        let cost = pricing::codex_cost(&model, &delta);
        let agg = by_day.entry(day).or_default();
        agg.codex_cost = round_cents(agg.codex_cost + cost);
        add_model(&mut agg.codex_by_model, &model, cost);
        agg.codex_tokens += delta;
        agg.codex_sessions.insert(session_id.clone());
        agg.codex_messages += 1;
        let key = format!("codex:{session_id}");
        let s = agg.sessions.entry(key).or_insert_with(|| SessionAccum { tool: "Codex".to_string(), title: title.clone(), ..Default::default() });
        s.cost = round_cents(s.cost + cost);
        s.messages += 1;
        *s.by_model.entry(model.clone()).or_insert(0.0) += cost;
        s.tokens += delta;
    }
}

fn codex_delta(current: TokenUsage, previous: TokenUsage) -> TokenUsage {
    if current.input < previous.input || current.output < previous.output {
        return current;
    }
    TokenUsage {
        input: current.input - previous.input,
        output: current.output - previous.output,
        cache_read: (current.cache_read - previous.cache_read).max(0),
        ..Default::default()
    }
}

// ---------------------------------------------------------------------------
// Claude
// ---------------------------------------------------------------------------

fn scan_claude(root: &PathBuf, by_day: &mut HashMap<String, DayUsageAggregate>) {
    if !root.exists() {
        return;
    }
    for entry in WalkDir::new(root).into_iter().filter_map(|e| e.ok()) {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
            continue;
        }
        parse_claude_file(path, by_day);
    }
}

/// One JSONL record, reduced to the fields billing needs (Claudoscope-compatible rules).
#[derive(Debug, Default)]
struct RawClaudeRecord {
    index: usize,
    is_assistant: bool,
    uuid: Option<String>,
    session_id: Option<String>,
    timestamp: Option<String>,
    entrypoint: Option<String>,
    is_sidechain: bool,
    message_id: Option<String>,
    model: Option<String>,
    has_stop_reason: bool,
    has_usage: bool,
    tokens: TokenUsage,
    orphan_total: i64,
    is_fast: bool,
}

/// Context-forking subagent files replay the parent transcript before new calls.
fn is_context_fork_filename(name: &str) -> bool {
    name.starts_with("agent-acompact-") || name.starts_with("agent-aside_question-")
}

/// Billable assistant `message.id`s from the parent transcript of a subagent file
/// (`<session>/subagents/agent-*.jsonl` → `<session>.jsonl`).
fn parent_replay_message_ids(subagent_path: &std::path::Path) -> HashSet<String> {
    let mut ids = HashSet::new();
    let parent = match subagent_path.parent().and_then(|p| p.parent()) {
        Some(dir) => dir.with_extension("jsonl"),
        None => return ids,
    };
    let data = match std::fs::read(&parent) {
        Ok(d) => d,
        Err(_) => return ids,
    };
    for line in data.split(|&b| b == b'\n') {
        if line.len() <= 2 || !contains_subslice(line, b"input_tokens") {
            continue;
        }
        let obj: Value = match serde_json::from_slice(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if obj.get("type").and_then(Value::as_str) != Some("assistant") {
            continue;
        }
        if let Some(msg) = obj.get("message") {
            if msg.get("usage").is_some() {
                if let Some(id) = msg.get("id").and_then(Value::as_str) {
                    ids.insert(id.to_string());
                }
            }
        }
    }
    ids
}

fn parse_raw_claude(obj: &Value, index: usize) -> RawClaudeRecord {
    let msg = obj.get("message");
    let usage = msg.and_then(|m| m.get("usage"));
    // `speed` is the current field; `service_tier` is the legacy name.
    let speed = usage
        .and_then(|u| u.get("speed").or_else(|| u.get("service_tier")))
        .and_then(Value::as_str);
    let tokens = usage.map(claude_tokens).unwrap_or_default();
    let orphan_total = usage
        .map(|u| {
            int_field(u.get("input_tokens"))
                + int_field(u.get("output_tokens"))
                + int_field(u.get("cache_read_input_tokens"))
                + int_field(u.get("cache_creation_input_tokens"))
        })
        .unwrap_or(0);
    RawClaudeRecord {
        index,
        is_assistant: obj.get("type").and_then(Value::as_str) == Some("assistant"),
        uuid: obj.get("uuid").and_then(Value::as_str).map(str::to_string),
        session_id: obj.get("sessionId").and_then(Value::as_str).map(str::to_string),
        timestamp: obj.get("timestamp").and_then(Value::as_str).map(str::to_string),
        entrypoint: obj.get("entrypoint").and_then(Value::as_str).map(str::to_string),
        is_sidechain: obj.get("isSidechain").and_then(Value::as_bool).unwrap_or(false),
        message_id: msg.and_then(|m| m.get("id")).and_then(Value::as_str).map(str::to_string),
        model: msg.and_then(|m| m.get("model")).and_then(Value::as_str).map(str::to_string),
        has_stop_reason: msg
            .and_then(|m| m.get("stop_reason"))
            .map(|v| !v.is_null())
            .unwrap_or(false),
        has_usage: usage.is_some(),
        tokens,
        orphan_total,
        is_fast: speed.map(|s| s != "standard").unwrap_or(false),
    }
}

/// For message ids never seen with `stop_reason`, pick the record index carrying the max
/// cumulative usage so streamed partials aren't billed.
fn select_orphan_indices(
    records: &[RawClaudeRecord],
    stop_reason_ids: &HashSet<String>,
) -> HashMap<String, usize> {
    let mut chosen: HashMap<String, usize> = HashMap::new();
    let mut best_total: HashMap<String, i64> = HashMap::new();
    for raw in records {
        let id = match (&raw.message_id, raw.is_assistant, raw.has_usage) {
            (Some(id), true, true) if !stop_reason_ids.contains(id) => id,
            _ => continue,
        };
        if let Some(prev) = best_total.get(id) {
            if raw.orphan_total < *prev {
                continue;
            }
        }
        best_total.insert(id.clone(), raw.orphan_total);
        chosen.insert(id.clone(), raw.index);
    }
    chosen
}

/// Label material gathered from the first lines of a session file.
#[derive(Debug, Default)]
struct LabelParts {
    cwd: Option<String>,
    ai_title: Option<String>,
    first_user: Option<String>,
}

fn parse_claude_file(path: &std::path::Path, by_day: &mut HashMap<String, DayUsageAggregate>) {
    let data = match std::fs::read(path) {
        Ok(d) => d,
        Err(_) => return,
    };
    let file_session_id = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("unknown")
        .to_string();
    let is_subagent_file = path
        .parent()
        .and_then(|p| p.file_name())
        .and_then(|n| n.to_str())
        == Some("subagents");
    let file_name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
    let parent_replay: HashSet<String> = if is_subagent_file && is_context_fork_filename(file_name) {
        parent_replay_message_ids(path)
    } else {
        HashSet::new()
    };

    // Pass 1: reduce lines to raw records; collect session-label material on the way.
    let mut records: Vec<RawClaudeRecord> = Vec::new();
    let mut label = LabelParts::default();
    let mut line_count = 0usize;
    for line in data.split(|&b| b == b'\n') {
        if line.len() <= 2 {
            continue;
        }
        let obj: Value = match serde_json::from_slice(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        line_count += 1;
        if line_count <= 800 {
            collect_label_parts(&obj, &mut label);
        }
        records.push(parse_raw_claude(&obj, records.len()));
    }

    let stop_reason_ids: HashSet<String> = records
        .iter()
        .filter(|r| r.is_assistant && r.has_stop_reason)
        .filter_map(|r| r.message_id.clone())
        .collect();
    let orphan_chosen = select_orphan_indices(&records, &stop_reason_ids);
    let title = claude_session_label(&label, path);

    // Pass 2: bill.
    let mut seen_msg_ids: HashSet<String> = HashSet::new();
    let mut seen_uuids: HashSet<String> = HashSet::new();
    let mut parent_session_id: Option<String> = None;
    let mut is_first = true;
    let mut last_day_key: Option<String> = None;

    for raw in &records {
        if let Some(ts) = raw.timestamp.as_deref().and_then(parse_iso8601) {
            last_day_key = Some(day_key(&ts));
        }
        let is_sidechain = raw.is_sidechain || is_subagent_file;
        if is_first {
            is_first = false;
            if !is_sidechain {
                if let Some(sid) = &raw.session_id {
                    // A resumed session's file replays its parent transcript first.
                    if *sid != file_session_id {
                        parent_session_id = Some(sid.clone());
                    }
                }
            }
        }
        if !is_sidechain {
            if let (Some(parent), Some(sid)) = (&parent_session_id, &raw.session_id) {
                if sid == parent {
                    continue;
                }
            }
        }
        if !raw.is_assistant || !raw.has_usage {
            continue;
        }

        // Bill only final cumulative records: stop_reason, or the max-usage orphan record.
        let is_orphan = raw
            .message_id
            .as_ref()
            .map(|id| !stop_reason_ids.contains(id))
            .unwrap_or(true);
        if !raw.has_stop_reason && !is_orphan {
            continue;
        }
        if is_orphan {
            if let Some(id) = &raw.message_id {
                if orphan_chosen.get(id) != Some(&raw.index) {
                    continue;
                }
            }
        }
        if let Some(id) = &raw.message_id {
            if parent_replay.contains(id) {
                continue;
            }
            if !seen_msg_ids.insert(id.clone()) {
                continue;
            }
        }
        if let Some(uuid) = &raw.uuid {
            if !seen_uuids.insert(uuid.clone()) {
                continue;
            }
        }

        let model = raw.model.as_deref().unwrap_or("");
        if model.is_empty() || model == "<synthetic>" {
            continue;
        }
        if raw.tokens.total() <= 0 {
            continue;
        }

        let multiplier = if raw.is_fast { 2.0 } else { 1.0 };
        let normalized = pricing::normalize(model);
        let cost = pricing::cost_with_speed(&normalized, &raw.tokens, multiplier);
        let day = raw
            .timestamp
            .as_deref()
            .and_then(parse_iso8601)
            .map(|ts| day_key(&ts))
            .or_else(|| last_day_key.clone())
            .unwrap_or_else(|| "1970-01-01".to_string());

        let agg = by_day.entry(day).or_default();
        agg.claude_cost = round_cents(agg.claude_cost + cost);
        add_model(&mut agg.claude_by_model, &normalized, cost);
        let product = claude_product(raw.entrypoint.as_deref());
        add_model(&mut agg.claude_by_product, &product, cost);
        agg.claude_tokens += raw.tokens;

        let sid = raw.session_id.clone().unwrap_or_else(|| file_session_id.clone());
        agg.claude_sessions.insert(sid.clone());
        let key = format!("claude:{sid}");
        let s = agg.sessions.entry(key).or_insert_with(|| SessionAccum {
            tool: "Claude".to_string(),
            ..Default::default()
        });
        s.cost = round_cents(s.cost + cost);
        s.messages += 1;
        *s.by_model.entry(normalized.clone()).or_insert(0.0) += cost;
        s.tokens += raw.tokens;
        if s.title.is_none() && sid == file_session_id {
            s.title = title.clone();
        }
        agg.claude_messages += 1;
    }
}

fn claude_tokens(usage: &Value) -> TokenUsage {
    let cache = usage.get("cache_creation");
    let breakdown_5m = cache.and_then(|c| c.get("ephemeral_5m_input_tokens"));
    let breakdown_1h = cache.and_then(|c| c.get("ephemeral_1h_input_tokens"));
    // Prefer the per-TTL breakdown; the legacy flat count is 5-minute-tier writes.
    let (w5, w1h) = if breakdown_5m.is_some() || breakdown_1h.is_some() {
        (int_field(breakdown_5m), int_field(breakdown_1h))
    } else {
        (int_field(usage.get("cache_creation_input_tokens")), 0)
    };
    TokenUsage {
        input: int_field(usage.get("input_tokens")),
        output: int_field(usage.get("output_tokens")),
        cache_read: int_field(usage.get("cache_read_input_tokens")),
        cache_write_5m: w5,
        cache_write_1h: w1h,
    }
}

fn claude_product(entrypoint: Option<&str>) -> String {
    match entrypoint {
        Some("cli") | Some("claude-vscode") => "claude_code".to_string(),
        _ => "claude_chat".to_string(),
    }
}

// ---------------------------------------------------------------------------
// Claude session labels — "repo — summary" instead of "Claude session cdaf8825"
// ---------------------------------------------------------------------------

fn collect_label_parts(obj: &Value, label: &mut LabelParts) {
    if label.cwd.is_none() {
        if let Some(c) = obj.get("cwd").and_then(Value::as_str) {
            if !c.is_empty() {
                label.cwd = Some(c.to_string());
            }
        }
    }
    let kind = obj.get("type").and_then(Value::as_str);
    if label.ai_title.is_none() && kind == Some("ai-title") {
        if let Some(t) = obj.get("aiTitle").and_then(Value::as_str) {
            let t = t.trim();
            if !t.is_empty() {
                label.ai_title = Some(t.to_string());
            }
        }
    }
    if label.first_user.is_none() && kind == Some("user") {
        if let Some(text) = user_text(obj) {
            label.first_user = Some(text);
        }
    }
}

/// First line of a real user prompt — skips tool wrappers, slash commands, and meta noise.
pub fn user_text(obj: &Value) -> Option<String> {
    let message = obj.get("message")?;
    let raw = match message.get("content") {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Array(parts)) => parts
            .iter()
            .find(|p| p.get("type").and_then(Value::as_str) == Some("text"))?
            .get("text")
            .and_then(Value::as_str)?
            .to_string(),
        _ => return None,
    };
    let mut text = raw.trim();
    if text.is_empty() || text.starts_with('<') || text.starts_with('/') {
        return None;
    }
    if text.to_lowercase().starts_with("caveat:") {
        return None;
    }
    if let Some(nl) = text.find('\n') {
        text = text[..nl].trim();
    }
    if text.is_empty() {
        None
    } else {
        Some(text.to_string())
    }
}

fn claude_session_label(label: &LabelParts, path: &std::path::Path) -> Option<String> {
    let repo = repo_name(label.cwd.as_deref(), path);
    let summary = if let Some(t) = &label.ai_title {
        Some(truncate_words(&clean_whitespace(t), 8))
    } else {
        label
            .first_user
            .as_ref()
            .map(|u| truncate_words(&clean_whitespace(u), 5))
            .filter(|s| !s.is_empty())
    };
    match (repo, summary) {
        (Some(r), Some(s)) => Some(format!("{r} — {s}")),
        (Some(r), None) => Some(r),
        (None, Some(s)) => Some(s),
        (None, None) => None,
    }
}

pub fn repo_name(cwd: Option<&str>, path: &std::path::Path) -> Option<String> {
    if let Some(cwd) = cwd {
        if let Some(name) = std::path::Path::new(cwd)
            .file_name()
            .and_then(|n| n.to_str())
        {
            if !is_boring_repo(name) {
                return Some(name.to_string());
            }
        }
    }
    // Parent folder is often "-Users-…-projects-my-repo"; subagent files sit one level deeper.
    let parent = path.parent()?;
    let parent_name = parent.file_name().and_then(|n| n.to_str())?;
    if parent_name == "subagents" {
        return repo_name(None, parent);
    }
    decode_project_dir(parent_name)
}

fn is_boring_repo(name: &str) -> bool {
    name == "/" || name == "projects" || name == "Desktop" || name == "Users" || name.starts_with('.')
}

/// "-Users-ishay-projects-my-repo" → "my-repo"
pub fn decode_project_dir(encoded: &str) -> Option<String> {
    if !encoded.starts_with('-') {
        return None;
    }
    let tokens: Vec<&str> = encoded.split('-').filter(|t| !t.is_empty()).collect();
    if let Some(idx) = tokens.iter().rposition(|t| *t == "projects") {
        if idx + 1 < tokens.len() {
            let repo = tokens[idx + 1..].join("-");
            if !repo.is_empty() {
                return Some(repo);
            }
        }
    }
    tokens.last().map(|t| t.to_string())
}

fn clean_whitespace(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

pub fn truncate_words(s: &str, max_words: usize) -> String {
    let words: Vec<&str> = s.split_whitespace().collect();
    if words.len() <= max_words {
        s.trim().to_string()
    } else {
        words[..max_words].join(" ")
    }
}

// ---------------------------------------------------------------------------
// Cursor
// ---------------------------------------------------------------------------

fn scan_cursor(db_path: &PathBuf, by_day: &mut HashMap<String, DayUsageAggregate>) {
    if !db_path.exists() {
        return;
    }
    let conn = match rusqlite::Connection::open_with_flags(
        db_path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_URI,
    ) {
        Ok(c) => c,
        Err(_) => return,
    };

    // composerData:* → per-composer last-updated date + title.
    let mut composer_dates: HashMap<String, DateTime<Local>> = HashMap::new();
    let mut composer_titles: HashMap<String, String> = HashMap::new();
    if let Ok(mut stmt) =
        conn.prepare("SELECT key, value FROM cursorDiskKV WHERE key LIKE 'composerData:%'")
    {
        let rows = stmt.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        });
        if let Ok(rows) = rows {
            for (key, val) in rows.flatten() {
                let obj: Value = match serde_json::from_str(&val) {
                    Ok(v) => v,
                    Err(_) => continue,
                };
                let cid = obj
                    .get("composerId")
                    .and_then(Value::as_str)
                    .map(str::to_string)
                    .unwrap_or_else(|| key.rsplit(':').next().unwrap_or("").to_string());
                if let Some(ms) = obj
                    .get("lastUpdatedAt")
                    .and_then(Value::as_f64)
                    .or_else(|| obj.get("createdAt").and_then(Value::as_f64))
                {
                    composer_dates.insert(cid.clone(), epoch_ms_to_local(ms));
                }
                let raw = obj
                    .get("name")
                    .and_then(Value::as_str)
                    .or_else(|| obj.get("text").and_then(Value::as_str))
                    .unwrap_or("")
                    .trim();
                if !raw.is_empty() {
                    let first_line = raw.lines().next().unwrap_or("");
                    let title: String = first_line.chars().take(60).collect();
                    composer_titles.insert(cid, title);
                }
            }
        }
    }

    // bubbleId:* → per-message token counts.
    if let Ok(mut stmt) =
        conn.prepare("SELECT key, value FROM cursorDiskKV WHERE key LIKE 'bubbleId:%'")
    {
        let rows = stmt.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        });
        if let Ok(rows) = rows {
            for (key, val) in rows.flatten() {
                let obj: Value = match serde_json::from_str(&val) {
                    Ok(v) => v,
                    Err(_) => continue,
                };
                let tc = match obj.get("tokenCount") {
                    Some(t) => t,
                    None => continue,
                };
                let input = int_field(tc.get("inputTokens"));
                let output = int_field(tc.get("outputTokens"));
                if input + output <= 0 {
                    continue;
                }
                let parts: Vec<&str> = key.split(':').collect();
                let composer_id = if parts.len() >= 2 { parts[1] } else { "" }.to_string();
                let model = cursor_model(&obj);
                let tokens = TokenUsage { input, output, ..Default::default() };
                let normalized = pricing::normalize(&model);
                let cost = pricing::cost(&normalized, &tokens);

                let day = day_key(composer_dates.get(&composer_id).unwrap_or(&Local::now()));
                let agg = by_day.entry(day).or_default();
                agg.cursor_cost = round_cents(agg.cursor_cost + cost);
                add_model(&mut agg.cursor_by_model, &normalized, cost);
                agg.cursor_tokens += tokens;
                agg.cursor_sessions.insert(composer_id.clone());
                agg.cursor_messages += 1;
                let skey = format!("cursor:{composer_id}");
                let title = composer_titles.get(&composer_id).cloned();
                let s = agg.sessions.entry(skey).or_insert_with(|| SessionAccum {
                    tool: "Cursor".to_string(),
                    title,
                    ..Default::default()
                });
                s.cost = round_cents(s.cost + cost);
                s.messages += 1;
                *s.by_model.entry(normalized.clone()).or_insert(0.0) += cost;
                s.tokens += tokens;
            }
        }
    };
}

fn cursor_model(bubble: &Value) -> String {
    if let Some(name) = bubble
        .get("modelInfo")
        .and_then(|i| i.get("modelName"))
        .and_then(Value::as_str)
    {
        if !name.is_empty() {
            return name.to_string();
        }
    }
    pricing::CURSOR_DEFAULT_MODEL.to_string()
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn add_model(map: &mut HashMap<String, f64>, key: &str, cost: f64) {
    let e = map.entry(key.to_string()).or_insert(0.0);
    *e = round_cents(*e + cost);
}

/// Token counts arrive as Int, Double, or numeric String across payloads — coerce safely.
fn int_field(v: Option<&Value>) -> i64 {
    match v {
        Some(Value::Number(n)) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)).unwrap_or(0),
        Some(Value::String(s)) => s.parse::<i64>().unwrap_or(0),
        _ => 0,
    }
}

fn contains_subslice(haystack: &[u8], needle: &[u8]) -> bool {
    if needle.is_empty() || haystack.len() < needle.len() {
        return false;
    }
    haystack
        .windows(needle.len())
        .any(|w| w == needle)
}

/// Parse an ISO-8601 timestamp (with or without fractional seconds) into local time.
fn parse_iso8601(s: &str) -> Option<DateTime<Local>> {
    DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|dt| dt.with_timezone(&Local))
}

// ---------------------------------------------------------------------------
// Queries over a computed map
// ---------------------------------------------------------------------------

/// The `limit` most expensive sessions on a day, richest first.
pub fn top_sessions(agg: &DayUsageAggregate, limit: usize) -> Vec<SessionCost> {
    let mut out: Vec<SessionCost> = agg
        .sessions
        .iter()
        .filter(|(_, s)| s.cost > 0.0)
        .map(|(key, s)| {
            let dominant = s
                .by_model
                .iter()
                .max_by(|a, b| a.1.partial_cmp(b.1).unwrap_or(std::cmp::Ordering::Equal))
                .map(|(m, _)| m.clone())
                .unwrap_or_default();
            let id_part = key.rsplit(':').next().unwrap_or(key);
            let fallback = format!("{} session {}", s.tool, id_part.chars().take(8).collect::<String>());
            SessionCost {
                id: key.clone(),
                tool: s.tool.clone(),
                cost: s.cost,
                dominant_model: dominant,
                messages: s.messages,
                title: s.title.clone().unwrap_or(fallback),
                tips: Vec::new(),
                issue_key: None,
            }
        })
        .collect();
    out.sort_by(|a, b| b.cost.partial_cmp(&a.cost).unwrap_or(std::cmp::Ordering::Equal));
    out.truncate(limit);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn subslice_search() {
        assert!(contains_subslice(b"has input_tokens here", b"input_tokens"));
        assert!(!contains_subslice(b"nothing", b"input_tokens"));
    }

    #[test]
    fn int_field_coercions() {
        assert_eq!(int_field(Some(&serde_json::json!(42))), 42);
        assert_eq!(int_field(Some(&serde_json::json!("42"))), 42);
        assert_eq!(int_field(Some(&serde_json::json!(4.9))), 4);
        assert_eq!(int_field(None), 0);
    }

    fn write_jsonl(dir: &std::path::Path, name: &str, lines: &[&str]) -> std::path::PathBuf {
        let path = dir.join(name);
        std::fs::write(&path, lines.join("\n")).unwrap();
        path
    }

    #[test]
    fn streamed_partials_bill_only_the_stop_reason_record() {
        let dir = std::env::temp_dir().join("aiut-test-stop-reason");
        std::fs::create_dir_all(&dir).unwrap();
        let path = write_jsonl(&dir, "s1.jsonl", &[
            // Streamed partial (no stop_reason, low cumulative usage) then the final record.
            r#"{"type":"assistant","uuid":"u1","sessionId":"s1","timestamp":"2026-07-28T10:00:00Z","message":{"id":"m1","model":"claude-opus-4-8","stop_reason":null,"usage":{"input_tokens":10,"output_tokens":5}}}"#,
            r#"{"type":"assistant","uuid":"u2","sessionId":"s1","timestamp":"2026-07-28T10:00:05Z","message":{"id":"m1","model":"claude-opus-4-8","stop_reason":"end_turn","usage":{"input_tokens":1000000,"output_tokens":1000000}}}"#,
        ]);
        let mut by_day = HashMap::new();
        parse_claude_file(&path, &mut by_day);
        let agg = by_day.get("2026-07-28").expect("day aggregated");
        // Only the final record: 1M in @ $5 + 1M out @ $25 = $30, not the partial.
        assert_eq!(agg.claude_cost, 30.0);
        assert_eq!(agg.claude_messages, 1);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn orphan_messages_bill_the_max_usage_record_once() {
        let dir = std::env::temp_dir().join("aiut-test-orphan");
        std::fs::create_dir_all(&dir).unwrap();
        let path = write_jsonl(&dir, "s2.jsonl", &[
            // No stop_reason anywhere: bill the max-cumulative record only.
            r#"{"type":"assistant","uuid":"u1","sessionId":"s2","timestamp":"2026-07-28T11:00:00Z","message":{"id":"m1","model":"claude-sonnet-4-6","usage":{"input_tokens":100,"output_tokens":50}}}"#,
            r#"{"type":"assistant","uuid":"u2","sessionId":"s2","timestamp":"2026-07-28T11:00:05Z","message":{"id":"m1","model":"claude-sonnet-4-6","usage":{"input_tokens":1000000,"output_tokens":0}}}"#,
        ]);
        let mut by_day = HashMap::new();
        parse_claude_file(&path, &mut by_day);
        let agg = by_day.get("2026-07-28").expect("day aggregated");
        // Max record: 1M input @ $3 = $3.00.
        assert_eq!(agg.claude_cost, 3.0);
        assert_eq!(agg.claude_messages, 1);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn fast_mode_doubles_cost() {
        let dir = std::env::temp_dir().join("aiut-test-fast");
        std::fs::create_dir_all(&dir).unwrap();
        let path = write_jsonl(&dir, "s3.jsonl", &[
            r#"{"type":"assistant","uuid":"u1","sessionId":"s3","timestamp":"2026-07-28T12:00:00Z","message":{"id":"m1","model":"claude-opus-4-8","stop_reason":"end_turn","usage":{"input_tokens":1000000,"output_tokens":1000000,"speed":"fast"}}}"#,
        ]);
        let mut by_day = HashMap::new();
        parse_claude_file(&path, &mut by_day);
        let agg = by_day.get("2026-07-28").expect("day aggregated");
        assert_eq!(agg.claude_cost, 60.0); // $30 × 2
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn legacy_cache_creation_maps_to_5m_tier() {
        let usage = serde_json::json!({"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":300});
        let t = claude_tokens(&usage);
        assert_eq!(t.cache_write_5m, 300);
        assert_eq!(t.cache_write_1h, 0);
    }

    #[test]
    fn decode_project_dir_extracts_repo() {
        assert_eq!(decode_project_dir("-Users-ishay-projects-my-repo").as_deref(), Some("my-repo"));
        assert_eq!(decode_project_dir("plain").as_deref(), None);
    }

    #[test]
    fn codex_cumulative_counts_become_deltas() {
        let previous = TokenUsage { input: 1_000, output: 100, cache_read: 600, ..Default::default() };
        let current = TokenUsage { input: 1_600, output: 180, cache_read: 900, ..Default::default() };
        assert_eq!(codex_delta(current, previous), TokenUsage { input: 600, output: 80, cache_read: 300, ..Default::default() });
    }
}
