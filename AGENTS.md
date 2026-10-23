# Development workflow

The user has reverted to local development to avoid cloud deployment overhead.

- Edit, build, sign and install using the user's Mac and Xcode. Use a physical iPhone, not a simulator.
- Do not start Codex Cloud tasks, GitHub-hosted builds, deployment watchers or recurring monitoring unless the user explicitly requests them again.
- Both GitHub Actions workflows are disabled in repository settings. Keep them disabled. Existing cloud deployment scripts are historical and must not be started automatically.
- The Mac LaunchAgent `com.iseeyou.deploy` has been stopped and removed from login startup. Its private configuration is retained for recovery, not automatic use.
- Keep GitHub as source control. Push authorized code changes normally; a push is not an instruction to deploy through the old cloud bridge.
- Check the selected checkout and branch before work. The user's original checkout is `/Users/abdulkunnummal/source/iseeyou`; other checkouts may have different commits or pending work. Preserve all changes.
- Preserve the installed bundle identifier and existing calibration. Do not claim model accuracy, reliable door/stair recognition, or locked-phone glasses operation without real-world verification.

The previous cloud-built release was successfully installed on the physical iPhone. Returning to local development does not require reinstalling that unchanged app.
