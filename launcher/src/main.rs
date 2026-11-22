#![windows_subsystem = "windows"]

mod actions;
mod i18n;
mod prefs;
mod status;
mod task;

use i18n::{fmt, tr, Lang};
use slint::SharedString;
use status::{pill_state, Pill, StatusInfo, TaskLookup};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};

slint::include_modules!();

fn build_status_data(info: &StatusInfo, lang: Lang) -> StatusData {
    let time = match &info.task {
        TaskLookup::Found {
            start_time: Some(t),
            ..
        } => t.clone(),
        _ => "09:00".to_string(),
    };
    let version_text = info
        .installed_version
        .as_ref()
        .map(|v| format!("v{v}"))
        .unwrap_or_else(|| tr(lang, "notFound").to_string());
    let latest_text = info
        .result
        .as_ref()
        .and_then(|r| r.latest_version.as_ref())
        .map(|v| fmt(lang, "latest", &[v]))
        .unwrap_or_default();
    let task_text = match &info.task {
        TaskLookup::Error(e) => {
            if e.contains("0x80070005") {
                tr(lang, "taskAccessDenied").to_string()
            } else {
                fmt(lang, "unavailable", &[e])
            }
        }
        TaskLookup::NotFound => tr(lang, "taskMissing").to_string(),
        TaskLookup::Found { state, .. } => fmt(
            lang,
            "taskFmt",
            &[i18n::task_state_name(lang, *state), &time],
        ),
    };
    let lastrun_text = match &info.task {
        TaskLookup::Found {
            last_run: Some(t), ..
        } => {
            let rel = i18n::relative_hint(lang, *t);
            let d = i18n::format_date(lang, *t);
            if rel.is_empty() {
                d
            } else {
                format!("{d} · {rel}")
            }
        }
        _ => tr(lang, "never").to_string(),
    };
    let (result_text, result_is_error) = match &info.result {
        Some(r) => {
            let name = i18n::result_status_name(lang, &r.status);
            if let Some(e) = &r.error {
                (format!("{name} - {e}"), true)
            } else {
                let mut s = name;
                if let Some(m) = r.modified {
                    let rel = i18n::relative_hint(lang, m);
                    if !rel.is_empty() {
                        s = format!("{s} · {rel}");
                    }
                }
                (s, false)
            }
        }
        None => (tr(lang, "noRuns").to_string(), false),
    };
    let pill = pill_state(info);
    let (pill_kind, pill_text) = match pill {
        Pill::Unknown => (0, tr(lang, "pillUnknown").to_string()),
        Pill::Good => (1, tr(lang, "pillGood").to_string()),
        Pill::Updating => (2, tr(lang, "pillUpdating").to_string()),
        Pill::Ready => (2, tr(lang, "pillReady").to_string()),
        Pill::Error => (3, tr(lang, "pillError").to_string()),
    };
    StatusData {
        version_text: version_text.into(),
        latest_text: latest_text.into(),
        task_text: task_text.into(),
        lastrun_text: lastrun_text.into(),
        result_text: result_text.into(),
        result_is_error,
        subtitle_text: fmt(lang, "subtitle", &[&time]).into(),
        pill_text: pill_text.into(),
        pill_kind,
        task_time: time.into(),
    }
}

fn build_txt(lang: Lang) -> Txt {
    let g = |k: &str| SharedString::from(tr(lang, k));
    Txt {
        installed: g("installed"),
        task: g("task"),
        lastrun: g("lastRun"),
        updresult: g("updResult"),
        settings: g("settings"),
        timelabel: g("timeLabel"),
        apply: g("apply"),
        open: g("open"),
        check: g("check"),
        title: g("title"),
        footer: g("footer"),
        langs: g("langSwitch"),
        minimize: g("minimize"),
        close: g("close"),
        picktime: g("pickTime"),
        openacc: g("open"),
        checkacc: g("check"),
        timefield: g("timeLabel"),
    }
}

enum Cmd {
    Refresh,
}

/// A UI message kept as (kind, i18n key, args) so it can be re-rendered in the
/// new language when the user toggles EN/VI.
#[derive(Clone)]
struct UiMsg {
    kind: i32,
    key: &'static str,
    args: Vec<String>,
}

