# Strimr AllDebrid integration — starter package

This is an **initial, untested source-code scaffold**, NOT a working server-free iPhone app or an IPA.

## Confirmed from the uploaded project
- Strimr is a Swift/Xcode project with Plex and Jellyfin providers.
- Shared/Services/Protocols/MediaServiceProtocols.swift defines the media-service interfaces.
- Shared/Providers/Plex and Shared/Providers/Jellyfin implement those interfaces.
- The project has a GitHub Actions build workflow, but an unsigned simulator build is not an installable iPhone app.
- The included project is GPL-3.0 licensed; retain its license and comply with its terms when distributing modifications.

## What this starter adds
- `Shared/Providers/AllDebrid/AllDebridModels.swift`: basic local catalog/playback data models.
- `Shared/Providers/AllDebrid/AllDebridCatalog.swift`: a local catalog that can store sanitized entries and a resolved playback URL in memory.
- Neither file is added to the Xcode target or wired to Strimr's media-service interfaces yet. The original project is otherwise unchanged.

## Remaining work before playback
1. Confirm the current official AllDebrid API, authentication, account terms, and which content endpoints can be used for this application.
2. Implement API calls and safe credential storage (never commit API keys to GitHub).
3. Implement the MediaHomeService, MediaLibraryService, MediaDetailService, MediaPlaybackService and related interfaces or adapt the app architecture.
4. Replace the mandatory Plex/Jellyfin login path with an optional AllDebrid sign-in.
5. Integrate playback with the existing player, and implement metadata, resume, error handling, and link refresh.
6. Test in Xcode on a macOS runner, then handle device signing and installation separately.

**No 4K/HDR/Dolby Vision performance guarantee is possible before device testing.**
