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

## Patches

### `0001-fallback-without-display-link.patch`

- **Applied to:** Ghostty v1.3.1 (commit `332b2ae`)
- **Why necessary:** macOS CI runners lack a physical display; `DisplayLink.createWithActiveCGDisplays()` fails. Without the patch, Ghostty init crashes in headless environments.
- **Why safe:** Only changes error handling for display link creation. Falls back to no-vsync (null display link) with a warning log. No rendering logic changes.
- **Removal condition:** When upstream Ghostty adds graceful fallback for missing displays.
