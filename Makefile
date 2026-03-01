.PHONY: rust-check frontend-check check

TMPDIR ?= /tmp

rust-check:
	cargo fmt --check
	cargo clippy --workspace --all-targets -- -D warnings
	cargo test --workspace
	TMPDIR=$(TMPDIR) cargo build --workspace --release

frontend-check:
	cd frontend && npx tsc --noEmit
	cd frontend && npx eslint .
	cd frontend && npx vite build

check: rust-check frontend-check
