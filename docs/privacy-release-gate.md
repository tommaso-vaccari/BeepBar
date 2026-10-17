# Privacy release gate — issue #180

Status: **OPEN; draft remediation, not a GDPR compliance declaration.** Baseline: dev `039dc4092d29c23682ee3a8e802f40923af6ffce`, reviewed 2026-10-17. This PR targets dev. Do not release through #150 until the blockers below are resolved and the final binary is verified.

## Decisions already recorded

- Keep telemetry enabled by default if a lawful implementation can be demonstrated; preserve opt-out. Downloading the app is not consent.
- Minimize telemetry: remove language and all settings from outgoing signals. The existing monthly random hash remains pending the decision below; it is not proven anonymous.
- Public privacy contact is in [the draft notice](privacy-notice.md).
- Preserve automatic WeBeep profile-email behavior and study choices until explicitly erased.
- Owner approved on 2026-10-17: saved Polimi sessions expire ten days after initial save (updates do not renew the deadline); exclude token/session files from future macOS backups. Existing backups remain. Expired files are removed while running or at the next launch; no process can erase files while the app is closed.
- Owner approved on 2026-10-17: add per-account study erasure preserving downloaded materials; show and retry physical history deletion failures.

## Owner decisions and external evidence

| Blocker | Concrete next step | Completion evidence |
| --- | --- | --- |
| Default-on telemetry (C08) | Obtain a documented assessment of GDPR basis and Italian ePrivacy/terminal access for this exact native implementation. Legitimate interest requires necessity and balancing; it does not bypass ePrivacy. Compare monthly identity against daily/random-per-event counting, no telemetry, and opt-in. | Approved assessment naming payload, purposes, identifiers, IP processing, retention, safeguards and applicable exemption; otherwise opt-in before sending. |
| Provider (C08) | Verify terms accepted for the actual account and ask whether the direct Ingest API receives the same protections as the SDK; request IP handling, cold-storage deletion, hosting/access/transfer details and anonymization/security evidence. Do not send this request without authorization. | Written provider evidence plus role assessment; Article 28 agreement only if processing is actually on behalf of the publisher. |
| Local session lifetime/backups (C02/C05) | Approved and implemented: ten-day session lifetime, token/session backup exclusion. Token remains until disconnect/revocation; it is separate from the Polimi cookie session. | Boundary/replacement/startup tests; verify backup behavior and wake/clock behavior in the packaged app. |
| Local study data (C03/C06) | Approved and implemented: per-account erasure of watchlist, viewing state and resume points; closes playback and preserves materials. Persistent warning/retry for physical history deletion failures. | Regression coverage; verify Settings confirmation and failure/retry UI in the packaged app. |
| Publisher and support (C01/C09) | Confirm who determines telemetry/support purposes and approve the complete IT/EN notice, support retention (proposed: 90 days after closure), incident owner and rights procedure. | Signed/date-stamped owner decisions; no blanket assumption that university, Webex and publisher share one role. |

## Finding ledger

| Finding | Delivered in this branch | Remaining gate |
| --- | --- | --- |
| C01 transparency | In-app factual data screen/contact; bilingual notice draft | Roles, lawful bases, retention and publication before processing; draft is not a finished Article 13 notice |
| C02 local secrets | Restrict existing session folder; fail closed on token-folder permissions; attempt all secret-file deletions despite failures | Final packaged backup/expiry verification and data inventory |
| C03 deletion | Persistent failed-session deletion, visible retry, truthful logout residues | Full local cleanup usability and rights exercise |
| C04 updates | Correct README opt-in contradiction; disclose default-on eight-hour checks | Verify runtime request/redirect recipients, Sparkle system-profile settings and distribution-provider retention |
| C05 recordings/email | Explain automatic email use and university/Webex connections | Full identity-provider chain, necessary cookie scope/lifetime, provider roles |
| C06 study data | Per-account erasure, persistent history deletion warning/retry and cleanup guidance | Packaged erasure verification; complete current/legacy persistence inventory |
| C07 diagnostics | Static log audit; browser traces omit paths/query/userinfo/fragments, login-item errors omit free text | Synthetic runtime packet capture and OS/provider diagnostics verification; no absence-of-leak claim |
| C08 telemetry | Language/settings omitted; opt-out effects accurately described | Default-on basis/ePrivacy, provider evidence and historical signals |
| C09 operations | Rights/incident runbook and contact | Owner approval, mailbox/security arrangements, dry run, proportional ROPA/DPIA/DPO assessment |

## Evidence required on final release SHA

- Focused regressions, full `swift test`, Release Xcode build, independent review, green PR CI on the final SHA.
- Synthetic runtime network trace: first launch before any choice; disabled telemetry; updates; login, profile lookup and Webex; opt-out in flight; logout/relaunch and deletion errors. Do not use real accounts or transmit production telemetry.
- Verify the static [persistence inventory](privacy-operations.md#persistence-inventory) against the final packaged app, including OS/provider-managed retention.
- Attach provider evidence, lawful-basis/ePrivacy conclusions, owner decisions and approved notice. Publish the website notice only as part of the authorized release, in its separate repository.
- Reconcile wiki snapshots with final source/binary. No merge, release, installed-app change, production signal, provider message or real-data inspection was performed by this task.

## Current sources, checked 2026-10-17

[EDPB legal bases](https://www.edpb.europa.eu/sme/be-compliant/process-personal-data-lawfully_en): consent requires affirmative informed choice; legitimate interest needs a concrete necessity/balancing assessment. [EDPB final Guidelines 2/2023](https://www.edpb.europa.eu/documents/guideline/guidelines-22023-on-technical-scope-of-art-53-of-eprivacy-directive_en) concern access/storage on terminal equipment, not only browser cookies. [Garante 10 June 2021](https://www.garanteprivacy.it/home/docweb/-/docweb-display/docweb/9677876) sets conditions for analytics treated as technical tools; applicability to this native implementation is an open assessment, not an automatic exemption.

[TelemetryDeck supplemental agreement](https://telemetrydeck.com/dpa/) describes SDK use and treats its service as anonymous, outside processor/joint-controller roles; the publisher remains responsible for lawful collection/configuration. Its title alone does not prove an Article 28 contract or that this custom client is covered. [Provider FAQ](https://telemetrydeck.com/docs/guides/privacy-faq/) says IPs are not stored, lists EU hosting, and gives no guaranteed cold-storage deletion deadline. These are provider claims, not account-specific verification; three months of dashboard access is not retention. [Ingest API](https://telemetrydeck.com/docs/ingest/v2/) supports direct clients. Sources and provenance are indexed in the compliance wiki.
