//! EN/VI string tables, ported from the `$L` table in HtkkLauncher.ps1 plus
//! new keys for the native launcher (task-state names, result-status names,
//! relative times, cancelled-UAC message).

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Lang {
    En,
    Vi,
}

impl Lang {
    pub fn parse(s: &str) -> Option<Lang> {
        match s {
            "en" => Some(Lang::En),
            "vi" => Some(Lang::Vi),
            _ => None,
        }
    }
    pub fn code(self) -> &'static str {
        match self {
            Lang::En => "en",
            Lang::Vi => "vi",
        }
    }
}

const EN: &[(&str, &str)] = &[
    ("subtitle", "Automatic updates - every day at {0}"),
    ("installed", "INSTALLED VERSION"),
    ("latest", "Latest release: v{0}"),
    ("task", "SCHEDULED TASK"),
    ("lastRun", "LAST UPDATE CHECK"),
    ("updResult", "UPDATER RESULT"),
    ("settings", "SETTINGS"),
    ("timeLabel", "Daily update time"),
    ("apply", "Apply"),
    ("open", "Open HTKK"),
    ("check", "Check for updates"),
    ("taskMissing", "Not installed - run Install-HtkkUpdater.ps1"),
    ("taskFmt", "{0} - daily at {1}"),
    ("unavailable", "Unavailable: {0}"),
    ("never", "Never"),
    ("noRuns", "No runs recorded yet"),
    ("notFound", "Not found"),
    ("saved", "Saved - daily at {0}"),
    ("saving", "Saving..."),
    ("invalidTime", "Enter a valid time (HH:mm)"),
    ("changeFail", "Could not change schedule: {0}"),
    ("pillChecking", "Checking"),
    ("pillUpdating", "Updating"),
    ("pillReady", "Update ready"),
    ("pillGood", "Up to date"),
    ("pillError", "Error"),
    ("pillUnknown", "Unknown"),
    ("pillRunning", "Running"),
    ("disabled", "The scheduled updater is disabled."),
    ("alreadyRun", "The updater is already running."),
    ("taskErr", "Expected exactly one scheduled updater task."),
    ("exeMissing", "HTKK executable not found."),
    // new keys
    ("title", "HTKK Updater"),
    ("footer", "github.com/cosmaxis/htkk-updater"),
    ("cancelled", "Cancelled."),
    ("launchFail", "Could not open HTKK: {0}"),
    ("runFail", "Could not start the updater: {0}"),
    ("langSwitch", "Switch language"),
    ("minimize", "Minimize"),
    ("close", "Close"),
    ("pickTime", "Pick a daily time"),
    ("stUnknown", "Unknown"),
    ("stDisabled", "Disabled"),
    ("stQueued", "Queued"),
    ("stReady", "Ready"),
    ("stRunning", "Running"),
    ("stNotFound", "Not found"),
    ("resUpdated", "Updated"),
    ("resCurrent", "Current"),
    ("resReboot", "Reboot required"),
    ("resError", "Error"),
    ("relNow", "just now"),
    ("relMin", "{0} min ago"),
    ("relHour", "1 hour ago"),
    ("relHours", "{0} hours ago"),
    ("relDay", "1 day ago"),
    ("relDays", "{0} days ago"),
];

