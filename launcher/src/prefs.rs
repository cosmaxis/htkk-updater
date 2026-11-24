//! %LOCALAPPDATA%\HttkUpdater\prefs.json — {"lang":"en"|"vi"}, same format as
//! the PowerShell launcher writes.

use crate::i18n::Lang;
use std::path::PathBuf;

pub fn pref_path() -> PathBuf {
    PathBuf::from(std::env::var("LOCALAPPDATA").unwrap_or_else(|_| r"C:\Users\Public".into()))
        .join(r"HttkUpdater\prefs.json")
}

/// Pre-1.2.0 prefs location — read as a fallback so the language choice
/// survives the HtkkUpdater -> HttkUpdater rename.
fn legacy_pref_path() -> PathBuf {
    PathBuf::from(std::env::var("LOCALAPPDATA").unwrap_or_else(|_| r"C:\Users\Public".into()))
        .join(r"HtkkUpdater\prefs.json")
}

pub fn load() -> Option<Lang> {
    for path in [pref_path(), legacy_pref_path()] {
        if let Ok(text) = std::fs::read_to_string(path) {
            let v: serde_json::Value =
                serde_json::from_str(text.trim_start_matches('\u{feff}')).ok()?;
            if let Some(lang) = Lang::parse(v.get("lang")?.as_str()?) {
                return Some(lang);
            }
        }
    }
    None
}

pub fn save(lang: Lang) {
    let path = pref_path();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let body = serde_json::json!({ "lang": lang.code() }).to_string();
    let _ = std::fs::write(path, body);
}
