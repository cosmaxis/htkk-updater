fn main() {
    slint_build::compile("ui/app.slint").expect("slint compile failed");

    // Embed manifest + icon resources. embed-resource picks rc.exe / llvm-rc on
    // MSVC (CI) and x86_64-w64-mingw32-windres on GNU; it panics when no
    // resource compiler exists, which we tolerate locally (DPI awareness is
    // also set at runtime) but not when HTKK_REQUIRE_RESOURCES=1 is set
    // (CI release builds). A plain `windres` (unprefixed MinGW64) is wired up
    // via the RC env var so `cargo build` alone still embeds resources.
    if std::env::var_os("RC").is_none() {
        let mut dirs: Vec<std::path::PathBuf> = std::env::var_os("PATH")
            .map(|p| std::env::split_paths(&p).collect())
            .unwrap_or_default();
        if let Some(home) = std::env::var_os("USERPROFILE") {
            dirs.push(std::path::PathBuf::from(home).join(r"mingw64\bin"));
        }
        let found = ["x86_64-w64-mingw32-windres", "windres"]
            .iter()
            .flat_map(|t| dirs.iter().map(move |d| d.join(format!("{t}.exe"))))
            .find(|p| p.is_file());
        if let Some(rc) = found {
            // embed-resource chains windres with `ar` on GNU targets — make the
            // tool's own directory reachable so sibling binutils resolve too.
            std::env::set_var("RC", &rc);
            if let Some(dir) = rc.parent() {
                let mut p = vec![dir.to_path_buf()];
                p.extend(dirs);
                if let Ok(joined) = std::env::join_paths(p) {
                    std::env::set_var("PATH", joined);
                }
            }
        }
    }
    let r = std::panic::catch_unwind(|| {
        embed_resource::compile("htkk-launcher.rc", embed_resource::NONE)
    });
    match r {
        Ok(_) => println!("cargo:rustc-cfg=has_embedded_resources"),
        Err(_) if std::env::var_os("HTKK_REQUIRE_RESOURCES").is_some() => {
            panic!("no resource compiler (rc/windres) found and HTKK_REQUIRE_RESOURCES is set")
        }
        Err(_) => println!(
            "cargo:warning=no resource compiler (rc/windres) found; building without embedded manifest/icon"
        ),
    }
}
