//! Local-only smoke test: scans this machine's real session files.
//! Run explicitly with `cargo test --test smoke_scan -- --ignored --nocapture`.

#[test]
#[ignore]
fn scan_real_local_data() {
    let by_day = ai_usage_tracker_lib::scanner::compute_by_day();
    let mut days: Vec<_> = by_day.iter().collect();
    days.sort_by(|a, b| a.0.cmp(b.0));
    for (day, agg) in days.iter().rev().take(7).rev() {
        println!(
            "{day}: claude ${:.2} ({} msgs) cursor ${:.2} codex ${:.2}",
            agg.claude_cost, agg.claude_messages, agg.cursor_cost, agg.codex_cost
        );
    }
    if let Some((day, agg)) = days.last() {
        for s in ai_usage_tracker_lib::scanner::top_sessions(agg, 3) {
            println!("top session {day}: {} | {} | ${:.2} | {} msgs", s.title, s.tool, s.cost, s.messages);
            let signals = ai_usage_tracker_lib::coach::load_signals(&s.id);
            for tip in ai_usage_tracker_lib::coach::coaching_tips(&s, signals.as_ref(), 3) {
                println!("  tip: {tip}");
            }
        }
    }
}
