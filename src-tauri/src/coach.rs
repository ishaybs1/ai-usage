//! Cost coaching — a port of the Swift v1.4 `CoachAdvisor` + `TranscriptSignals`.
//! Rule-based, no API calls; tips cite real repo/branch/prompt facts from local transcripts.

use crate::scanner::{self, SessionCost};
use chrono::{Datelike, Local};
use serde::Serialize;
use serde_json::Value;
use std::collections::HashMap;

// ---------------------------------------------------------------------------
// Transcript signals — a lightweight pass over one session's local log
// ---------------------------------------------------------------------------

#[derive(Debug, Default)]
pub struct TranscriptSignals {
    pub repo: Option<String>,
    pub branch: Option<String>,
    pub ai_title: Option<String>,
    pub user_prompt_count: i64,
    pub short_prompt_count: i64, // ≤3 words
    pub interrupt_count: i64,
    pub tool_use_turns: i64,
    pub assistant_turns: i64,
    pub model_counts: HashMap<String, i64>,
    pub sample_prompts: Vec<String>, // substantive openers
    pub weak_prompts: Vec<String>,   // short / vague lines
}

impl TranscriptSignals {
    pub fn short_prompt_share(&self) -> f64 {
        if self.user_prompt_count == 0 {
            return 0.0;
        }
        self.short_prompt_count as f64 / self.user_prompt_count as f64
    }

    pub fn opus_assistant_share(&self) -> f64 {
        if self.assistant_turns == 0 {
            return 0.0;
        }
        let opus: i64 = self
            .model_counts
            .iter()
            .filter(|(k, _)| k.to_lowercase().contains("opus"))
            .map(|(_, v)| v)
            .sum();
        opus as f64 / self.assistant_turns as f64
    }
}

/// `session_key` is "claude:<uuid>" or "codex:<uuid>".
pub fn load_signals(session_key: &str) -> Option<TranscriptSignals> {
    if let Some(id) = session_key.strip_prefix("claude:") {
        let path = find_claude_jsonl(id)?;
        let data = std::fs::read(&path).ok()?;
        return Some(parse_claude_signals(&data, &path));
    }
    if let Some(id) = session_key.strip_prefix("codex:") {
        let path = find_codex_jsonl(id)?;
        let data = std::fs::read(&path).ok()?;
        return Some(parse_codex_signals(&data));
    }
    None
}

fn find_claude_jsonl(session_id: &str) -> Option<std::path::PathBuf> {
    let exact = format!("{session_id}.jsonl");
    for entry in walkdir::WalkDir::new(scanner::claude_root())
        .into_iter()
        .filter_map(|e| e.ok())
    {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
            continue;
        }
        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
        if name == exact || name.starts_with(session_id) {
            return Some(path.to_path_buf());
        }
    }
    None
}

fn find_codex_jsonl(session_id: &str) -> Option<std::path::PathBuf> {
    for entry in walkdir::WalkDir::new(scanner::codex_root())
        .into_iter()
        .filter_map(|e| e.ok())
    {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
            continue;
        }
        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
        if name.contains(session_id) {
            return Some(path.to_path_buf());
        }
    }
    None
}

