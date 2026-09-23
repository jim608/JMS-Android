# Workspace instructions

Follow `C:\Users\a0659\.codex\RTK.md`. Use RTK and narrow searches. Keep progress, evidence, blockers and handoff in `docs/JMS_STATUS.md`; resume from that record. Preserve upstream licenses and do not modify production media, servers, accounts or viewing records.

## Conditional JMS release authorization (2026-09-20)

The user authorizes reviewed JMS source commits, non-force pushes, tags and complete Releases/Prereleases exclusively to `jim608/JMS-Android`. This supersedes older no-publish restrictions for this repository only; historical milestone records describe past actions, not current authorization.

After the user's specified JMS changes are complete, if a genuinely new version is releasable and all release checks pass, Codex must run `scripts/publish_jms_android.ps1`, upload the complete release and verify anonymous downloads. Do not stop at a local APK or ask for upload authorization again. If a gate fails, stop remote writes and report the specific evidence and minimum remedy.

- Ordinary edits, tests and `flutter build` must never trigger publishing. No continuous development, polling or background publishing.
- Keep `com.jim608.jms`, the existing compatible signer and local-only private key custody. Never generate/substitute a key, expose credentials, operate phones or clear data.
- Default to prerelease until documented device acceptance permits stable. Public prereleases require the same signature, secret, test and licensing gates as stable releases.
- Use draft → upload all materials → verify → publish → anonymous verification. Never publish an incomplete release, replace published assets, reuse a versionCode or retag an existing release.
- Preserve upstream remotes. Push only the checked source snapshot/history to the fixed JMS target; never blindly stage the worktree, push upstream, force-push or upload unrelated/private files.
- Reuse unchanged signature/dependency evidence only after checking bound hashes. Unknown custody, incompatible licenses, missing corresponding source or failed tests remain blocking; authorization is not a waiver.
- Resume interrupted runs from saved release state, without duplicate builds/uploads. See `docs/JMS_UPDATES.md` for the single entry point and evidence format.

## Public release copy

- Compare the previous public JMS release with the actual new APK/source. Record only that version's user-visible changes under `# JMS <version>` in `CHANGELOG.md`, using nonempty applicable sections from `新增`, `調整`, `修正`, `移除`, `已知問題`, `更新注意事項` in that order.
- Write complete, factual Traditional Chinese sentences. Do not copy development status, chat instructions, PASS/FAIL/BLOCKED labels, local paths, secrets, placeholder text or old features into the new release description. Record historical errors as errata, without claiming older binaries were corrected.
- Generate `docs/JMS_RELEASE_NOTES.zh-Hant.md` from the matching changelog entry with `python scripts/jms_release_notes.py --version <actual-version> --write`. The publisher checks exact equality and uses that one text for the GitHub Release body and packaged notes; the App reads the same GitHub body for update details. The title is `JMS <actual-version>` from APK metadata.
- Keep `README.md` current for installation, update source, point/request setup, compatibility and licensing. A formal tone does not promote a Prerelease to stable or waive device validation.