#[derive(Default)]
struct MsgState {
    notice: Option<UiMsg>,
    save: Option<UiMsg>,
}

fn render_msg(lang: Lang, m: &UiMsg) -> String {
    let args: Vec<&str> = m.args.iter().map(|s| s.as_str()).collect();
    fmt(lang, m.key, &args)
}

fn apply_lang(ui: &AppWindow, lang: Lang) {
    ui.set_txt(build_txt(lang));
    ui.set_lang_en(lang == Lang::En);
}

fn set_notice(ui: &AppWindow, msgs: &Mutex<MsgState>, m: Option<UiMsg>) {
    let l = if ui.get_lang_en() { Lang::En } else { Lang::Vi };
    match &m {
        Some(mm) => {
            ui.set_notice_kind(mm.kind);
            ui.set_notice_text(render_msg(l, mm).into());
        }
        None => ui.set_notice_text("".into()),
    }
    msgs.lock().unwrap().notice = m;
}

fn set_save(ui: &AppWindow, msgs: &Mutex<MsgState>, m: Option<UiMsg>) {
    let l = if ui.get_lang_en() { Lang::En } else { Lang::Vi };
    let kind = m.as_ref().map(|mm| mm.kind).unwrap_or(0);
    let text = m.as_ref().map(|mm| render_msg(l, mm)).unwrap_or_default();
    msgs.lock().unwrap().save = m;
    ui.set_save_kind(kind);
    ui.set_save_text(text.into());
}

fn check_only_run() -> i32 {
    let Some(dir) = status::install_dir() else {
        return 1;
    };
    let exe = dir.join(r"Project\HTKK.exe");
    if !exe.is_file() {
        return 1;
    }
    let cfg = dir.join(r"Project\HTKK.exe.config");
    match std::fs::read_to_string(&cfg)
        .ok()
        .and_then(|xml| status::parse_installed_version(&xml).ok())
    {
        Some(v) => {
            println!("{v}");
            0
        }
        None => 1,
    }
}

fn save_png(buf: &slint::SharedPixelBuffer<slint::Rgba8Pixel>, path: &str) -> Result<(), String> {
    if let Some(parent) = std::path::Path::new(path).parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let file = std::fs::File::create(path).map_err(|e| e.to_string())?;
    let mut enc = png::Encoder::new(std::io::BufWriter::new(file), buf.width(), buf.height());
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    let mut w = enc.write_header().map_err(|e| e.to_string())?;
    w.write_image_data(buf.as_bytes())
        .map_err(|e| e.to_string())
}

fn snapshot(ui: &AppWindow) -> Option<slint::SharedPixelBuffer<slint::Rgba8Pixel>> {
    ui.window().take_snapshot().ok()
}

#[cfg(windows)]
mod win {
    use slint::ComponentHandle;
    use windows::core::{w, PCWSTR};
    use windows::Win32::Foundation::{CloseHandle, GetLastError, HWND, LPARAM, WPARAM};
    use windows::Win32::Graphics::Dwm::{DwmSetWindowAttribute, DWMWINDOWATTRIBUTE};
    use windows::Win32::System::Console::{AttachConsole, FreeConsole, ATTACH_PARENT_PROCESS};
    use windows::Win32::System::Threading::CreateMutexW;
    use windows::Win32::UI::HiDpi::{
        SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
    };
    use windows::Win32::UI::Input::KeyboardAndMouse::ReleaseCapture;
    use windows::Win32::UI::WindowsAndMessaging::{
        FindWindowW, IsIconic, SendMessageW, SetForegroundWindow, ShowWindow, SW_RESTORE,
        WM_NCLBUTTONDOWN,
    };

    /// Single-instance mutex. Returns false if another copy is running
    /// (and focuses its window before returning).
    pub fn single_instance() -> bool {
        unsafe {
            let h = CreateMutexW(None, true, w!("Local\\HtkkLauncherSingleInstance"));
            let exists = GetLastError().0 == 183; // ERROR_ALREADY_EXISTS
            if let Ok(h) = h {
                if exists {
                    let _ = CloseHandle(h);
                    if let Ok(hwnd) = FindWindowW(PCWSTR::null(), w!("HTKK Updater")) {
                        if !hwnd.is_invalid() {
                            if IsIconic(hwnd).as_bool() {
                                let _ = ShowWindow(hwnd, SW_RESTORE);
                            }
                            let _ = SetForegroundWindow(hwnd);
                        }
                    }
                    return false;
                }
                // HANDLE has no destructor — it stays open for the process
                // lifetime without us doing anything.
                let _keep_alive = h;
            }
            true
        }
    }

