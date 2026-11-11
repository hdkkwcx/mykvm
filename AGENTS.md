# Repository workflow

- Use `bate` for development, fixes, local builds, and testing.
- Do not create separate `codex/*` development or release branches unless the user explicitly requests one.
- Preserve existing commits and uncommitted changes when returning to `bate`.
- Release changes follow a pull request from `bate` into `main`.
- Write every commit message, including its subject and body, in English.
- Do not add AI attribution or `Co-Authored-By` trailers to commits or pull requests.

## Scope of changes

- Keep changes within MyKVM. Do not modify Clash Verge, any other application's configuration, or macOS or Windows system settings.
- Leave existing TUN, network routes, firewall rules, and OS permissions as configured when troubleshooting. Use read-only diagnostics for settings outside MyKVM.

## Code map

- `src/` contains the React and TypeScript UI. `src/layout.ts` handles display geometry and adjacency, and `src/desktopApi.ts` calls the Tauri backend.
- `src-tauri/src/lib.rs` contains Tauri commands and UDP discovery. `src-tauri/src/input.rs` handles input capture and forwarding, and `src-tauri/src/quic_transport.rs` handles QUIC transport.

## Local verification

- Install frontend dependencies with `npm ci` and use `npm run tauri:dev` to run the desktop app locally.
- Frontend checks are `npm run build`, `npm run lint`, and `npm test`.
- Backend checks are `cargo check --manifest-path src-tauri/Cargo.toml --workspace --all-targets --locked` and `cargo test --manifest-path src-tauri/Cargo.toml --workspace --locked`.
