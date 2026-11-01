# Development workflow

## Token-efficient development

- Minimise token consumption while maintaining code quality.
- Read only files relevant to the current task.
- Do not repeatedly scan the entire repository.
- Do not read generated files, build outputs, large datasets or lengthy logs unless necessary.
- Use targeted searches and limit command output.
- Make the smallest changes required.
- Avoid unnecessary refactoring and repeated explanations.
- Run focused tests first.
- Stop after three unsuccessful debugging attempts and report the blocker.
- Provide a concise summary of changes, tests and remaining issues.
- Preserve progress through Git commits and a short project status file.
- Do not start additional tasks without approval.

The user has reverted to local development to avoid cloud deployment overhead.

- Edit, build, sign and install using the user's Mac and Xcode. Use a physical iPhone, not a simulator.
- Do not start Codex Cloud tasks, GitHub-hosted builds, deployment watchers or recurring monitoring unless the user explicitly requests them again.
- The iOS cloud-build and deployment-bridge-check workflows are disabled in repository settings. Keep them disabled. Existing iPhone cloud deployment scripts are historical and must not be started automatically.
- The user separately authorized AWS Terraform bootstrap in London using local profile `abdul`, with an S3 state bucket and repository-scoped GitHub OIDC. A manual AWS connection-check workflow is allowed; this does not authorize restoring iPhone cloud builds, capturing images, or starting ML training/inference jobs.
- The Mac LaunchAgent `com.iseeyou.deploy` has been stopped and removed from login startup. Its private configuration is retained for recovery, not automatic use.
- The user subsequently authorized implementation of issue 3. The private S3/SQS/Lambda/Bedrock teacher pilot may be deployed and tested from this Mac using `abdul`; use synthetic fixtures for smoke tests. Do not capture personal camera images or start GPU training/model promotion implicitly.
- Keep GitHub as source control. Push authorized code changes normally; a push is not an instruction to deploy through the old cloud bridge.
- Check the selected checkout and branch before work. The user's original checkout is `/Users/abdulkunnummal/source/iseeyou`; other checkouts may have different commits or pending work. Preserve all changes.
- Preserve the installed bundle identifier and existing calibration. Do not claim model accuracy, reliable door/stair recognition, or locked-phone glasses operation without real-world verification.
- After every normal app/model installation on the physical iPhone, run the complete `UnitChecks` scheme on that same device before calling the install verified. Record pass/fail/skip counts and explain any skip; a successful build or launch does not replace this run. The test-runner installation itself is part of that verification and does not trigger recursive reruns.

The previous cloud-built release was successfully installed on the physical iPhone. Returning to local development does not require reinstalling that unchanged app.
