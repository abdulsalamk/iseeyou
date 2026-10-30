# ICU reinstall — 30 October 2026

- Icon display name changed to ICU 1.2; bundle ID remains com.iseeyou.research.
- Local Release build and physical iPhone installation succeeded. Provisioning profile expires 6 November 2026 and includes this device.
- Saved phone distance calibration was copied before and after installation and matched byte for byte. No glasses calibration file was found before installation.
- Launch remains blocked by iOS Security: invalid signature, inadequate entitlements or developer profile not explicitly trusted. User must check Settings → General → VPN & Device Management.
- Full UnitChecks attempted: Release test compilation failed because test helpers require DEBUG; Debug test run could not complete device launch. No passing test count is claimed.
- App installation is not yet verified end to end. After trust is resolved, rerun the complete UnitChecks scheme on this physical iPhone, reinstall the normal Release build, recheck calibration and launch.
- Existing unrelated infra/teacher/learning.tf work was preserved. No AWS deployment or model training performed.