    pub fn hwnd(ui: &crate::AppWindow) -> Option<HWND> {
        use raw_window_handle::{HasWindowHandle, RawWindowHandle};
        let wh = ui.window().window_handle();
        match wh.window_handle().ok()?.as_raw() {
            RawWindowHandle::Win32(h) => Some(HWND(h.hwnd.get() as *mut _)),
            _ => None,
        }
    }

    pub fn apply_dwm(hwnd: HWND) {
        unsafe {
            // Win11 rounded corners + dark mode; silently no-ops on Win10.
            let corner: u32 = 2; // DWMWCP_ROUND
            let _ = DwmSetWindowAttribute(
                hwnd,
                DWMWINDOWATTRIBUTE(33), // DWMWA_WINDOW_CORNER_PREFERENCE
                &corner as *const _ as _,
                std::mem::size_of_val(&corner) as u32,
            );
            let dark: i32 = 1;
            let _ = DwmSetWindowAttribute(
                hwnd,
                DWMWINDOWATTRIBUTE(20), // DWMWA_USE_IMMERSIVE_DARK_MODE
                &dark as *const _ as _,
                std::mem::size_of_val(&dark) as u32,
            );
        }
    }

    pub fn dpi_awareness() {
        unsafe {
            let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        }
    }

    pub fn drag(hwnd: HWND) {
        unsafe {
            let _ = ReleaseCapture();
            let _ = SendMessageW(hwnd, WM_NCLBUTTONDOWN, Some(WPARAM(2)), Some(LPARAM(0)));
            // HTCAPTION
        }
    }

    pub fn attach_parent_console() {
        unsafe {
            let _ = AttachConsole(ATTACH_PARENT_PROCESS);
        }
    }

    pub fn detach_console() {
        unsafe {
            let _ = FreeConsole();
        }
    }
}

