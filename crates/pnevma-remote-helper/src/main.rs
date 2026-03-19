fn main() {
    if let Err(error) = pnevma_remote_helper::run_cli(std::env::args()) {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
