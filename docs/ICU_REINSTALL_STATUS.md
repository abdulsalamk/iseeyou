# I See You reinstall — 30 October 2026

- Corrected icon display name to I See You 1.2; bundle ID remains com.iseeyou.research.
- Renewed local signing profile expires 6 November 2026 and includes the physical iPhone.
- User trusted the developer certificate; app launch succeeded afterward.
- Complete UnitChecks on the physical iPhone succeeded: 51 passed, 0 failed, 1 skipped (52 total). Candidate benchmark skipped because no shadow candidate was staged. Result: /private/tmp/iseeyou-trusted-tests-20261030.xcresult.
- Restored normal signed Release app after testing; installation and launch succeeded. Bundled display name verified as I See You 1.2.
- Phone distance calibration matched the pre-install backup byte for byte after final installation. No glasses calibration file was found before installation.
- Earlier Release test compilation attempts failed because tests use DEBUG-only helpers; successful full run used the intended Debug configuration.
- Existing unrelated infra/teacher/learning.tf work preserved. No AWS deployment, training or cloud app build performed. Real-world recognition accuracy was not evaluated.
