# Credential-free iPhone visual tests

`Strimr-VisualTests` runs the actual server-free SwiftUI Home, bottom tabs, catalog cards,
shared backdrop renderer, TMDb detail views and native navigation on an iPhone simulator.
It does not replace these screens with a mock UI. It is separate from the production `Strimr` scheme.

The test runner passes `-CatalogVisualTesting` and an explicit JSON fixture payload to the app.
The transport is compiled only with `DEBUG && os(iOS) && targetEnvironment(simulator)`;
it is absent from physical-device and Release builds. Unsupported fixture requests fail instead
of reaching a live service. No AllDebrid, TMDb or Simkl credentials are supplied. Tracker writes
are disabled, account/settings stores and progress persistence are isolated, and each capture
visibly says `SIMULATOR · FIXTURE DATA`.

The title names, descriptions, IDs and artwork paths in `StrimrVisualUITests/catalog-fixture.json`
were read from the corresponding public TMDb title pages on 2026-11-15. Watchlist membership,
progress, episode metadata, provider results and recommendation order are synthetic test inputs,
not live account data, current charts or verified streaming availability. Provider logo fallback
is intentional in this fixture. Public TMDb artwork still loads through the normal image pipeline,
so the simulator needs internet access to `image.tmdb.org`.

## Run

On a Mac with Xcode and an installed iPhone simulator runtime, prepare the normal local
`Config/Config.xcconfig` (never put credentials in it), then run:

```sh
xcodebuild test -project Strimr.xcodeproj -scheme Strimr-VisualTests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -resultBundlePath build/CatalogVisualTests.xcresult CODE_SIGNING_ALLOWED=NO
xcrun xcresulttool export attachments --path build/CatalogVisualTests.xcresult \
  --output-path build/screenshots
```

Use an installed simulator name or UDID. The `AllDebrid iOS compile check` GitHub Actions
workflow also boots a fresh iPhone simulator, runs the visual tests, exports PNG attachments,
and uploads `ios-catalog-visual-tests` including the full xcresult and test log. Screenshot names
are recorded in the exported `manifest.json`. Failure captures are retained too; a screenshot
alone is not proof a test passed. The unauthenticated launch smoke is a separate, much narrower
process-survival check, and its screenshot must also be visually inspected.

## Scope

The suite checks Home and its combined movie/episode Continue Watching inputs, Home scrolling,
Movies and TV Shows tabs, loaded dynamic artwork, movie/TV detail navigation and TV episodes,
Search text input/results/detail navigation, native navigation-stack retention, My List filtering,
and no catalog backdrop in Settings. It saves named screenshots for review.

It does not play an AllDebrid file, write to Simkl, validate live provider availability, authenticate,
or prove exact resume after an actual engine seek. Physical-iPhone checks still include video
readiness/resume, pause/background/interruption recovery, AirPlay/PiP, real Simkl synchronization
and cross-device API behavior, touch feel, image transition smoothness/flicker, Reduce Motion,
Dynamic Type, VoiceOver, smaller screens and hardware performance. Existing unit tests cover
progress persistence/conflicts and title/episode matching independently of these visual fixtures.
