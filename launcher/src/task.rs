//! Task Scheduler 2.0 COM access: find "HTKK Daily Updater", read its state,
//! first trigger time, last run time/result, and run it on demand.

#![cfg(windows)]

use crate::status::{TaskLookup, TASK_NAME};
use windows::core::BSTR;
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_ALL, COINIT_MULTITHREADED,
};
use windows::Win32::System::TaskScheduler::{
    IRegisteredTask, ITaskFolder, ITaskService, TaskScheduler, TASK_CREATE_OR_UPDATE,
    TASK_LOGON_S4U,
};
use windows::Win32::System::Time::TzSpecificLocalTimeToSystemTime;
use windows::Win32::System::Variant::{VariantTimeToSystemTime, VARIANT, VT_I4};

struct ComGuard {
    initialized: bool,
}
impl ComGuard {
    fn new() -> Result<Self, String> {
        unsafe {
            // S_OK / S_FALSE mean we initialized (and must uninitialize);
            // RPC_E_CHANGED_MODE means another model is active on this thread —
            // usable, but we must NOT call CoUninitialize for it.
            let hr = CoInitializeEx(None, COINIT_MULTITHREADED);
            let initialized = hr.is_ok();
            if hr.is_err() && hr != windows::Win32::Foundation::RPC_E_CHANGED_MODE {
                return Err(format!("CoInitializeEx failed: {hr}"));
            }
            Ok(ComGuard { initialized })
        }
    }
}
impl Drop for ComGuard {
    fn drop(&mut self) {
        if self.initialized {
            unsafe { CoUninitialize() }
        }
    }
}

fn is_not_found(e: &windows::core::Error) -> bool {
    // ERROR_FILE_NOT_FOUND / ERROR_PATH_NOT_FOUND
    const FILE_NOT_FOUND: windows::core::HRESULT = windows::core::HRESULT(0x80070002u32 as i32);
    const PATH_NOT_FOUND: windows::core::HRESULT = windows::core::HRESULT(0x80070003u32 as i32);
    matches!(e.code(), FILE_NOT_FOUND | PATH_NOT_FOUND)
}

fn index_variant(i: i32) -> VARIANT {
    let mut v = VARIANT::default();
    unsafe {
        (*v.Anonymous.Anonymous).vt = VT_I4;
        (*v.Anonymous.Anonymous).Anonymous.lVal = i;
    }
    v
}

fn find_task(folder: &ITaskFolder) -> Result<Option<IRegisteredTask>, String> {
    unsafe {
        match folder.GetTask(&BSTR::from(TASK_NAME)) {
            Ok(t) => return Ok(Some(t)),
            Err(e) if !is_not_found(&e) => return Err(format!("{e}")),
            _ => {}
        }
        // Fall back to enumerating subfolders of the given folder.
        let mut first_err: Option<String> = None;
        if let Ok(folders) = folder.GetFolders(0) {
            if let Ok(count) = folders.Count() {
                for i in 1..=count {
                    if let Ok(sub) = folders.get_Item(&index_variant(i)) {
                        match sub.GetTask(&BSTR::from(TASK_NAME)) {
                            Ok(t) => return Ok(Some(t)),
                            Err(e) if is_not_found(&e) => {}
                            Err(e) => {
                                if first_err.is_none() {
                                    first_err = Some(format!("{e}"));
                                }
                            }
                        }
                    }
                }
            }
        }
        if let Some(e) = first_err {
            return Err(e);
        }
        Ok(None)
    }
}

fn date_to_system_time(date: f64) -> Option<std::time::SystemTime> {
    if date == 0.0 {
        return None; // OLE zero date (1899-12-30) = "never ran"
    }
    unsafe {
        // Task Scheduler stores LastRunTime as a variant date in LOCAL time;
        // convert local -> UTC before turning it into an absolute SystemTime.
        let mut local = windows::Win32::Foundation::SYSTEMTIME::default();
        if VariantTimeToSystemTime(date, &mut local) == 0 {
            return None;
        }
        let mut utc = windows::Win32::Foundation::SYSTEMTIME::default();
        if TzSpecificLocalTimeToSystemTime(None, &local, &mut utc).is_err() {
            return None;
        }
        let days = ymd_to_days(utc.wYear as i64, utc.wMonth as i64, utc.wDay as i64);
        let secs =
            days * 86_400 + utc.wHour as i64 * 3600 + utc.wMinute as i64 * 60 + utc.wSecond as i64;
        // 2000-01-01 threshold: "never ran" is reported as the 1999-11-30
        // sentinel (not OLE zero) on recent Windows builds.
        const NEVER_RAN_BEFORE: i64 = 946_684_800;
        if secs < NEVER_RAN_BEFORE {
            return None;
        }
        Some(std::time::UNIX_EPOCH + std::time::Duration::from_secs(secs as u64))
    }
}

