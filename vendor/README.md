# Vendor Dependencies

## Ghostty

Fetch ghostty into this directory:

```bash
./scripts/fetch-ghostty.sh
```

Build xcframework:

```bash
cd vendor/ghostty && zig build -Demit-xcframework=true -Doptimize=ReleaseFast
```