const VI: &[(&str, &str)] = &[
    ("subtitle", "Tự động cập nhật - mỗi ngày lúc {0}"),
    ("installed", "PHIÊN BẢN ĐÃ CÀI"),
    ("latest", "Bản mới nhất: v{0}"),
    ("task", "TÁC VỤ ĐỊNH KỲ"),
    ("lastRun", "KIỂM TRA LẦN CUỐI"),
    ("updResult", "KẾT QUẢ CẬP NHẬT"),
    ("settings", "CÀI ĐẶT"),
    ("timeLabel", "Giờ cập nhật mỗi ngày"),
    ("apply", "Áp dụng"),
    ("open", "Mở HTKK"),
    ("check", "Kiểm tra cập nhật"),
    (
        "taskMissing",
        "Chưa cài đặt - hãy chạy Install-HtkkUpdater.ps1",
    ),
    ("taskFmt", "{0} - mỗi ngày lúc {1}"),
    ("unavailable", "Không khả dụng: {0}"),
    ("never", "Chưa từng"),
    ("noRuns", "Chưa có lượt chạy nào"),
    ("notFound", "Không tìm thấy"),
    ("saved", "Đã lưu - mỗi ngày lúc {0}"),
    ("saving", "Đang lưu..."),
    ("invalidTime", "Nhập giờ hợp lệ (HH:mm)"),
    ("changeFail", "Không đổi được lịch: {0}"),
    ("pillChecking", "Đang kiểm tra"),
    ("pillUpdating", "Đang cập nhật"),
    ("pillReady", "Có bản mới"),
    ("pillGood", "Mới nhất"),
    ("pillError", "Lỗi"),
    ("pillUnknown", "Không rõ"),
    ("pillRunning", "Đang chạy"),
    ("disabled", "Tác vụ cập nhật đang tắt."),
    ("alreadyRun", "Trình cập nhật đang chạy."),
    ("taskErr", "Cần đúng một tác vụ cập nhật định kỳ."),
    ("exeMissing", "Không tìm thấy HTKK.exe."),
    ("title", "Trình cập nhật HTKK"),
    ("footer", "github.com/cosmaxis/htkk-updater"),
    ("cancelled", "Đã hủy."),
    ("launchFail", "Không mở được HTKK: {0}"),
    ("runFail", "Không chạy được trình cập nhật: {0}"),
    ("langSwitch", "Đổi ngôn ngữ"),
    ("minimize", "Thu nhỏ"),
    ("close", "Đóng"),
    ("pickTime", "Chọn giờ mỗi ngày"),
    ("stUnknown", "Không rõ"),
    ("stDisabled", "Đã tắt"),
    ("stQueued", "Đang chờ"),
    ("stReady", "Sẵn sàng"),
    ("stRunning", "Đang chạy"),
    ("stNotFound", "Không tìm thấy"),
    ("resUpdated", "Đã cập nhật"),
    ("resCurrent", "Mới nhất"),
    ("resReboot", "Cần khởi động lại"),
    ("resError", "Lỗi"),
    ("relNow", "vừa xong"),
    ("relMin", "{0} phút trước"),
    ("relHour", "1 giờ trước"),
    ("relHours", "{0} giờ trước"),
    ("relDay", "1 ngày trước"),
    ("relDays", "{0} ngày trước"),
];

fn table(lang: Lang) -> &'static [(&'static str, &'static str)] {
    match lang {
        Lang::En => EN,
        Lang::Vi => VI,
    }
}

/// Look up a key; falls back to EN, then to the key itself so a missing
/// translation is visible instead of panicking.
pub fn tr(lang: Lang, key: &str) -> &str {
    table(lang)
        .iter()
        .chain(EN.iter())
        .find(|(k, _)| *k == key)
        .map(|(_, v)| *v)
        .unwrap_or(key)
}

pub fn fmt(lang: Lang, key: &str, args: &[&str]) -> String {
    let mut s = tr(lang, key).to_string();
    for (i, a) in args.iter().enumerate() {
        s = s.replace(&format!("{{{i}}}"), a);
    }
    s
}

const MONTHS_EN: &[&str] = &[
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

/// Civil date fields for a system time, in local time.
/// Returns (year, month 1-12, day, hour, minute, unix_secs).
fn local_parts(t: std::time::SystemTime) -> Option<(i64, u32, u32, u32, u32, u64)> {
    let secs = t.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs();
    #[cfg(windows)]
    {
        use windows::Win32::Foundation::SYSTEMTIME;
        use windows::Win32::System::Time::{FileTimeToSystemTime, SystemTimeToTzSpecificLocalTime};
        let ft = ((secs as i64 + 11_644_473_600) * 10_000_000) as u64;
        let ft = windows::Win32::Foundation::FILETIME {
            dwLowDateTime: (ft & 0xFFFF_FFFF) as u32,
            dwHighDateTime: (ft >> 32) as u32,
        };
        unsafe {
            let mut utc = SYSTEMTIME::default();
            let mut local = SYSTEMTIME::default();
            FileTimeToSystemTime(&ft, &mut utc).ok()?;
            SystemTimeToTzSpecificLocalTime(None, &utc, &mut local).ok()?;
            Some((
                local.wYear as i64,
                local.wMonth as u32,
                local.wDay as u32,
                local.wHour as u32,
                local.wMinute as u32,
                secs,
            ))
        }
    }
    #[cfg(not(windows))]
    {
        // test / non-windows fallback: treat as UTC
        let days = (secs / 86_400) as i64;
        let sod = secs % 86_400;
        let (y, m, d) = days_to_ymd(days);
        Some((
            y,
            m,
            d,
            (sod / 3600) as u32,
            ((sod % 3600) / 60) as u32,
            secs,
        ))
    }
}

#[allow(dead_code)]
fn days_to_ymd(days: i64) -> (i64, u32, u32) {
    // Howard Hinnant's civil-from-days
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m as u32, d as u32)
}

