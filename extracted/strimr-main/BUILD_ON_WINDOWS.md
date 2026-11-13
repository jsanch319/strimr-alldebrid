# Build-check the experimental AllDebrid Strimr fork from Windows

This workflow **only compiles an iOS Simulator build** on a GitHub-hosted Mac. It does **not** generate an installable IPA or bypass Apple signing. It cannot prove that AllDebrid playback works. The fork is still experimental.

1. Create a new GitHub repository (prefer private while developing). GitHub Actions minutes for private repositories may be limited or billed depending on plan; check your account usage. Public repos expose committed source and workflow logs.
2. Upload the **contents** of the extracted `strimr-main` directory to the repository root (not the outer folder). Keep `.github/workflows/alldebrid-ios-check.yml` intact; browser upload may hide dot-folders, so GitHub Desktop or Git CLI is recommended.
3. In the repository open **Actions** > **AllDebrid iOS compile check** > **Run workflow**.
4. Open the job results. If it fails, download the `ios-compile-log` artifact and share it for troubleshooting. Remove tokens, API keys, or private links before sharing logs.

No API key is needed for compilation. Never put AllDebrid keys in GitHub files, Actions secrets for this check, or issue reports.

Note: The workflow uses `macos-15`. Xcode and iOS SDK compatibility depend on the GitHub runner image and upstream project requirements; a runner or SDK update may be needed. The original upstream workflow uses an `xcode-27` runner label that may not be available in your GitHub account.
