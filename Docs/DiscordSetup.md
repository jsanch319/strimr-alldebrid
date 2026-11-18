# Optional Discord Watch Together

The feature-branch IPA from run `44117857904` (commit `ebcbb42`) was inspected:
its generated `Info.plist` contained neither `DiscordApplicationClientID` nor
`DiscordActivityURL`. That IPA cannot enable the feature. The GitHub connection
cannot read repository Actions variables (HTTP 403), so their presence is not inferred.

Details now show setup information when configuration is absent. The native player
continues to hide its optional Discord button when unconfigured, avoiding setup
popups during ordinary AllDebrid playback. Configured movie/episode details expose
the existing Discord launch action; a successful URL handoff does not certify the
Activity is deployed or that playback synchronization works.

1. Create a real Discord application and deploy its Discord Activity on HTTPS.
2. Configure the Activity URL mappings and required Discord application settings
   in the Discord Developer Portal. Use the actual public application/client ID.
3. Set repository Actions variables `DISCORD_APPLICATION_CLIENT_ID` and
   `DISCORD_ACTIVITY_URL`, or set these build settings locally. Do not embed an
   OAuth client secret, AllDebrid key or other private credential.
4. Workflows run `Scripts/configure_discord.py` to validate the optional public
   settings and escape `//` as `/$()/` for xcconfig. Otherwise HTTPS URLs can be
   truncated as xcconfig comments. Missing/invalid settings remain empty.
5. The iOS source plist explicitly expands both build settings. The IPA workflow
   uploads `discord-configuration.json`, auditing the actual generated plist.
   `syntax_configured: true` is not proof of deployment: `deployment_verified`
   remains false until a real Discord Activity is tested on a signed device.

Discord is not required for AllDebrid playback. No placeholder production
credentials, hosted Activity or new backend are supplied by this change.
