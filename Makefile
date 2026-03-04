.PHONY: rust-check check

TMPDIR ?= /tmp

rust-check:
	cargo fmt --check
	cargo clippy --workspace --all-targets -- -D warnings
	cargo test --workspace
	TMPDIR=$(TMPDIR) cargo build --workspace --release

check: rust-check
