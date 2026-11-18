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

## FaceTime launch failure: signing preflight and diagnostics

The previous unsigned audit (`signed=null`, `profile=null`, runtime unverified)
means **unknown**, not proof of either a valid final signature or a missing
entitlement. It cannot diagnose a FaceTime crash. The final SideStore-signed app
and a matching device crash report were not available for this investigation.
No FaceTime process crash has been reproduced or attributed to a specific cause.

Code review found unguarded invitation-controller construction and an activation
reservation ending before asynchronous session delivery. The iOS preflight now
reads the installed thin Mach-O executable's XML entitlement blob and embedded
provisioning profile before constructing a native invitation, querying eligibility,
starting the session listener, preparing, activating, or accepting a session.
Both must explicitly grant `com.apple.developer.group-session`. Absent, stripped,
unknown, malformed, DER-only/unsupported evidence and simulator builds fail closed
with an informative message. These read-only parsers use Foundation, not private
entitlement APIs. They do not authenticate CMS, add entitlements, certify profile
expiry, or replace iOS signature enforcement. Conservatively, a distribution with
no embedded profile will also be blocked and needs a supported signing-verification
path before enabling SharePlay; profile presence alone never enables it.

Use the audit command above against the **exported final SideStore-signed app**,
not the GitHub unsigned IPA. Confirm the final bundle ID, certificate/profile
validity, entitlement presence in signature and profile, and matching application
identity on both phones. Apple-account/provisioning restrictions may prevent
SharePlay in a particular signing configuration. Strimr cannot grant that access.
Do not modify profiles or inject unauthorized entitlements to bypass the check.

One main-actor launch guard now spans invitation creation, activation and waiting
for a session. Rapid taps and other details surfaces cannot start a second launch.
Cancellation/error introduces a two-second cooldown; accepted launches wait at
most 60 seconds for session delivery before reporting unavailability. There is
no automatic activation retry. Dismissal without a completed result releases the
reservation. Invalid titles, non-finite/negative clocks and mismatched catalog
identity are rejected before GroupActivities. Framework errors are not logged
verbatim. Swift errors cannot catch a crash in FaceTime's separate process.

### Collect only the necessary evidence

1. Note the local failure time, iOS and Strimr build versions, whether FaceTime was
   already in a call, and the last visible UI. Avoid repeated attempts if FaceTime
   crashes. Ordinary playback remains available without SharePlay.
2. On iPhone, open Settings → Privacy & Security → Analytics & Improvements →
   Analytics Data. Look near that time for a FaceTime report, Strimr report, or
   a jetsam report. Alternatively use Xcode → Devices and Simulators → device →
   View Device Logs on a trusted Mac. A sheet disappearing alone is not evidence
   of a process crash; jetsam is also different from an exception crash.
3. Inspect the report's actual process name/path, timestamp, Exception Type,
   Termination Reason and crashed-thread stack. A FaceTime-process report supports
   a FaceTime crash; a Strimr report supports an app crash. No matching report
   leaves the distinction unresolved. Do not assume that opening FaceTime proves
   activation or joining succeeded.
4. In macOS Console, select the connected iPhone, enable Info messages and filter
   subsystem `app.strimr.shareplay`, category `Launch`. Stages are `preflight`,
   `listener`, `invitation` (constructing/visible/completed/cancelled/dismissed),
   `preparation`, `activation`, `session_access` and `session_join`. They contain no
   media title, playback URL, account, activity UUID, source configuration or token.
   `session_join=requested` is an API call, not proof peers connected successfully.
5. Share only these filtered events and necessary exception/stack excerpts. Remove
   device identifiers, account/phone/email details, paths containing usernames,
   invitation URLs, authorization headers and playback/add-on URLs. Avoid uploading
   a full sysdiagnose or unredacted crash report to a public GitHub PR.

Regression coverage checks the signing truth table, malformed/truncated executable
and profile evidence, missing capability, invalid activity metadata, launch
reservation/cooldown and stale dismissal ownership. Builds/tests cannot establish
FaceTime service health or final SideStore authorization. Required device tests:
blocked signing causes no sheet/activation; valid signing can invite outside and
inside FaceTime; rapid taps, cancellation, late session delivery, joining/leaving,
backgrounding and post-failure retry. Collect crash evidence before calling this
an actual FaceTime-crash fix. Existing AirPlay/LG verification remains separate.
