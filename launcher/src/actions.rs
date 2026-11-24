//! User actions: launch HTTK, run the scheduled task via elevated schtasks.exe.

#![cfg(windows)]

use crate::status::{install_dir, LEGACY_TASK_NAME, TASK_NAME};
use windows::core::{w, HRESULT, PCWSTR};
use windows::Win32::Foundation::{
    CloseHandle, GetLastError, HWND, WAIT_FAILED, WAIT_OBJECT_0, WAIT_TIMEOUT,
};
use windows::Win32::System::Threading::{
    GetExitCodeProcess, TerminateProcess, WaitForSingleObject,
};
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
pub fn open_httk() -> Result<(), OpenError> {
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
    Applied,
    Cancelled,
    Failed(String),
}

/// ShellExecute "runas" a process and wait for its exit code.
/// ERROR_CANCELLED (1223) maps to ScheduleResult::Cancelled.
fn run_elevated_wait(file: &str, args: &str, timeout_ms: u32) -> ScheduleResult {
    let file_w = wide(file);
    let args_w = wide(args);
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
        let wait = WaitForSingleObject(h, timeout_ms);
        if wait == WAIT_TIMEOUT {
            let _ = TerminateProcess(h, 1);
            let _ = CloseHandle(h);
            return ScheduleResult::Failed("timed out".into());
        }
        let mut code: u32 = 1;
        let got = GetExitCodeProcess(h, &mut code);
        let _ = CloseHandle(h);
        if wait == WAIT_FAILED || wait != WAIT_OBJECT_0 || got.is_err() {
            return ScheduleResult::Failed("could not wait for process".into());
        }
        if code == 0 {
            ScheduleResult::Applied
        } else {
            ScheduleResult::Failed(format!("exit {code}"))
        }
    }
}

/// Change the daily trigger time via elevated PowerShell + Schedule.Service
/// COM. Needed because unprivileged COM access is denied on hardened builds,
/// and `schtasks /change` cannot represent S4U tasks (it demands the account
/// password and hangs on a console ShellExecute never provides).
pub fn set_task_time_elevated(hhmm: &str) -> ScheduleResult {
    let script = format!(
        "$ErrorActionPreference = 'Stop'\n\
         $svc = New-Object -ComObject Schedule.Service\n\
         $svc.Connect()\n\
         $folder = $svc.GetFolder('\\')\n\
         $task = $null; $taskName = $null\n\
         foreach ($n in '{TASK_NAME}','{LEGACY_TASK_NAME}') {{ try {{ $task = $folder.GetTask($n); $taskName = $n; break }} catch {{}} }}\n\
         if (-not $task) {{ throw 'updater task not found' }}\n\
         $def = $task.Definition\n\
         $trig = $def.Triggers.Item(1)\n\
         $sb = [string]$trig.StartBoundary\n\
         if ($sb.Length -lt 19 -or $sb[10] -ne 'T') {{ throw \"unexpected StartBoundary: $sb\" }}\n\
         $trig.StartBoundary = $sb.Substring(0,11) + '{hhmm}' + ':00' + $sb.Substring(19)\n\
         $folder.RegisterTaskDefinition($taskName, $def, 6, $null, $null, 2, $null) | Out-Null\n\
         exit 0\n"
    );
    let path = std::env::temp_dir().join(format!("httk-settime-{}.ps1", std::process::id()));
    if std::fs::write(&path, script).is_err() {
        return ScheduleResult::Failed("could not write helper script".into());
    }
    let ps = format!(
        "{}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
        std::env::var("SystemRoot").unwrap_or_else(|_| r"C:\Windows".into())
    );
    let args = format!(
        "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{}\"",
        path.display()
    );
    let result = run_elevated_wait(&ps, &args, 120_000);
    let _ = std::fs::remove_file(&path);
    result
}

/// Start the daily updater via an elevated schtasks.exe (one UAC prompt).
/// Hardened Windows builds deny unprivileged read/run rights on scheduled
/// tasks, so this is the fallback when task::run_now() gets 0x80070005.
/// schtasks /run returns immediately — no wait needed.
pub fn run_task_elevated() -> ScheduleResult {
    let args =
        format!("/c schtasks /run /tn \"{TASK_NAME}\" || schtasks /run /tn \"{LEGACY_TASK_NAME}\"");
    let args_w = wide(&args);
    let file_w = wide("cmd.exe");
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
            const ERROR_CANCELLED: u32 = 1223;
            if e.code() == HRESULT::from_win32(ERROR_CANCELLED)
                || GetLastError().0 == ERROR_CANCELLED
            {
                return ScheduleResult::Cancelled;
            }
            return ScheduleResult::Failed(e.to_string());
        }
        if !info.hProcess.is_invalid() {
            let _ = CloseHandle(info.hProcess);
        }
        ScheduleResult::Applied
    }
}
