fn main() {
    slint_build::compile("ui/app.slint").expect("slint compile failed");

    // Embed manifest + icon resources. embed-resource picks rc.exe / llvm-rc on
    // MSVC (CI) and windres on GNU; it panics when no resource compiler exists,
    // which we tolerate locally (DPI awareness is also set at runtime) but not
    // when HTKK_REQUIRE_RESOURCES=1 is set (CI release builds).
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