/// "Nov 21, 2026 14:20" (EN) / "21/11/2026 14:20" (VI)
pub fn format_date(lang: Lang, t: std::time::SystemTime) -> String {
    match local_parts(t) {
        Some((y, m, d, hh, mm, _)) => match lang {
            Lang::En => format!(
                "{} {}, {} {:02}:{:02}",
                MONTHS_EN[(m - 1) as usize],
                d,
                y,
                hh,
                mm
            ),
            Lang::Vi => format!("{:02}/{:02}/{} {:02}:{:02}", d, m, y, hh, mm),
        },
        None => String::new(),
    }
}

/// "2 hours ago" / "2 giờ trước"
pub fn relative_hint(lang: Lang, t: std::time::SystemTime) -> String {
    let elapsed = match std::time::SystemTime::now().duration_since(t) {
        Ok(d) => d.as_secs(),
        Err(_) => return String::new(),
    };
    if elapsed < 60 {
        tr(lang, "relNow").to_string()
    } else if elapsed < 3600 {
        fmt(lang, "relMin", &[&(elapsed / 60).to_string()])
    } else if elapsed < 7200 {
        tr(lang, "relHour").to_string()
    } else if elapsed < 86_400 {
        fmt(lang, "relHours", &[&(elapsed / 3600).to_string()])
    } else if elapsed < 172_800 {
        tr(lang, "relDay").to_string()
    } else {
        fmt(lang, "relDays", &[&(elapsed / 86_400).to_string()])
    }
}

/// Localized scheduled-task state name (Task Scheduler TASK_STATE values).
pub fn task_state_name(lang: Lang, state: i32) -> &'static str {
    match state {
        0 => tr(lang, "stUnknown"),
        1 => tr(lang, "stDisabled"),
        2 => tr(lang, "stQueued"),
        3 => tr(lang, "stReady"),
        4 => tr(lang, "stRunning"),
        _ => tr(lang, "stUnknown"),
    }
}

/// Localized last-result.json Status value.
pub fn result_status_name(lang: Lang, status: &str) -> String {
    let key = match status {
        "Updated" => "resUpdated",
        "Current" => "resCurrent",
        "RebootRequired" => "resReboot",
        "Error" => "resError",
        _ => return status.to_string(),
    };
    tr(lang, key).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn key_parity() {
        let en: std::collections::BTreeSet<_> = EN.iter().map(|(k, _)| *k).collect();
        let vi: std::collections::BTreeSet<_> = VI.iter().map(|(k, _)| *k).collect();
        assert_eq!(en, vi, "EN keys missing from VI or vice versa");
        assert_eq!(en.len(), EN.len(), "duplicate EN keys");
        assert_eq!(vi.len(), VI.len(), "duplicate VI keys");
    }

    #[test]
    fn date_formats() {
        // 2026-11-21 14:20 UTC
        let t = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_795_312_800);
        let en = format_date(Lang::En, t);
        let vi = format_date(Lang::Vi, t);
        // Local timezone may shift the exact numbers; check shapes.
        assert!(en.contains(','), "en format: {en}");
        assert!(vi.contains('/'), "vi format: {vi}");
        assert!(en.contains("14:") || en.contains(':'), "{en}");
    }

    #[test]
    fn relative_hints() {
        let now = std::time::SystemTime::now();
        assert_eq!(relative_hint(Lang::En, now), "just now");
        let t = now - std::time::Duration::from_secs(7_300);
        assert_eq!(relative_hint(Lang::En, t), "2 hours ago");
        assert_eq!(relative_hint(Lang::Vi, t), "2 giờ trước");
    }
}