fn main() -> Result<(), slint::PlatformError> {
    let mut lang_arg: Option<Lang> = None;
    let mut screenshot: Option<String> = None;
    let mut check_only = false;
    let args: Vec<String> = std::env::args().collect();
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--check-only" => check_only = true,
            "--lang" => {
                if let Some(v) = args.get(i + 1) {
                    lang_arg = Lang::parse(v);
                    i += 1;
                }
            }
            "--screenshot" => {
                if let Some(v) = args.get(i + 1) {
                    screenshot = Some(v.clone());
                    i += 1;
                }
            }
            _ => {}
        }
        i += 1;
    }

    #[cfg(windows)]
    {
        win::dpi_awareness();
        if check_only {
            win::attach_parent_console();
            let r = check_only_run();
            win::detach_console();
            std::process::exit(r);
        }
    }
    #[cfg(not(windows))]
    if check_only {
        std::process::exit(check_only_run());
    }

    if !win::single_instance() {
        return Ok(());
    }

    let lang = lang_arg.or_else(prefs::load).unwrap_or(Lang::En);
    let cur_lang = Arc::new(Mutex::new(lang));

    let ui = AppWindow::new()?;
    apply_lang(&ui, lang);
    ui.set_st(build_status_data(&StatusInfo::default(), lang));

    let (cmd_tx, cmd_rx) = mpsc::channel::<Cmd>();
    let last_info: Arc<Mutex<Option<StatusInfo>>> = Arc::new(Mutex::new(None));

    // background status worker: poll every 3 s (or on demand), push on change
    {
        let weak = ui.as_weak();
        let last_info = last_info.clone();
        let cur_lang = cur_lang.clone();
        std::thread::spawn(move || {
            let mut last: Option<StatusInfo> = None;
            loop {
                let info = status::gather(task::query());
                *last_info.lock().unwrap() = Some(info.clone());
                if last.as_ref() != Some(&info) {
                    let lang = *cur_lang.lock().unwrap();
                    let data = build_status_data(&info, lang);
                    let _ = weak.upgrade_in_event_loop(move |ui| {
                        if !ui.get_time_adopted() {
                            ui.set_picked_time(data.task_time.clone());
                            ui.set_time_adopted(true);
                        }
                        ui.set_st(data);
                    });
                    last = Some(info);
                }
                match cmd_rx.recv_timeout(std::time::Duration::from_secs(3)) {
                    Ok(Cmd::Refresh) | Err(mpsc::RecvTimeoutError::Timeout) => {}
                    Err(mpsc::RecvTimeoutError::Disconnected) => break,
                }
            }
        });
    }

    let msgs = Arc::new(Mutex::new(MsgState::default()));

    // ---- callbacks ----
    ui.on_set_lang({
        let tx = cmd_tx.clone();
        let cur_lang = cur_lang.clone();
        let last_info = last_info.clone();
        let msgs = msgs.clone();
        let weak = ui.as_weak();
        move |en| {
            let l = if en { Lang::En } else { Lang::Vi };
            *cur_lang.lock().unwrap() = l;
            prefs::save(l);
            if let Some(ui) = weak.upgrade() {
                apply_lang(&ui, l);
                if let Some(info) = last_info.lock().unwrap().clone() {
                    ui.set_st(build_status_data(&info, l));
                }
                // re-render any visible notice/save message in the new language
                let g = msgs.lock().unwrap();
                if let Some(m) = &g.notice {
                    ui.set_notice_kind(m.kind);
                    ui.set_notice_text(render_msg(l, m).into());
                }
                if let Some(m) = &g.save {
                    ui.set_save_kind(m.kind);
                    ui.set_save_text(render_msg(l, m).into());
                }
            }
            let _ = tx.send(Cmd::Refresh);
        }
    });

    ui.on_open_htkk({
        let msgs = msgs.clone();
        let weak = ui.as_weak();
        move || {
            if let Some(ui) = weak.upgrade() {
                match actions::open_htkk() {
                    Ok(()) => set_notice(&ui, &msgs, None),
                    Err(actions::OpenError::NotInstalled | actions::OpenError::ExeMissing) => {
                        set_notice(
                            &ui,
                            &msgs,
                            Some(UiMsg {
                                kind: 2,
                                key: "exeMissing",
                                args: vec![],
                            }),
                        )
                    }
                    Err(actions::OpenError::Launch(e)) => set_notice(
                        &ui,
                        &msgs,
                        Some(UiMsg {
                            kind: 2,
                            key: "launchFail",
                            args: vec![e],
                        }),
                    ),
                }
            }
        }
    });

    ui.on_check_updates({
        let tx = cmd_tx.clone();
        let msgs = msgs.clone();
        let weak = ui.as_weak();
        move || {
            // run the task off the UI thread
            let weak = weak.clone();
            let tx = tx.clone();
            let msgs = msgs.clone();
            std::thread::spawn(move || {
                let mut outcome = task::run_now();
                // hardened builds deny unprivileged task access -> elevate once
                if matches!(&outcome, Err(task::RunError::Other(e)) if e.contains("0x80070005")) {
                    outcome = match actions::run_task_elevated() {
                        actions::ScheduleResult::Applied(_) => Ok(()),
                        actions::ScheduleResult::Cancelled => {
                            Err(task::RunError::Other("cancelled".into()))
                        }
                        actions::ScheduleResult::Failed(e) => Err(task::RunError::Other(e)),
                    };
                }
                let msg = match &outcome {
                    Ok(()) => None,
                    Err(task::RunError::NotFound) => Some(UiMsg {
                        kind: 2,
                        key: "taskErr",
                        args: vec![],
                    }),
                    Err(task::RunError::Disabled) => Some(UiMsg {
                        kind: 2,
                        key: "disabled",
                        args: vec![],
                    }),
                    Err(task::RunError::Running) => Some(UiMsg {
                        kind: 2,
                        key: "alreadyRun",
                        args: vec![],
                    }),
                    Err(task::RunError::Other(e)) if e == "cancelled" => Some(UiMsg {
                        kind: 0,
                        key: "cancelled",
                        args: vec![],
                    }),
                    Err(task::RunError::Other(e)) => Some(UiMsg {
                        kind: 2,
                        key: "runFail",
                        args: vec![e.clone()],
                    }),
                };
                let _ = weak.upgrade_in_event_loop(move |ui| {
                    set_notice(&ui, &msgs, msg);
                });
                let _ = tx.send(Cmd::Refresh);
            });
        }
    });

    ui.on_apply_time({
        let tx = cmd_tx.clone();
        let msgs = msgs.clone();
        let weak = ui.as_weak();
        move |t| {
            let Some(norm) = status::normalize_time(t.as_ref()) else {
                if let Some(ui) = weak.upgrade() {
                    set_save(
                        &ui,
                        &msgs,
                        Some(UiMsg {
                            kind: 2,
                            key: "invalidTime",
                            args: vec![],
                        }),
                    );
                }
                return;
            };
            if let Some(ui) = weak.upgrade() {
                ui.set_saving(true);
                set_save(
                    &ui,
                    &msgs,
                    Some(UiMsg {
                        kind: 0,
                        key: "saving",
                        args: vec![],
                    }),
                );
            }
            let weak = weak.clone();
            let tx = tx.clone();
            let msgs = msgs.clone();
            std::thread::spawn(move || {
                let result = actions::set_task_time(&norm);
                let msg = match result {
                    actions::ScheduleResult::Applied(t2) => UiMsg {
                        kind: 1,
                        key: "saved",
                        args: vec![t2],
                    },
                    actions::ScheduleResult::Cancelled => UiMsg {
                        kind: 0,
                        key: "cancelled",
                        args: vec![],
                    },
                    actions::ScheduleResult::Failed(e) => UiMsg {
                        kind: 2,
                        key: "changeFail",
                        args: vec![e],
                    },
                };
                let _ = weak.upgrade_in_event_loop(move |ui| {
                    ui.set_saving(false);
                    set_save(&ui, &msgs, Some(msg));
                    ui.set_time_adopted(false); // re-adopt the new task time on next poll
                });
                let _ = tx.send(Cmd::Refresh);
            });
        }
    });

    ui.on_ui_minimize({
        let weak = ui.as_weak();
        move || {
            if let Some(ui) = weak.upgrade() {
                ui.window().set_minimized(true);
            }
        }
    });
    ui.on_ui_close(|| {
        let _ = slint::quit_event_loop();
    });
    ui.on_ui_drag({
        let weak = ui.as_weak();
        move || {
            if let Some(ui) = weak.upgrade() {
                if let Some(h) = win::hwnd(&ui) {
                    win::drag(h);
                }
            }
        }
    });

    // apply DWM attributes once, as soon as the HWND exists
    #[cfg(windows)]
    {
        let weak = ui.as_weak();
        let timer = std::rc::Rc::new(slint::Timer::default());
        let timer2 = timer.clone();
        let mut attempts = 0u32;
        timer.start(
            slint::TimerMode::Repeated,
            std::time::Duration::from_millis(100),
            move || {
                attempts += 1;
                if attempts > 30 {
                    timer2.stop();
                    return;
                }
                if let Some(ui) = weak.upgrade() {
                    if let Some(h) = win::hwnd(&ui) {
                        win::apply_dwm(h);
                        timer2.stop();
                    }
                }
            },
        );
        std::mem::forget(timer); // keep the timer alive for the process lifetime
    }

    if let Some(path) = screenshot {
        let weak = ui.as_weak();
        let path2 = path.clone();
        let t = slint::Timer::default();
        t.start(
            slint::TimerMode::SingleShot,
            std::time::Duration::from_millis(2500),
            move || {
                if let Some(ui) = weak.upgrade() {
                    if let Some(buf) = snapshot(&ui) {
                        let _ = save_png(&buf, &path2);
                    }
                    ui.set_picker_open(true);
                    let pop_path = path2.replace(".png", "-popup.png");
                    if let Some(buf) = snapshot(&ui) {
                        let _ = save_png(&buf, &pop_path);
                    }
                }
                let _ = slint::quit_event_loop();
            },
        );
        std::mem::forget(t);
    }

    ui.run()
}
