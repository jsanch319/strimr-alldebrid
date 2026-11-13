# AllDebrid integration — experimental UI milestone

## Added
- AllDebrid (experimental) button on the existing provider-selection screen, opening a separate SwiftUI library screen without requiring Plex login.
- Keychain-backed API key entry and sign-out.
- Fetching video entries from AllDebrid saved links, manual refresh, cleaned display titles.
- Unlock-on-play and native AVPlayer/VideoPlayer presentation for compatible direct video URLs.
- Swift source syntax parsed successfully on Linux using `swiftc -frontend -parse`.

## Not completed / limitations
- **Not compiled with Xcode or tested on an iPhone**. Syntax parsing does not validate Apple framework types, deployment compatibility, or runtime behavior.
- Only `user/links` saved links; AllDebrid magnet history and nested files are not included. Endpoint parsing may need adjustment after testing against documented API samples.
- Does not yet integrate AllDebrid into Strimr's full home UI, poster metadata, search, Continue Watching, or player history.
- AVPlayer may not support some MKV containers, Dolby Vision profiles, subtitles, or audio codecs. No guaranteed 4K, HDR, or fallback.
- App Store app is not modified in place; requires compiling and signing a separate app.
- Keep API keys private. Do not put keys or unlocked URLs in public GitHub repositories, logs, or screenshots.
- Keep the GPL-3.0 license and required notices when distributing source.

## Next tests
1. Build with Xcode on macOS/cloud Mac and address any compiler errors.
2. Validate AllDebrid response schemas with safe redacted test fixtures.
3. Implement magnet history/file selection, artwork, progress persistence, and codec-aware playback.