fn ymd_to_days(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = if m > 2 { m - 3 } else { m + 9 };
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// Connect to the service and look up the task. NotFound and access errors
/// are distinguished per the spec.
pub fn query() -> TaskLookup {
    unsafe {
        let _com = match ComGuard::new() {
            Ok(g) => g,
            Err(e) => return TaskLookup::Error(e),
        };
        let svc: ITaskService = match CoCreateInstance(&TaskScheduler, None, CLSCTX_ALL) {
            Ok(s) => s,
            Err(e) => return TaskLookup::Error(format!("{e}")),
        };
        let empty = VARIANT::default();
        if let Err(e) = svc.Connect(&empty, &empty, &empty, &empty) {
            return TaskLookup::Error(format!("{e}"));
        }
        let root = match svc.GetFolder(&BSTR::from("\\")) {
            Ok(f) => f,
            Err(e) => return TaskLookup::Error(format!("{e}")),
        };
        let task = match find_task(&root) {
            Ok(Some(t)) => t,
            Ok(None) => return TaskLookup::NotFound,
            Err(e) => return TaskLookup::Error(e),
        };
        let state = task.State().map(|s| s.0).unwrap_or(0);
        let mut start_time = None;
        if let Ok(def) = task.Definition() {
            if let Ok(trigs) = def.Triggers() {
                let mut count = 0i32;
                if trigs.Count(&mut count).is_ok() && count > 0 {
                    if let Ok(trig) = trigs.get_Item(1) {
                        let mut sb = BSTR::default();
                        if trig.StartBoundary(&mut sb).is_ok() {
                            start_time = crate::status::parse_start_boundary(&sb.to_string());
                        }
                    }
                }
            }
        }
        let last_run = task.LastRunTime().ok().and_then(date_to_system_time);
        let last_result = task.LastTaskResult().ok();
        TaskLookup::Found {
            state,
            start_time,
            last_run,
            last_result,
        }
    }
}

/// Trigger an on-demand run. Returns Err with a key-style reason for
/// Disabled / already Running so the caller can localize.
pub fn run_now() -> Result<(), RunError> {
    unsafe {
        let _com = ComGuard::new().map_err(RunError::Other)?;
        let svc: ITaskService = CoCreateInstance(&TaskScheduler, None, CLSCTX_ALL)
            .map_err(|e| RunError::Other(e.to_string()))?;
        let empty = VARIANT::default();
        svc.Connect(&empty, &empty, &empty, &empty)
            .map_err(|e| RunError::Other(e.to_string()))?;
        let root = svc
            .GetFolder(&BSTR::from("\\"))
            .map_err(|e| RunError::Other(e.to_string()))?;
        let task = match find_task(&root).map_err(RunError::Other)? {
            Some(t) => t,
            None => return Err(RunError::NotFound),
        };
        let state = task.State().map(|s| s.0).unwrap_or(0);
        if state == 1 {
            return Err(RunError::Disabled);
        }
        if state == 4 {
            return Err(RunError::Running);
        }
        task.Run(&VARIANT::default())
            .map_err(|e| RunError::Other(e.to_string()))?;
        Ok(())
    }
}

/// Change the daily trigger's start time ("HH:mm") through the Task Scheduler
/// COM API. `schtasks.exe /change` cannot be used here: for S4U-logon tasks it
/// demands the account password and blocks forever waiting on a console that
/// ShellExecute never provides.
pub fn set_trigger_time(hhmm: &str) -> Result<(), String> {
    let b = hhmm.as_bytes();
    let valid = b.len() == 5
        && b[2] == b':'
        && b[..2].iter().all(|c| c.is_ascii_digit())
        && b[3..].iter().all(|c| c.is_ascii_digit())
        && hhmm[..2].parse::<u32>().is_ok_and(|h| h <= 23)
        && hhmm[3..].parse::<u32>().is_ok_and(|m| m <= 59);
    if !valid {
        return Err(format!("bad time {hhmm}"));
    }
    unsafe {
        let _com = ComGuard::new()?;
        let svc: ITaskService =
            CoCreateInstance(&TaskScheduler, None, CLSCTX_ALL).map_err(|e| e.to_string())?;
        let empty = VARIANT::default();
        svc.Connect(&empty, &empty, &empty, &empty)
            .map_err(|e| e.to_string())?;
        let root = svc
            .GetFolder(&BSTR::from("\\"))
            .map_err(|e| e.to_string())?;
        let task = find_task(&root)?.ok_or_else(|| "task not found".to_string())?;
        let def = task.Definition().map_err(|e| e.to_string())?;
        let trigs = def.Triggers().map_err(|e| e.to_string())?;
        let mut count = 0i32;
        trigs.Count(&mut count).map_err(|e| e.to_string())?;
        if count < 1 {
            return Err("task has no trigger".into());
        }
        let trig = trigs.get_Item(1).map_err(|e| e.to_string())?;
        // Keep the existing boundary's date + UTC offset; replace only HH:mm.
        // StartBoundary looks like "2026-11-22T09:00:00+07:00" — the time
        // fields sit at fixed offsets, so splice the new HH:mm in place.
        let mut cur = BSTR::default();
        trig.StartBoundary(&mut cur).map_err(|e| e.to_string())?;
        let cur_s = cur.to_string();
        let boundary = if cur_s.len() >= 19 && cur_s.as_bytes().get(10) == Some(&b'T') {
            format!("{}{}:00{}", &cur_s[..11], hhmm, &cur_s[19..])
        } else {
            return Err(format!("unexpected StartBoundary '{cur_s}'"));
        };
        trig.SetStartBoundary(&BSTR::from(boundary))
            .map_err(|e| e.to_string())?;
        root.RegisterTaskDefinition(
            &BSTR::from(TASK_NAME),
            &def,
            TASK_CREATE_OR_UPDATE.0,
            &VARIANT::default(),
            &VARIANT::default(),
            TASK_LOGON_S4U,
            &VARIANT::default(),
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }
}

pub enum RunError {
    NotFound,
    Disabled,
    Running,
    Other(String),
}
