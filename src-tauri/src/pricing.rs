//! Token pricing — a faithful port of the Swift `TokenPricing` / `ModelRates` / `TokenUsage`.
//!
//! Anthropic API list rates (USD per 1M tokens). Turns local session token counts into dollar
//! estimates. Unknown / unmapped models fall back to Haiku (cheapest).

/// Round a dollar figure to whole cents, matching the Swift `(x * 100).rounded() / 100`.
pub fn round_cents(x: f64) -> f64 {
    (x * 100.0).round() / 100.0
}

#[derive(Debug, Clone, Copy, Default, PartialEq, serde::Serialize)]
pub struct TokenUsage {
    pub input: i64,
    pub output: i64,
    pub cache_read: i64,
    pub cache_write_5m: i64,
    pub cache_write_1h: i64,
}

impl std::ops::Add for TokenUsage {
    type Output = TokenUsage;
    fn add(self, rhs: TokenUsage) -> TokenUsage {
        TokenUsage {
            input: self.input + rhs.input,
            output: self.output + rhs.output,
            cache_read: self.cache_read + rhs.cache_read,
            cache_write_5m: self.cache_write_5m + rhs.cache_write_5m,
            cache_write_1h: self.cache_write_1h + rhs.cache_write_1h,
        }
    }
}

impl std::ops::AddAssign for TokenUsage {
    fn add_assign(&mut self, rhs: TokenUsage) {
        *self = *self + rhs;
    }
}

impl TokenUsage {
    pub fn total(&self) -> i64 {
        self.input + self.output + self.cache_read + self.cache_write_5m + self.cache_write_1h
    }
}

#[derive(Debug, Clone, Copy)]
struct ModelRates {
    input_per_m: f64,
    output_per_m: f64,
    cache_read_per_m: f64,
    cache_write_5m_per_m: f64,
    cache_write_1h_per_m: f64,
}

impl ModelRates {
    fn cost(&self, u: &TokenUsage) -> f64 {
        let m = 1_000_000.0;
        let raw = u.input as f64 * self.input_per_m / m
            + u.output as f64 * self.output_per_m / m
            + u.cache_read as f64 * self.cache_read_per_m / m
            + u.cache_write_5m as f64 * self.cache_write_5m_per_m / m
            + u.cache_write_1h as f64 * self.cache_write_1h_per_m / m;
        round_cents(raw)
    }
}

/// Cursor aliases like "default" / "composer-*" map here (user preference: Sonnet).
pub const CURSOR_DEFAULT_MODEL: &str = "claude-sonnet-4-6";
const CHEAPEST_MODEL: &str = "claude-haiku-4-5";

fn rates_for_key(key: &str) -> Option<ModelRates> {
    // (input, output, cache_read, cache_write_5m, cache_write_1h) per 1M tokens.
    let r = |i, o, cr, c5, c1| ModelRates {
        input_per_m: i,
        output_per_m: o,
        cache_read_per_m: cr,
        cache_write_5m_per_m: c5,
        cache_write_1h_per_m: c1,
    };
    Some(match key {
        "claude-haiku-4-5" | "claude-haiku-4-5-20251001" => r(1.0, 5.0, 0.10, 1.25, 2.0),
        "claude-sonnet-4-6" | "claude-sonnet-4" => r(3.0, 15.0, 0.30, 3.75, 6.0),
        // Opus 4.8 list price: $5 / $25 per 1M (cache read 0.1x, write-5m 1.25x, write-1h 2x).
        "claude-opus-4-8" | "claude-opus-4" => r(5.0, 25.0, 0.50, 6.25, 10.0),
        "composer-2.5" => r(1.0, 5.0, 0.10, 1.25, 2.0),
        _ => return None,
    })
}

/// Map a raw model id from either tool onto one of our known rate keys.
pub fn normalize(raw: &str) -> String {
    let m = raw.trim().to_lowercase();
    if m.is_empty() || m == "default" || m == "<synthetic>" {
        return CURSOR_DEFAULT_MODEL.to_string();
    }
    if m.starts_with("composer") {
        return CURSOR_DEFAULT_MODEL.to_string();
    }
    if m.contains("haiku") {
        return "claude-haiku-4-5".to_string();
    }
    if m.contains("sonnet") {
        return "claude-sonnet-4-6".to_string();
    }
    if m.contains("opus") {
        return "claude-opus-4-8".to_string();
    }
    m
}

/// Cost for a normalized-or-raw model id + usage. Unknown models price at the cheapest tier.
pub fn cost(model: &str, usage: &TokenUsage) -> f64 {
    let key = normalize(model);
    let rates = rates_for_key(&key).unwrap_or_else(|| rates_for_key(CHEAPEST_MODEL).unwrap());
    rates.cost(usage)
}

/// API-equivalent OpenAI estimate for Codex logs. Codex subscription usage is not billed
/// per token; these rates let the local tracker compare tools on a consistent basis.
pub fn codex_cost(model: &str, usage: &TokenUsage) -> f64 {
    let m = model.to_lowercase();
    // Conservative fallback for new/private Codex model slugs. Rates are USD per 1M tokens.
    let (input, cached, output) = if m.contains("mini") {
        (0.25, 0.025, 2.0)
    } else {
        (1.25, 0.125, 10.0)
    };
    let uncached_input = (usage.input - usage.cache_read).max(0) as f64;
    round_cents(
        uncached_input * input / 1_000_000.0
            + usage.cache_read as f64 * cached / 1_000_000.0
            + usage.output as f64 * output / 1_000_000.0,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_aliases() {
        assert_eq!(normalize(""), "claude-sonnet-4-6");
        assert_eq!(normalize("default"), "claude-sonnet-4-6");
        assert_eq!(normalize("composer-2.5"), "claude-sonnet-4-6");
        assert_eq!(normalize("claude-3-5-haiku"), "claude-haiku-4-5");
        assert_eq!(normalize("Claude Opus 4.8"), "claude-opus-4-8");
    }

    #[test]
    fn opus_cost() {
        let u = TokenUsage { input: 1_000_000, output: 1_000_000, ..Default::default() };
        // 1M input @ $5 + 1M output @ $25 = $30.00
        assert_eq!(cost("claude-opus-4-8", &u), 30.0);
    }

    #[test]
    fn unknown_falls_back_to_haiku() {
        let u = TokenUsage { input: 1_000_000, ..Default::default() };
        assert_eq!(cost("some-unknown-model", &u), 1.0);
    }


    #[test]
    fn codex_cached_input_is_discounted() {
        let u = TokenUsage { input: 1_000_000, cache_read: 800_000, output: 100_000, ..Default::default() };
        assert_eq!(codex_cost("gpt-5", &u), 1.35);
    }
}
