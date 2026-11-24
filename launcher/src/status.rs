//! Status gathering (HTTK install, scheduled task, saved updater result) and
//! pure parsing logic, mirroring Get-InstalledRelease / Get-LauncherInfo in
//! HttkLauncher.ps1.

use std::path::{Path, PathBuf};

pub const TASK_NAME: &str = "HTTK Daily Updater";
/// Pre-1.2.0 installs used the HtkkUpdater naming; still honored so an
/// upgraded exe keeps working before the installer migrates the task.
pub const LEGACY_TASK_NAME: &str = "HTKK Daily Updater";

/// Result from the Task Scheduler lookup.
#[derive(Clone, Debug, PartialEq)]
pub enum TaskLookup {
    /// Task exists; fields: raw TASK_STATE, first trigger HH:mm, last run, last result.
    Found {
        state: i32,
        start_time: Option<String>,
        last_run: Option<std::time::SystemTime>,
        last_result: Option<i32>,
    },
    NotFound,
    Error(String),
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct SavedResult {
    pub status: String,
    pub stage: Option<String>,
    pub error: Option<String>,
    pub installed_version: Option<String>,
    pub latest_version: Option<String>,
    pub modified: Option<std::time::SystemTime>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct StatusInfo {
    pub installed_version: Option<String>,
    pub version_error: Option<String>,
    pub task: TaskLookup,
    pub result: Option<SavedResult>,
}

impl Default for StatusInfo {
    fn default() -> Self {
        Self {
            installed_version: None,
            version_error: None,
            task: TaskLookup::NotFound,
            result: None,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Pill {
    Unknown,
    Good,
    Updating,
    Ready,
    Error,
}

/// Pill-state logic, ported from the `$refresh` block of HttkLauncher.ps1.
pub fn pill_state(info: &StatusInfo) -> Pill {
    let (running, _disabled) = match &info.task {
        TaskLookup::Found { state, .. } => (*state == 4, *state == 1),
        _ => (false, false),
    };
    let latest_gt = match (
        &info.installed_version,
        info.result.as_ref().and_then(|r| r.latest_version.as_ref()),
    ) {
        (Some(inst), Some(latest)) => version_gt(latest, inst),
        _ => false,
    };
    if info
        .result
        .as_ref()
        .and_then(|r| r.error.as_ref())
        .map(|e| !e.is_empty())
        .unwrap_or(false)
        || info
            .result
            .as_ref()
            .map(|r| r.status == "Error")
            .unwrap_or(false)
    {
        Pill::Error
    } else if running {
        Pill::Updating
    } else if latest_gt {
        Pill::Ready
    } else if info
        .result
        .as_ref()
        .map(|r| r.status == "Current" || r.status == "Updated")
        .unwrap_or(false)
        || info.installed_version.is_some()
    {
        Pill::Good
    } else {
        Pill::Unknown
    }
}

/// Compare dotted versions: returns true if a > b numerically, component-wise.
pub fn version_gt(a: &str, b: &str) -> bool {
    let pa = parse_version(a);
    let pb = parse_version(b);
    match (pa, pb) {
        (Some(va), Some(vb)) => {
            for i in 0..4 {
                let (x, y) = (
                    va.get(i).copied().unwrap_or(0),
                    vb.get(i).copied().unwrap_or(0),
                );
                if x != y {
                    return x > y;
                }
            }
            false
        }
        _ => false,
    }
}

/// a.b.c[.d] — mirrors [version]::TryParse + Build >= 0 in the PS spec.
pub fn parse_version(s: &str) -> Option<Vec<u32>> {
    let parts: Vec<&str> = s.trim().split('.').collect();
    if parts.len() < 2 || parts.len() > 4 {
        return None;
    }
    let mut out = Vec::with_capacity(parts.len());
    for p in &parts {
        if p.is_empty() || !p.chars().all(|c| c.is_ascii_digit()) {
            return None;
        }
        out.push(p.parse::<u32>().ok()?);
    }
    Some(out)
}

/// First of the candidate dirs containing Project\HTKK.exe.config.
pub fn install_dir() -> Option<PathBuf> {
    for d in [
        Path::new(r"C:\Program Files (x86)\HTKK"),
        Path::new(r"C:\Program Files\HTKK"),
    ] {
        if d.join(r"Project\HTKK.exe.config").is_file() {
            return Some(d.to_path_buf());
        }
    }
    None
}

/// The single `/configuration/appSettings/add[@key="VERSION"]` value.
/// Rejects DOCTYPE, 0 or >1 matches, and invalid versions — same rules as
/// Get-InstalledRelease (DtdProcessing.Prohibit, exactly one node, a.b.c[.d]).
pub fn parse_installed_version(xml: &str) -> Result<String, String> {
    if xml.to_ascii_lowercase().contains("<!doctype") {
        return Err("DOCTYPE not allowed".into());
    }
    let doc = roxmltree::Document::parse(xml).map_err(|e| e.to_string())?;
    let root = doc.root_element();
    if !root.has_tag_name("configuration") {
        return Err("missing <configuration> root".into());
    }
    let mut matches = Vec::new();
    for app in root
        .children()
        .filter(|n| n.is_element() && n.has_tag_name("appSettings"))
    {
        for add in app
            .children()
            .filter(|n| n.is_element() && n.has_tag_name("add"))
        {
            if add.attribute("key") == Some("VERSION") {
                if let Some(v) = add.attribute("value") {
                    matches.push(v.to_string());
                }
            }
        }
    }
    if matches.len() != 1 {
        return Err("HTTK release version is missing or ambiguous.".into());
    }
    let v = &matches[0];
    if parse_version(v).is_none() {
        return Err("Invalid HTTK release version.".into());
    }
    Ok(v.clone())
}

/// Parse %ProgramData%\HttkUpdater\last-result.json (written by ConvertTo-Json,
/// may carry a UTF-8 BOM). Malformed or missing-Status => None, never panics.
pub fn parse_last_result(
    text: &str,
    modified: Option<std::time::SystemTime>,
) -> Option<SavedResult> {
    let text = text.trim_start_matches('\u{feff}');
    let v: serde_json::Value = serde_json::from_str(text).ok()?;
    let status = v.get("Status")?.as_str()?.trim().to_string();
    if status.is_empty() {
        return None;
    }
    let get = |k: &str| {
        v.get(k)
            .and_then(|x| x.as_str())
            .filter(|s| !s.is_empty())
            .map(|s| s.to_string())
    };
    Some(SavedResult {
        status,
        stage: get("Stage"),
        error: get("Error"),
        installed_version: get("InstalledVersion"),
        latest_version: get("LatestVersion"),
        modified,
    })
}

/// "YYYY-MM-DDTHH:mm:ss(.fff)(Z|+hh:mm)" -> "HH:mm"
pub fn parse_start_boundary(b: &str) -> Option<String> {
    let t = b.split('T').nth(1)?;
    let mut it = t.split(':');
    let hh: u32 = it.next()?.parse().ok()?;
    let mm: u32 = it
        .next()?
        .trim_end_matches(|c: char| !c.is_ascii_digit())
        .parse()
        .ok()?;
    if hh > 23 || mm > 59 {
        return None;
    }
    Some(format!("{hh:02}:{mm:02}"))
}

/// Validate "H:mm"/"HH:mm" and normalize to "HH:mm". None if invalid.
pub fn normalize_time(t: &str) -> Option<String> {
    let t = t.trim();
    let mut it = t.split(':');
    let hh: u32 = it.next()?.parse().ok()?;
    let mmpart = it.next()?;
    if it.next().is_some() || mmpart.len() != 2 {
        return None;
    }
    let mm: u32 = mmpart.parse().ok()?;
    if hh > 23 || mm > 59 {
        return None;
    }
    Some(format!("{hh:02}:{mm:02}"))
}

pub fn result_path() -> PathBuf {
    PathBuf::from(std::env::var("ProgramData").unwrap_or_else(|_| r"C:\ProgramData".into()))
        .join(r"HttkUpdater\last-result.json")
}

/// Pre-1.2.0 install root — still read when the new dir has no result yet.
fn legacy_result_path() -> PathBuf {
    PathBuf::from(std::env::var("ProgramData").unwrap_or_else(|_| r"C:\ProgramData".into()))
        .join(r"HtkkUpdater\last-result.json")
}

/// Gather all status pieces. `task_info` is injected so tests / non-COM
/// callers can supply their own lookup.
pub fn gather(task: TaskLookup) -> StatusInfo {
    let mut info = StatusInfo {
        task,
        ..Default::default()
    };
    if let Some(dir) = install_dir() {
        let cfg = dir.join(r"Project\HTKK.exe.config");
        match std::fs::read_to_string(&cfg) {
            Ok(xml) => match parse_installed_version(&xml) {
                Ok(v) => info.installed_version = Some(v),
                Err(e) => info.version_error = Some(e),
            },
            Err(e) => info.version_error = Some(e.to_string()),
        }
    } else {
        info.version_error = Some("HTTK configuration not found.".into());
    }
    for rp in [result_path(), legacy_result_path()] {
        if let Ok(meta) = std::fs::metadata(&rp) {
            let mtime = meta.modified().ok();
            if let Ok(text) = std::fs::read_to_string(&rp) {
                info.result = parse_last_result(&text, mtime);
                if info.result.is_some() {
                    break;
                }
            }
        }
    }
    info
}

#[cfg(test)]
mod tests {
    use super::*;

    const CFG: &str = r#"<?xml version="1.0"?>
<configuration>
  <appSettings>
    <add key="VERSION" value="5.8.5"/>
    <add key="OTHER" value="x"/>
  </appSettings>
</configuration>"#;

    #[test]
    fn version_xml_ok() {
        assert_eq!(parse_installed_version(CFG).unwrap(), "5.8.5");
    }

    #[test]
    fn version_xml_four_part() {
        let x = CFG.replace("5.8.5", "5.8.5.1");
        assert_eq!(parse_installed_version(&x).unwrap(), "5.8.5.1");
    }

    #[test]
    fn version_xml_duplicate() {
        let x = CFG.replace(
            r#"<add key="OTHER" value="x"/>"#,
            r#"<add key="VERSION" value="9.9"/>"#,
        );
        assert!(parse_installed_version(&x).is_err());
    }

    #[test]
    fn version_xml_doctype() {
        let x = format!("<!DOCTYPE configuration [ <!ELEMENT configuration ANY> ]>{CFG}");
        assert!(parse_installed_version(&x).is_err());
    }

    #[test]
    fn version_xml_missing_and_invalid() {
        let no_ver = CFG.replace(
            r#"<add key="VERSION" value="5.8.5"/>"#,
            r#"<add key="VER" value="5.8.5"/>"#,
        );
        assert!(parse_installed_version(&no_ver).is_err());
        let bad = CFG.replace("5.8.5", "abc");
        assert!(parse_installed_version(&bad).is_err());
        let one_part = CFG.replace("5.8.5", "5");
        assert!(parse_installed_version(&one_part).is_err());
        let negative = CFG.replace("5.8.5", "5.8.-1");
        assert!(parse_installed_version(&negative).is_err());
    }

    #[test]
    fn last_result_ok() {
        let j = r#"{"Status":"Current","InstalledVersion":"5.8.5","LatestVersion":"5.8.5"}"#;
        let r = parse_last_result(j, None).unwrap();
        assert_eq!(r.status, "Current");
        assert_eq!(r.latest_version.as_deref(), Some("5.8.5"));
    }

    #[test]
    fn last_result_bom() {
        let j = "\u{feff}{\"Status\":  \"Updated\"}";
        assert_eq!(parse_last_result(j, None).unwrap().status, "Updated");
    }

    #[test]
    fn last_result_malformed() {
        assert!(parse_last_result("{not json", None).is_none());
        assert!(parse_last_result("{}", None).is_none());
        assert!(parse_last_result(r#"{"Status":" "}"#, None).is_none());
        assert!(parse_last_result(r#"{"Status":42}"#, None).is_none());
    }

    #[test]
    fn start_boundary() {
        assert_eq!(
            parse_start_boundary("2025-01-15T09:30:00"),
            Some("09:30".into())
        );
        assert_eq!(
            parse_start_boundary("2025-01-15T09:30:00.000+07:00"),
            Some("09:30".into())
        );
        assert_eq!(parse_start_boundary("2025-01-15"), None);
        assert_eq!(parse_start_boundary("xT25:00:00"), None);
    }

    #[test]
    fn time_validation() {
        assert_eq!(normalize_time("9:05"), Some("09:05".into()));
        assert_eq!(normalize_time("23:59"), Some("23:59".into()));
        assert_eq!(normalize_time(" 07:30 "), Some("07:30".into()));
        assert_eq!(normalize_time("24:00"), None);
        assert_eq!(normalize_time("9:60"), None);
        assert_eq!(normalize_time("9:5"), None);
        assert_eq!(normalize_time("ab:cd"), None);
    }

    #[test]
    fn pill_branches() {
        let base = StatusInfo {
            installed_version: Some("5.8.5".into()),
            ..Default::default()
        };
        // error in result -> Error
        let mut i = base.clone();
        i.result = Some(SavedResult {
            status: "Error".into(),
            error: Some("boom".into()),
            ..Default::default()
        });
        assert_eq!(pill_state(&i), Pill::Error);
        // running task -> Updating
        let mut i = base.clone();
        i.task = TaskLookup::Found {
            state: 4,
            start_time: None,
            last_run: None,
            last_result: None,
        };
        assert_eq!(pill_state(&i), Pill::Updating);
        // latest > installed -> Ready
        let mut i = base.clone();
        i.result = Some(SavedResult {
            status: "Updated".into(),
            latest_version: Some("5.9.0".into()),
            ..Default::default()
        });
        assert_eq!(pill_state(&i), Pill::Ready);
        // current/updated -> Good
        let mut i = base.clone();
        i.result = Some(SavedResult {
            status: "Current".into(),
            ..Default::default()
        });
        assert_eq!(pill_state(&i), Pill::Good);
        // installed version alone -> Good
        assert_eq!(pill_state(&base), Pill::Good);
        // nothing -> Unknown
        let i = StatusInfo {
            task: TaskLookup::Error("denied".into()),
            ..Default::default()
        };
        assert_eq!(pill_state(&i), Pill::Unknown);
    }

    #[test]
    fn version_compare() {
        assert!(version_gt("5.9.0", "5.8.5"));
        assert!(version_gt("6.0", "5.9.9.9"));
        assert!(!version_gt("5.8.5", "5.8.5"));
        assert!(!version_gt("5.8.5", "5.9.0"));
        assert!(!version_gt("bad", "5.8.5"));
    }
}
