fn main() {
    let args: Vec<String> = std::env::args().collect();

    // The "serve" command requires an async runtime.
    if args.get(1).map(String::as_str) == Some("serve") {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("failed to build tokio runtime");
        let paths = match pnevma_remote_helper::HelperPaths::from_env() {
            Ok(p) => p,
            Err(e) => {
                eprintln!("{e}");
                std::process::exit(1);
            }
        };
        if let Err(error) = runtime.block_on(pnevma_remote_helper::serve::run_serve(paths)) {
            eprintln!("{error}");
            std::process::exit(1);
        }
        return;
    }

    // Existing synchronous CLI path.
    if let Err(error) = pnevma_remote_helper::run_cli(args) {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
