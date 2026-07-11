//! Cost coaching — a port of the Swift `CoachAdvisor`. Rule-based, no API calls.

use crate::scanner::SessionCost;
use chrono::{Datelike, Local};
use serde::Serialize;
use std::collections::HashMap;

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

/// A short coaching line for one expensive session.
pub fn coaching(session: &SessionCost) -> String {
    let model = session.dominant_model.to_lowercase();
    if model.contains("opus") {
        return "Mostly Opus \u{2014} use Sonnet for edits and Q&A (~5\u{d7} cheaper).".to_string();
    }
    if session.messages >= 40 {
        return format!(
            "Long session ({} turns) \u{2014} batch discovery and state the goal up front.",
            session.messages
        );
    }
    if session.messages >= 15 {
        return "A few back-and-forths \u{2014} front-load the facts to cut follow-ups.".to_string();
    }
    "Say the goal and setup up front.".to_string()
}

pub fn product_label(key: &str) -> String {
    match key {
        "claude_code" => "Claude Code".to_string(),
        "claude_chat" => "Claude Chat".to_string(),
        other => other.to_string(),
    }
}
