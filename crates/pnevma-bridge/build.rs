use std::env;
use std::path::PathBuf;

fn main() {
    let crate_dir = env::var("CARGO_MANIFEST_DIR")
        .expect("CARGO_MANIFEST_DIR is always set by Cargo during build scripts");
    let out_dir = PathBuf::from(&crate_dir);

    let config = cbindgen::Config::from_file("cbindgen.toml").unwrap_or_default();

    cbindgen::Builder::new()
        .with_crate(crate_dir)
        .with_config(config)
        .generate()
        .expect("Unable to generate bindings")
        .write_to_file(out_dir.join("pnevma-bridge.h"));
}
