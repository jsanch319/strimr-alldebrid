# iOS AirPlay

The AirPlay button in the existing player's header presents Apple's `AVRoutePickerView`, prioritizing video receivers. It remains present when no receiver is available; Apple owns discovery, selection and the active-route indicator. The route picker keeps the controls visible while its system panel is open. This is the same player for automatic and manually selected AllDebrid sources and media-server playback.

Each engine-created AVPlayer explicitly allows external playback and keeps the existing background playback policy. AetherEngine already configures its playback audio session, observes external playback, serves its supported loopback streams over the LAN, carries subtitle selection and restores playback position during route changes. Strimr does not create another AVPlayer, force another codec/quality, alter HDR or audio settings, or install another progress recorder. The existing clock, local exact-second recorder and Simkl tracker remain authoritative for their existing responsibilities. Discord is independently gated by valid configuration.

The existing `audio` background mode is retained. iOS Debug and Release local-network usage descriptions now mention AirPlay as well as media servers. No Bonjour browser, additional discovery entitlement or credentials are needed for Apple's native picker. Allow Local Network access if prompted for the engine's LAN stream. Keep sender and receiver on a reachable network; AP/client isolation, VPNs and firewalls can prevent delivery.

## Format and device limits

AirPlay video, 4K, HDR10 and Dolby Vision depend on the source, engine route, receiver, OS and connected display. The picker does not guarantee a format. Existing engine remuxing/receiver fallback remains in control; Dolby Vision profiles may require conversion or lose enhancement data, and software-decoded paths can send audio while keeping the picture on iPhone. No universal original-bitstream or Dolby Vision guarantee is made. Selected supported native subtitle/audio tracks can be delivered; styled overlays, bitmap captions and unsupported codecs may differ or be unavailable on the receiver. Receiver selection is not evidence of successful video delivery.

## Keychain investigation

The previous unsigned simulator capture displayed `KeychainError error 0`: this is Swift/NSError's enum-case representation, **not evidence that Security returned OSStatus 0**. Credential stores already distinguish missing items from failed Security calls. `KeychainError` now provides a localized diagnostic preserving the actual OSStatus and Security description, with specific signing/entitlement or locked-device guidance. No Keychain query, accessibility class, entitlement, credential migration or storage policy was weakened. Credentials are never copied into UserDefaults, fixtures or logs.

A missing entitlement on an unsigned simulator is a build limitation; a repeatable failure in a correctly signed device build is a separate bug to investigate using its actual Security status and signing entitlements. The new simulator capture can identify its status; it cannot prove that signed-device access succeeds or fails.

## Verification

Automated tests cover enabling external playback on replacement players without changing volume/mute/buffering preferences, accurate Keychain status diagnostics and optional Discord configuration. Existing resume, matching, automatic/manual source, tracker and catalog interaction regressions also run. Builds compile the actual UIKit route picker. CI simulators cannot validate receiver discovery, wireless video, HDR or live account playback.

On a signed iPhone with privately configured AllDebrid/Simkl accounts, test:

- Route picker discovery and selection of Apple TV/compatible TV; disconnect and reconnect before and during playback.
- Auto Play and manual selection with a known matching movie and TV episode; local exact-second resume and a Simkl fallback.
- Play/pause, seeks in both directions, audio/subtitle changes, progress saving, background/lock, return to iPhone and source fallback.
- Known SDR, HDR10 and supported Dolby Vision files; verify the actual receiver/TV signal and rendering, not only the iPhone badge.
- Local Network permission denied/allowed, an unreachable receiver, expired source URL and unsupported formats.
- Keychain account save/load after relaunch and device unlock. Record the actual Security status if it fails; never share credentials.

No real service credentials are required by the automated checks.
