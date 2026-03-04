# Vendor Dependencies

## Ghostty

Clone ghostty into this directory:

```bash
git submodule add https://github.com/ghostty-org/ghostty.git vendor/ghostty
cd vendor/ghostty && git checkout v1.2.0
```

Build xcframework:

```bash
cd vendor/ghostty && zig build -Demit-xcframework=true -Doptimize=ReleaseFast
```