fn parse_claude_signals(data: &[u8], path: &std::path::Path) -> TranscriptSignals {
    let mut s = TranscriptSignals::default();
    s.repo = scanner::repo_name(None, path);

    let mut line_count = 0;
    for line in data.split(|&b| b == b'\n') {
        if line.len() <= 2 {
            continue;
        }
        line_count += 1;
        if line_count > 12_000 {
            break; // cap huge transcripts
        }
        let obj: Value = match serde_json::from_slice(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if s.branch.is_none() {
            if let Some(b) = obj.get("gitBranch").and_then(Value::as_str) {
                if !b.is_empty() {
                    s.branch = Some(b.to_string());
                }
            }
        }
        if let Some(cwd) = obj.get("cwd").and_then(Value::as_str) {
            if let Some(repo) = scanner::repo_name(Some(cwd), path) {
                s.repo = Some(repo);
            }
        }
        let kind = obj.get("type").and_then(Value::as_str);
        if kind == Some("ai-title") && s.ai_title.is_none() {
            if let Some(t) = obj.get("aiTitle").and_then(Value::as_str) {
                let t = t.trim();
                if !t.is_empty() {
                    s.ai_title = Some(t.to_string());
                }
            }
        }
        if kind == Some("assistant") {
            if let Some(message) = obj.get("message") {
                s.assistant_turns += 1;
                if let Some(model) = message.get("model").and_then(Value::as_str) {
                    if !model.is_empty() {
                        *s.model_counts.entry(model.to_string()).or_insert(0) += 1;
                    }
                }
                let has_tool_use = message
                    .get("content")
                    .and_then(Value::as_array)
                    .map(|parts| {
                        parts
                            .iter()
                            .any(|p| p.get("type").and_then(Value::as_str) == Some("tool_use"))
                    })
                    .unwrap_or(false);
                if has_tool_use {
                    s.tool_use_turns += 1;
                }
            }
        }
        if kind == Some("user") {
            if let Some(text) = scanner::user_text(&obj) {
                record_prompt(&mut s, &text);
            } else if let Some(raw) = obj
                .get("message")
                .and_then(|m| m.get("content"))
                .and_then(Value::as_str)
            {
                if raw.to_lowercase().contains("request interrupted") {
                    s.interrupt_count += 1;
                }
            }
        }
    }
    s
}

fn parse_codex_signals(data: &[u8]) -> TranscriptSignals {
    let mut s = TranscriptSignals::default();
    let mut line_count = 0;
    for line in data.split(|&b| b == b'\n') {
        if line.len() <= 2 {
            continue;
        }
        line_count += 1;
        if line_count > 12_000 {
            break;
        }
        let obj: Value = match serde_json::from_slice(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let kind = obj.get("type").and_then(Value::as_str).unwrap_or("");
        let payload = obj.get("payload").unwrap_or(&Value::Null);
        match kind {
            "session_meta" => {
                if let Some(cwd) = payload.get("cwd").and_then(Value::as_str) {
                    s.repo = std::path::Path::new(cwd)
                        .file_name()
                        .and_then(|n| n.to_str())
                        .map(str::to_string);
                }
            }
            "turn_context" => {
                if let Some(m) = payload.get("model").and_then(Value::as_str) {
                    *s.model_counts.entry(m.to_string()).or_insert(0) += 1;
                }
            }
            "event_msg" => match payload.get("type").and_then(Value::as_str) {
                Some("user_message") => {
                    if let Some(text) = payload.get("message").and_then(Value::as_str) {
                        let text = text.trim();
                        if !text.is_empty() && !text.starts_with('<') && !text.starts_with('/') {
                            let first_line = text.lines().next().unwrap_or("").trim();
                            if !first_line.is_empty() {
                                record_prompt(&mut s, first_line);
                            }
                        }
                    }
                }
                Some("turn_aborted") => s.interrupt_count += 1,
                Some("token_count") => s.assistant_turns += 1,
                _ => {}
            },
            _ => {}
        }
    }
    s
}

fn record_prompt(s: &mut TranscriptSignals, text: &str) {
    s.user_prompt_count += 1;
    let words = text.split_whitespace().count();
    if words <= 3 {
        s.short_prompt_count += 1;
        if s.weak_prompts.len() < 5 {
            s.weak_prompts.push(text.chars().take(80).collect());
        }
    } else if s.sample_prompts.len() < 8 {
        s.sample_prompts.push(text.chars().take(120).collect());
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct CoachTip {
    pub rank: i32,
    pub title: String,
    pub detail: String,
    pub wrong: String,
    pub right: String,
}

/// (title, detail, wrong, right)
const TIP_POOL: &[(&str, &str, &str, &str)] = &[
    ("Say the goal up front", "Name your setup and what \u{201c}done\u{201d} means in the first message.",
     "You sent \u{201c}but it runs on Jenkins\u{201d} only after the agent had started building.",
     "\u{201c}This runs on Jenkins \u{2014} target that from the first step.\u{201d}"),
    ("Batch your questions", "Ask for everything in one probe, not many back-and-forth commands.",
     "Opening a pipeline run link, then asking for its logs, then the failing step \u{2014} one message each.",
     "\u{201c}Pull run #331, its logs, and the failing step in one go.\u{201d}"),
    ("Ask for the answer, not yes/no", "A yes/no reply costs an extra turn \u{2014} ask for the outcome directly.",
     "\u{201c}\u{2026}release/331 \u{2026} can you look into it?\u{201d} \u{2014} vague, so it explores before helping.",
     "\u{201c}Why did release #331 fail on master, and how do I fix it?\u{201d}"),
    ("Use Sonnet for routine work", "Reserve Opus for hard reasoning; Sonnet is ~5\u{d7} cheaper for edits and Q&A.",
     "Running Opus for \u{201c}change commit message and branch to feature/rtfs-4025\u{201d}.",
     "Sonnet for chores like renames; Opus only for hard debugging."),
    ("Hand over paths and flags", "Give exact file paths and commands so the agent doesn\u{2019}t reverse-engineer them.",
     "Letting it hunt for the findings PDF instead of giving the path.",
     "\u{201c}Use /Users/ishaybs/Desktop/RT-Scalability-FINDINGS.pdf.\u{201d}"),
    ("Say how to verify", "State the success check up front so the agent stops when it\u{2019}s actually done.",
     "\u{201c}update me it succeeded\u{201d} with no defined check \u{2014} so it can\u{2019}t confirm.",
     "\u{201c}Confirm the deploy by checking the feature-flag value flipped.\u{201d}"),
    ("Start fresh for new tasks", "Long threads re-send all history every turn \u{2014} open a new chat for unrelated work.",
     "Jumping from the MFE pipeline to a billing-doc task in the same long thread.",
     "New chat for the billing doc \u{2014} none of the pipeline history re-sent."),
    ("Give context, not one word", "A bare word makes the agent reconstruct state \u{2014} say what you actually want.",
     "Sending just \u{201c}status\u{201d} when a run failed.",
     "\u{201c}The release run failed at the publish step \u{2014} here\u{2019}s the log; what broke?\u{201d}"),
    ("Name constraints early", "List every target/limit in the first message, before it plans around the wrong one.",
     "Adding \u{201c}also run on ../f8n nightly\u{201d} after the plan was already made.",
     "\u{201c}Run the test on the repo and ../f8n, both in nightly.\u{201d}"),
];

/// The 3 tips for today's LOCAL day — a deterministic rotating slice of the pool.
pub fn tips() -> Vec<CoachTip> {
    let n = TIP_POOL.len() as i64;
    if n == 0 {
        return vec![];
    }
    // Days since the Unix epoch in local time.
    let now = Local::now();
    let day_number = now.date_naive().num_days_from_ce() as i64
        - chrono::NaiveDate::from_ymd_opt(1970, 1, 1).unwrap().num_days_from_ce() as i64;
    let offset = (((day_number * 3) % n) + n) % n;
    (0..3.min(n))
        .map(|i| {
            let base = TIP_POOL[((offset + i) % n) as usize];
            CoachTip {
                rank: (i + 1) as i32,
                title: base.0.to_string(),
                detail: base.1.to_string(),
                wrong: base.2.to_string(),
                right: base.3.to_string(),
            }
        })
        .collect()
}

/// One observation from the user's own spend, or None if there's no strong signal.
pub fn insight(
    product_breakdown: &HashMap<String, f64>,
    model_breakdown: &HashMap<String, f64>,
    today: f64,
) -> Option<String> {
    if today <= 0.0 {
        return None;
    }
    let model_total: f64 = model_breakdown.values().sum();
    if model_total > 0.0 {
        let opus: f64 = model_breakdown
            .iter()
            .filter(|(k, _)| k.contains("opus"))
            .map(|(_, v)| v)
            .sum();
        let opus_share = opus / model_total;
        if opus_share >= 0.7 {
            return Some(format!(
                "Opus is {}% of today. Use Sonnet for routine work to cut it.",
                (opus_share * 100.0).round() as i64
            ));
        }
    }
    if let Some((k, v)) = product_breakdown
        .iter()
        .max_by(|a, b| a.1.partial_cmp(b.1).unwrap_or(std::cmp::Ordering::Equal))
    {
        if *v > 0.0 {
            let share = v / today.max(0.01);
            return Some(format!(
                "{} is {}% of today \u{2014} focus there.",
                product_label(k),
                (share * 100.0).round() as i64
            ));
        }
    }
    None
}

fn money(v: f64) -> String {
    format!("${v:.2}")
}

/// Up to `limit` coaching lines for one expensive session. Prefers transcript signals so tips
/// cite real repo/branch/prompt facts — never pads with the same generic line across sessions.
pub fn coaching_tips(
    session: &SessionCost,
    signals: Option<&TranscriptSignals>,
    limit: usize,
) -> Vec<String> {
    let mut tips: Vec<String> = Vec::new();
    let repo: Option<String> = signals
        .and_then(|s| s.repo.clone())
        .or_else(|| session.title.split('\u{2014}').next().map(|s| s.trim().to_string()).filter(|s| !s.is_empty()));
    let branch = signals.and_then(|s| s.branch.clone());
    let model = session.dominant_model.to_lowercase();

    // 1) Model / cost
    let opus_share = signals.map(|s| s.opus_assistant_share()).unwrap_or(0.0);
    if opus_share >= 0.35 && session.cost >= 5.0 {
        let pct = (opus_share * 100.0).round() as i64;
        let where_ = repo.as_ref().map(|r| format!(" in `{r}`")).unwrap_or_default();
        tips.push(format!(
            "Opus was ~{pct}% of assistant turns{where_} ({}) \u{2014} keep Sonnet for build/log/check loops; escalate to Opus only when root-cause reasoning stalls.",
            money(session.cost)
        ));
    } else if model.contains("opus") && session.cost >= 3.0 {
        let where_ = repo.as_ref().map(|r| format!(" on `{r}`")).unwrap_or_default();
        tips.push(format!(
            "This{where_} chat was mostly Opus at {} \u{2014} rerun routine verify/fix steps on Sonnet (~5\u{d7} cheaper).",
            money(session.cost)
        ));
    }

    // 2) Length / thread hygiene
    if session.messages >= 80 {
        let loc: Vec<String> = [repo.as_ref(), branch.as_ref()]
            .iter()
            .flatten()
            .map(|s| format!("`{s}`"))
            .collect();
        let place = if loc.is_empty() { "this thread".to_string() } else { loc.join(" / ") };
        tips.push(format!(
            "{} billable turns on {place} \u{2014} checkpoint progress and open a new chat for the next milestone so prior history isn't re-sent every turn.",
            session.messages
        ));
    } else if session.messages >= 25 {
        tips.push(format!(
            "{} turns already \u{2014} before the next probe, paste the current hypothesis + exact command to run; don't explore with another vague ask.",
            session.messages
        ));
    }

    // 3) Short / weak prompts
    if let Some(sig) = signals {
        if sig.user_prompt_count >= 5 && sig.short_prompt_share() >= 0.25 {
            let pct = (sig.short_prompt_share() * 100.0).round() as i64;
            let example = sig
                .weak_prompts
                .first()
                .map(|w| format!(" (e.g. \u{201c}{w}\u{201d})"))
                .unwrap_or_default();
            tips.push(format!(
                "{pct}% of your prompts were \u{2264}3 words{example} \u{2014} each still reloads the full thread; batch the next 2\u{2013}3 asks into one message."
            ));
        }

        // 4) Interrupts
        if sig.interrupt_count >= 3 {
            tips.push(format!(
                "You interrupted the agent {}\u{d7} \u{2014} stop/restart loops burn turns; write one message with goal + constraints + how to verify, then let it finish.",
                sig.interrupt_count
            ));
        }

        // 5) Tool-heavy thrash
        if sig.assistant_turns > 0 {
            let tool_share = sig.tool_use_turns as f64 / sig.assistant_turns as f64;
            if tool_share >= 0.45 && session.messages >= 20 {
                tips.push(format!(
                    "Tool-use was ~{}% of assistant turns \u{2014} hand exact paths/commands for the next check so it doesn't keep exploring.",
                    (tool_share * 100.0).round() as i64
                ));
            }
        }
    }

    // 6) Rewrite a real weak opener
    let weak = signals.and_then(|s| {
        s.weak_prompts
            .iter()
            .find(|w| w.split_whitespace().count() <= 4)
            .cloned()
    });
    if let (Some(weak), true) = (weak, tips.len() < limit) {
        let context: Vec<String> = [repo.as_ref(), branch.as_ref()].iter().flatten().map(|s| s.to_string()).collect();
        let prefix = if context.is_empty() {
            "Instead of".to_string()
        } else {
            format!("In {}, instead of", context.join(" \u{b7} "))
        };
        tips.push(format!(
            "{prefix} \u{201c}{weak}\u{201d}, write: goal + files/commands + what \u{201c}done\u{201d} looks like \u{2014} in one message."
        ));
    } else if tips.len() < limit {
        if let Some(sample) = signals.and_then(|s| {
            s.sample_prompts
                .iter()
                .find(|p| {
                    let lower = p.to_lowercase();
                    p.chars().count() < 90 && (lower.starts_with("can you") || lower.contains("fix it"))
                })
                .cloned()
        }) {
            tips.push(format!(
                "Opener \u{201c}{sample}\u{201d} is underspecified \u{2014} name the failing symptom, the file/command, and the success check up front."
            ));
        }
    }

    // 7) Title-aware fallback (still specific, not a generic pad list)
    if tips.len() < limit {
        let title = signals
            .and_then(|s| s.ai_title.clone())
            .or_else(|| session.title.rsplit('\u{2014}').next().map(|s| s.trim().to_string()));
        if let Some(title) = title.filter(|t| t.chars().count() > 8) {
            tips.push(format!(
                "For \u{201c}{}\u{201d}: state the smallest next milestone and a verify command before asking the agent to continue.",
                crate::scanner::truncate_words(&title, 8)
            ));
        }
    }

    if session.cost >= 20.0 && tips.len() < limit {
        tips.push(format!(
            "At {}, split remaining work into scoped sessions (one milestone each) \u{2014} long threads dominate spend more than model choice alone.",
            money(session.cost)
        ));
    }

    // Last resorts — still vary by session numbers so they aren't identical clones.
    let lasts = [
        "Lead with the error signature + one command to reproduce before any \u{201c}fix it\u{201d} follow-up.".to_string(),
        format!(
            "Prefer one packed message (context + ask + verify) over {}+ mini follow-ups.",
            (session.messages / 10).max(2)
        ),
        "If the task changed mid-thread, start fresh \u{2014} mixed goals inflate tokens on every later turn.".to_string(),
    ];
    for t in lasts {
        if tips.len() < limit && !tips.contains(&t) {
            tips.push(t);
        }
    }

    // Dedup while preserving order.
    let mut seen = std::collections::HashSet::new();
    tips.retain(|t| seen.insert(t.clone()));
    tips.truncate(limit);
    tips
}

pub fn product_label(key: &str) -> String {
    match key {
        "claude_code" => "Claude Code".to_string(),
        "claude_chat" => "Claude Chat".to_string(),
        other => other.to_string(),
    }
}
