//! Jira Cloud integration — pushes a one-line AI-cost summary as an issue comment.
//!
//! This is the app's only outbound network call, and it runs solely when the user
//! clicks "Push to Jira" on a session. Auth is basic email + API token against
//! `https://<site>.atlassian.net/rest/api/3/issue/{key}/comment`.

use serde_json::json;

/// Uppercase Jira issue key ("PROJ-123") found in `text` (e.g. a git branch name).
pub fn detect_issue_key(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i].is_ascii_uppercase() {
            let start = i;
            let mut j = i;
            while j < bytes.len() && (bytes[j].is_ascii_uppercase() || bytes[j].is_ascii_digit()) {
                j += 1;
            }
            if j - start >= 2 && j < bytes.len() && bytes[j] == b'-' {
                let mut k = j + 1;
                while k < bytes.len() && bytes[k].is_ascii_digit() {
                    k += 1;
                }
                let boundary_before = start == 0 || !bytes[start - 1].is_ascii_alphanumeric();
                let boundary_after = k == bytes.len() || !bytes[k].is_ascii_alphanumeric();
                if k > j + 1 && boundary_before && boundary_after {
                    return Some(format!("{}-{}", &text[start..j], &text[j + 1..k]));
                }
            }
            i = j.max(i + 1);
        } else {
            i += 1;
        }
    }
    None
}

/// Comment body in Atlassian Document Format (required by REST API v3).
fn adf_comment(text: &str) -> serde_json::Value {
    json!({
        "body": {
            "type": "doc",
            "version": 1,
            "content": [{
                "type": "paragraph",
                "content": [{ "type": "text", "text": text }]
            }]
        }
    })
}

#[tauri::command]
pub async fn jira_push_cost(
    base_url: String,
    email: String,
    api_token: String,
    issue_key: String,
    summary: String,
) -> Result<String, String> {
    let base = base_url.trim().trim_end_matches('/');
    let issue = issue_key.trim().to_uppercase();
    if base.is_empty() || email.trim().is_empty() || api_token.trim().is_empty() {
        return Err("Fill in the Jira URL, email, and API token in Settings first.".into());
    }
    if detect_issue_key(&issue).as_deref() != Some(issue.as_str()) {
        return Err(format!("\u{201c}{issue}\u{201d} doesn't look like a Jira issue key (e.g. PROJ-123)."));
    }
    let url = format!("{base}/rest/api/3/issue/{issue}/comment");

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .build()
        .map_err(|e| e.to_string())?;
    let resp = client
        .post(&url)
        .basic_auth(email.trim(), Some(api_token.trim()))
        .json(&adf_comment(&summary))
        .send()
        .await
        .map_err(|e| format!("Could not reach Jira: {e}"))?;

    let status = resp.status();
    if status.is_success() {
        Ok(issue)
    } else {
        let hint = match status.as_u16() {
            401 => " — check the email + API token.",
            403 => " — the token lacks permission to comment on this issue.",
            404 => " — issue not found (key or site URL wrong?).",
            _ => "",
        };
        let body = resp.text().await.unwrap_or_default();
        let snippet: String = body.chars().take(200).collect();
        Err(format!("Jira returned {status}{hint} {snippet}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_issue_keys_in_branches() {
        assert_eq!(detect_issue_key("feature/PROJ-123-fix-tray").as_deref(), Some("PROJ-123"));
        assert_eq!(detect_issue_key("AI2-45").as_deref(), Some("AI2-45"));
        assert_eq!(detect_issue_key("main").as_deref(), None);
        assert_eq!(detect_issue_key("windows").as_deref(), None);
        // Lowercase and embedded alphanumerics don't match.
        assert_eq!(detect_issue_key("feature/proj-123").as_deref(), None);
        assert_eq!(detect_issue_key("XPROJ-123abc").as_deref(), None);
    }

    #[test]
    fn adf_body_wraps_text() {
        let v = adf_comment("AI usage: $1.00");
        assert_eq!(v["body"]["content"][0]["content"][0]["text"], "AI usage: $1.00");
    }
}
