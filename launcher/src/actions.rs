//! User actions: launch HTKK, change the schedule via elevated schtasks.exe.

#![cfg(windows)]

use crate::status::{install_dir, TASK_NAME};
use windows::core::{w, HRESULT, PCWSTR};
use windows::Win32::Foundation::{CloseHandle, GetLastError, HWND, WAIT_FAILED, WAIT_OBJECT_0};
use windows::Win32::System::Threading::{GetExitCodeProcess, WaitForSingleObject, INFINITE};
use windows::Win32::UI::Shell::{ShellExecuteExW, SEE_MASK_NOCLOSEPROCESS, SHELLEXECUTEINFOW};
use windows::Win32::UI::WindowsAndMessaging::SW_NORMAL;

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

pub enum OpenError {
    NotInstalled,
    ExeMissing,
    Launch(String),
}

/// Launch Project\HTKK.exe with its directory as the working directory.
pub fn open_htkk() -> Result<(), OpenError> {
    let dir = install_dir().ok_or(OpenError::NotInstalled)?;
    let exe = dir.join(r"Project\HTKK.exe");
    if !exe.is_file() {
        return Err(OpenError::ExeMissing);
    }
    let exe_w = wide(&exe.to_string_lossy());
    let dir_w = wide(&dir.to_string_lossy());
    let mut info = SHELLEXECUTEINFOW {
        cbSize: std::mem::size_of::<SHELLEXECUTEINFOW>() as u32,
        fMask: SEE_MASK_NOCLOSEPROCESS,
        hwnd: HWND::default(),
        lpVerb: w!("open"),
        lpFile: PCWSTR(exe_w.as_ptr()),
        lpParameters: PCWSTR::null(),
        lpDirectory: PCWSTR(dir_w.as_ptr()),
        nShow: SW_NORMAL.0,
        ..Default::default()
    };
    unsafe {
        ShellExecuteExW(&mut info).map_err(|e| OpenError::Launch(e.to_string()))?;
        if !info.hProcess.is_invalid() {
            let _ = CloseHandle(info.hProcess);
        }
    }
    Ok(())
}

pub enum ScheduleResult {
    Applied(String),
    Cancelled,
    Failed(String),
}

/// schtasks /change /tn "HTKK Daily Updater" /st HH:mm via UAC ("runas"),
/// SEE_MASK_NOCLOSEPROCESS so we can wait on the exit code. The caller must
/// run this on a worker thread — it blocks in WaitForSingleObject.
pub fn set_task_time(time: &str) -> ScheduleResult {
    let args = format!("/change /tn \"{TASK_NAME}\" /st {time}");
    let args_w = wide(&args);
    let file_w = wide("schtasks.exe");
    let verb_w = wide("runas");
    let mut info = SHELLEXECUTEINFOW {
        cbSize: std::mem::size_of::<SHELLEXECUTEINFOW>() as u32,
        fMask: SEE_MASK_NOCLOSEPROCESS,
        hwnd: HWND::default(),
        lpVerb: PCWSTR(verb_w.as_ptr()),
        lpFile: PCWSTR(file_w.as_ptr()),
        lpParameters: PCWSTR(args_w.as_ptr()),
        lpDirectory: PCWSTR::null(),
        nShow: SW_NORMAL.0,
        ..Default::default()
    };
    unsafe {
        if let Err(e) = ShellExecuteExW(&mut info) {
            // ERROR_CANCELLED (1223): user declined the UAC prompt
            const ERROR_CANCELLED: u32 = 1223;
            if e.code() == HRESULT::from_win32(ERROR_CANCELLED)
                || GetLastError().0 == ERROR_CANCELLED
            {
                return ScheduleResult::Cancelled;
            }
            return ScheduleResult::Failed(e.to_string());
        }
        let h = info.hProcess;
        if h.is_invalid() {
            return ScheduleResult::Failed("no process handle".into());
        }
        let wait = WaitForSingleObject(h, INFINITE);
        let mut code: u32 = 1;
        let got = GetExitCodeProcess(h, &mut code);
        let _ = CloseHandle(h);
        if wait == WAIT_FAILED || wait != WAIT_OBJECT_0 || got.is_err() {
            return ScheduleResult::Failed("could not wait for schtasks".into());
        }
        if code == 0 {
            ScheduleResult::Applied(time.to_string())
        } else {
            ScheduleResult::Failed(format!("schtasks exit {code}"))
        }
    }
}
