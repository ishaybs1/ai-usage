//! Local session scanner — a port of the Swift `LocalUsageScanner`.
//!
//! Reads Claude Code JSONL transcripts and Cursor composer bubbles, aggregates token usage by
//! LOCAL calendar day, and prices each request at the model that was actually used.
//!
//! Cross-platform paths (both resolve correctly on Windows and macOS via `dirs`):
//!   • Claude:  <home>/.claude/projects/**/*.jsonl
//!   • Cursor:  <app-data>/Cursor/User/globalStorage/state.vscdb
//!       - Windows: %APPDATA%\Cursor\User\globalStorage\state.vscdb
//!       - macOS:   ~/Library/Application Support/Cursor/User/globalStorage/state.vscdb

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
    pub claude_by_model: HashMap<String, f64>,
    pub cursor_by_model: HashMap<String, f64>,
    pub claude_by_product: HashMap<String, f64>,
    pub claude_tokens: TokenUsage,
    pub cursor_tokens: TokenUsage,
    pub claude_sessions: HashSet<String>,
    pub cursor_sessions: HashSet<String>,
    pub claude_messages: i64,
    pub cursor_messages: i64,
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
}

pub fn claude_root() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_default()
        .join(".claude")
        .join("projects")
}

pub fn cursor_db() -> PathBuf {
    // dirs::data_dir(): %APPDATA% on Windows, ~/Library/Application Support on macOS.
    dirs::data_dir()
        .unwrap_or_default()
        .join("Cursor")
        .join("User")
        .join("globalStorage")
        .join("state.vscdb")
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
    by_day
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

fn parse_claude_file(path: &std::path::Path, by_day: &mut HashMap<String, DayUsageAggregate>) {
    let data = match std::fs::read(path) {
        Ok(d) => d,
        Err(_) => return,
    };
    let mut seen_message_ids: HashSet<String> = HashSet::new();

    for line in data.split(|&b| b == b'\n') {
        if line.len() <= 2 {
            continue;
        }
        // Fast pre-filter: only lines carrying usage mention "input_tokens".
        if !contains_subslice(line, b"input_tokens") {
            continue;
        }
        let obj: Value = match serde_json::from_slice(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if obj.get("type").and_then(Value::as_str) != Some("assistant") {
            continue;
        }
        let msg = match obj.get("message") {
            Some(m) => m,
            None => continue,
        };
        let msg_id = match msg.get("id").and_then(Value::as_str) {
            Some(id) => id.to_string(),
            None => continue,
        };
        if seen_message_ids.contains(&msg_id) {
            continue;
        }

        let model = msg.get("model").and_then(Value::as_str).unwrap_or("");
        if model.is_empty() || model == "<synthetic>" {
            continue;
        }
        let usage = match msg.get("usage") {
            Some(u) => u,
            None => continue,
        };
        let has_any = int_field(usage.get("input_tokens")) > 0
            || int_field(usage.get("output_tokens")) > 0
            || int_field(usage.get("cache_read_input_tokens")) > 0;
        if !has_any {
            continue;
        }

        seen_message_ids.insert(msg_id);

        let tokens = claude_tokens(usage);
        let normalized = pricing::normalize(model);
        let cost = pricing::cost(&normalized, &tokens);

        let ts = obj
            .get("timestamp")
            .and_then(Value::as_str)
            .and_then(parse_iso8601)
            .unwrap_or_else(Local::now);
        let day = day_key(&ts);

        let agg = by_day.entry(day).or_default();
        agg.claude_cost = round_cents(agg.claude_cost + cost);
        add_model(&mut agg.claude_by_model, &normalized, cost);
        let product = claude_product(obj.get("entrypoint").and_then(Value::as_str));
        add_model(&mut agg.claude_by_product, &product, cost);
        agg.claude_tokens += tokens;

        if let Some(sid) = obj.get("sessionId").and_then(Value::as_str) {
            agg.claude_sessions.insert(sid.to_string());
            let key = format!("claude:{sid}");
            let s = agg.sessions.entry(key).or_insert_with(|| SessionAccum {
                tool: "Claude".to_string(),
                ..Default::default()
            });
            s.cost = round_cents(s.cost + cost);
            s.messages += 1;
            *s.by_model.entry(normalized.clone()).or_insert(0.0) += cost;
            s.tokens += tokens;
        }
        agg.claude_messages += 1;
    }
}

fn claude_tokens(usage: &Value) -> TokenUsage {
    let cache = usage.get("cache_creation");
    TokenUsage {
        input: int_field(usage.get("input_tokens")),
        output: int_field(usage.get("output_tokens")),
        cache_read: int_field(usage.get("cache_read_input_tokens")),
        cache_write_5m: cache
            .and_then(|c| c.get("ephemeral_5m_input_tokens"))
            .map(Some)
            .map(|v| int_field(v))
            .unwrap_or(0),
        cache_write_1h: cache
            .and_then(|c| c.get("ephemeral_1h_input_tokens"))
            .map(|v| int_field(Some(v)))
            .filter(|&v| v > 0)
            .unwrap_or_else(|| int_field(usage.get("cache_creation_input_tokens"))),
    }
}

fn claude_product(entrypoint: Option<&str>) -> String {
    match entrypoint {
        Some("cli") | Some("claude-vscode") => "claude_code".to_string(),
        _ => "claude_chat".to_string(),
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
            let fallback = format!("{} session {}", s.tool, &id_part.chars().take(8).collect::<String>());
            SessionCost {
                id: key.clone(),
                tool: s.tool.clone(),
                cost: s.cost,
                dominant_model: dominant,
                messages: s.messages,
                title: s.title.clone().unwrap_or(fallback),
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
}
