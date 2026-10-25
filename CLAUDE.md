# Releasing

1. Bump the version in `scripts/build-app.sh` (short version and build number), `scripts/check-bundle.py`, `README.md`, `site/download.html` and the fallback in `Sources/VectorScroll/Updates.swift`.
2. Commit as `<change>; <version>` and push `main`.
3. Write release notes in the style of the previous release (`gh release view`).
4. Run `scripts/release.sh <notes.md>`.

Releases must be signed with the self-signed "VectorScroll" certificate (SHA-1 `D2010A9E…`). The in-app updater rejects anything else, including ad-hoc builds. On miniko it lives in `~/Library/Keychains/vectorscroll-release.keychain-db`, with the password in `~/.vs-kc-pass`. Tags have no `v` prefix.
