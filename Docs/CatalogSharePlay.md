# Catalog SharePlay on iPhone

Movie and selected-episode details expose Apple's `shareplay` action beside Select
Source and Watch Trailer (the actions wrap on narrow screens). In FaceTime the
existing coordinator activates the activity; otherwise the native Group Activity
sharing controller supplies the invitation flow. Invitation presentation lives at
the app root so details layout/rotation cannot create a second invitation.

The existing StrimrWatchActivity / SharePlayCoordinator / AVPlaybackCoordinator
remain the session and transport owners. A new optional catalog identity carries
only TMDb ID, media kind, exact season/episode, activity ID, title and initial time.
No resolved stream URL, AllDebrid credential or add-on configuration is shared.
Legacy server activities remain decodable and retain their existing path.

Each iPhone loads TMDb metadata and uses its own connected AllDebrid library and
configured authorized add-ons. A participant without an accessible source sees
the ordinary source setup/availability interface. Episodes are resolved from the
shared show's actual season metadata. A private local/Simkl resume cannot replace
the group's advertised initial position. Source editions/cuts must correspond;
GroupActivities cannot make different edits of an episode align perfectly.

Joining/leaving, participant changes, play/pause/seek coordination and late media
loading reuse the original coordinator. Explicitly closing the party leaves it;
a changed catalog activity resolves a new local source without sending the old
URL or deliberately leaving the group. The catalog invitation UI is implemented
on iOS; it does not advertise continuation of catalog activities on tvOS.

## SideStore and signing

The project already declares `com.apple.developer.group-session = true` in the iOS
entitlements. The SideStore workflow builds with `CODE_SIGNING_ALLOWED=NO` and
packages an **unsigned** IPA. The declaration and a successful build are not proof
that FaceTime/SharePlay will work after SideStore re-signing. Both participants
need compatible app/activity identifiers and properly signed apps whose valid
provisioning permits Group Activities. FaceTime must be available and enabled.
Do not invent credentials, bypass signing restrictions or assume a signing tool
preserves an entitlement that its provisioning profile does not authorize.

The workflow exports `shareplay-configuration.json`. Its signed/profile values
remain unknown for an unsigned artifact and runtime verification is always false.
It exports no profile contents, team/account fields or credentials. On macOS,
extract the actual re-signed IPA and run:

```sh
python3 Scripts/report_shareplay_configuration.py Payload/Strimr-iOS.app /tmp/shareplay-configuration.json
codesign --verify --strict Payload/Strimr-iOS.app
```

The audit reports entitlement presence only; it does not certify profile expiry,
certificate trust, Apple account eligibility, bundle-ID compatibility or actual
FaceTime operation. A SideStore profile that strips/does not grant the entitlement
cannot be called SharePlay-compatible. The app shows a setup/unavailable error
rather than pretending it has started a working party.

## Checks requiring signed iPhones

Use two signed iPhones with FaceTime and independently authorized sources. Test
inviting outside a call and starting during an existing call; movie and exact
series/season/episode identity; private resume different from host position;
play, pause and seek; late joining and temporary participant disconnection;
leaving while the other participant continues; next/shared title changes; missing
sources and denied signing/FaceTime eligibility. Verify Simkl/Continue Watching
per account and English audio per device. Test AirPlay to the LG separately and
in combination with SharePlay. No physical FaceTime pair or LG receiver was
available here; neither simulator builds nor entitlement declarations prove those
flows work on the user's re-signed app.
