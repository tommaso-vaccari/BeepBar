# Privacy release gate — issue #180

Status: **OPEN; draft remediation, not a GDPR compliance declaration.** Baseline: dev `039dc4092d29c23682ee3a8e802f40923af6ffce`, reviewed 2026-10-17. This PR targets dev. Do not release through #150 until the blockers below are resolved and the final binary is verified.

## Decisions already recorded

- Keep telemetry enabled by default if a lawful implementation can be demonstrated; preserve opt-out. Downloading the app is not consent.
- Minimize telemetry: remove language and all settings from outgoing signals. The existing monthly random hash remains pending the decision below; it is not proven anonymous.
- Public privacy contact is in [the draft notice](privacy-notice.md).
- Preserve automatic WeBeep profile-email behavior and study choices until explicitly erased.
- Owner approved on 2026-10-17: saved Polimi sessions expire ten days after initial save (updates do not renew the deadline); exclude token/session files from future macOS backups. Existing backups remain. Expired files are removed while running or at the next launch; no process can erase files while the app is closed.
- Owner approved on 2026-10-17: add per-account study erasure preserving downloaded materials; show and retry physical history deletion failures.

## Scope update — 2026-10-17

The owner explicitly waived additional packaged-app network, backup, expiry and erasure checks for this PR. They are **not performed**, not passed. Existing automated tests, Release build and static review remain valid evidence within their limits; the waiver does not establish legal compliance. References below to packaged verification are residual evidence gaps, not work authorized for this iteration.

The owner confirmed Tommaso Vaccari as the individual publisher/privacy request handler and approved deletion of support/privacy correspondence within 90 days after closure, except documented legal obligations or disputes. This does not approve unresolved lawful bases, provider roles or transfers.

Use public provider documentation for this iteration; do not contact TelemetryDeck. FAQ review is complete. Open provider questions remain documentary limitations rather than a pending outreach task.

## Owner decisions and external evidence

| Blocker | Concrete next step | Completion evidence |
| --- | --- | --- |
| Default-on telemetry (C08) | Obtain a documented assessment of GDPR basis and Italian ePrivacy/terminal access for this exact native implementation. Legitimate interest requires necessity and balancing; it does not bypass ePrivacy. Compare monthly identity against daily/random-per-event counting, no telemetry, and opt-in. | Approved assessment naming payload, purposes, identifiers, IP processing, retention, safeguards and applicable exemption; otherwise opt-in before sending. |
| Provider (C08) | Public FAQ/agreement/anonymization documentation reviewed; owner chose no provider contact. Account-specific accepted terms and coverage of the direct API remain unverified. Keep these limits visible in the assessment; no outreach task is authorized. | Written provider evidence plus role assessment; Article 28 agreement only if processing is actually on behalf of the publisher. |
| Local session lifetime/backups (C02/C05) | Approved and implemented: ten-day session lifetime, token/session backup exclusion. Token remains until disconnect/revocation; it is separate from the Polimi cookie session. | Boundary/replacement/startup tests; verify backup behavior and wake/clock behavior in the packaged app. |
| Local study data (C03/C06) | Approved and implemented: per-account erasure of watchlist, viewing state and resume points; closes playback and preserves materials. Persistent warning/retry for physical history deletion failures. | Regression coverage; verify Settings confirmation and failure/retry UI in the packaged app. |
| Publisher and support (C01/C09) | Individual publisher/request handler and 90-day correspondence retention are confirmed. Approve the remaining IT/EN notice, incident procedure and processing-specific roles/bases. | Signed/date-stamped owner decisions; no blanket assumption that university, Webex and publisher share one role. |

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

## Default-on assessment — working conclusion

Purpose: measure adoption and supported app/OS versions to guide maintenance. Current implementation sends a daily event with a monthly random identifier hash; it is not needed to sync courses or play recordings. Minimization and opt-out reduce impact but do not by themselves establish necessity or an ePrivacy exemption. Monthly linkage serves monthly-user counting; daily/per-event identifiers, opt-in and no analytics are less intrusive alternatives and have not been ruled out by a documented necessity assessment.

Public evidence reviewed again on 2026-10-17:

- [Privacy FAQ](https://telemetrydeck.com/docs/guides/privacy-faq/): provider states IPs are not stored, identifies EU hosting, and makes no guaranteed cold-storage deletion commitment; closing the customer account retains analytics. These are published provider statements, not independently verified behavior.
- [Anonymization explanation](https://telemetrydeck.com/docs/articles/anonymization-how-it-works/): describes client-side salting/hashing and a second server-side salted hash. BeepBar hashes app ID plus a monthly random UUID in its own direct API client. Server behavior for this client has not been independently demonstrated.
- [Supplemental agreement](https://telemetrydeck.com/dpa/): guarantees and scope describe the SDK; collection and preprocessing lawfulness remain the publisher's responsibility. Its anonymity/role position is a provider position, not a conclusion about all BeepBar processing.

Conclusion: the public documentation supports a factual disclosure, but does **not** close C08 for this exact implementation. Do not label the monthly identifier anonymous, infer consent from installation, or claim that default-on is legally established. Preserve the requested default-on behavior in the draft; release requires a substantiated basis and terminal-access assessment, or a separate owner decision to require prior opt-in/disable telemetry. No provider contact is planned in this iteration.

## Purpose, necessity and balancing record — 2026-10-17

The publisher confirmed that the actual use of telemetry is adoption measurement and maintenance/compatibility planning. This records the purpose; it does not predetermine the lawfulness assessment. Candidate GDPR basis, to the extent personal data are processed: Article 6(1)(f), subject to the tests below. An ePrivacy exemption requires a separate assessment and cannot be supplied by this GDPR basis.

| Test | Concrete assessment | Result |
| --- | --- | --- |
| Purpose | Count active installations and understand deployed app/macOS versions to prioritize compatibility work. No advertising, user scoring or course-content analysis is proposed. | Specific maintenance purpose confirmed by publisher. |
| App/OS versions | Counts by app and major OS version can inform release support. Language and settings were removed; precise OS builds are unnecessary. | Limited metadata is relevant; this alone does not justify identifiers or default-on. |
| Daily frequency | At-most-daily reporting limits volume and supports daily activity counts. Less frequent reporting would reduce traffic but provide less current counts. | Proportionate frequency is plausible; reliability and representativeness are not guaranteed. |
| Monthly identity | Deduplicates active installations within a calendar month. It does not directly identify a person or reliably count people; multiple installations and clock changes affect counts. | Technically justified for installation-weighted monthly compatibility counts: repeated daily activity must not increase an installation's weight. This establishes utility and the failure of event counts as an equivalent measure, not the necessity of every retained event or a positive legal conclusion. |
| Alternatives | Per-event random identity gives event counts; daily identity gives daily-installation counts; opt-in gives statistics from volunteers; no telemetry permits maintenance using bug reports and public compatibility information. | Alternatives remain viable. Owner preference for default-on and complete counts does not itself establish necessity. |
| Impact and expectations | Small metadata payload, monthly rotation and opt-out reduce impact. Persistent linkage within a month, source IP in transit, small cohorts and archived event retention remain risks; installation/update is not consent. | Favorable safeguards exist; anonymity and a positive balancing conclusion are not established. |
| Safeguards | No account/course/file/settings payload, no advertising purpose, restricted app-specific hash, ephemeral transport and opt-out deletion of local identity. Provider states IPs are not stored. | Implemented client safeguards plus attributed provider claims; server-side implementation not verified. |
| Italian analytics exemption | Garante guidance requires aggregate statistics for the relevant app, reduced identification and limits on third-party combination/onward use. Applicability to this native macOS client and actual provider restrictions must be substantiated. | Public anonymity assertions alone do not demonstrate all conditions. |

**Decision for this draft:** retain the explicitly requested default-on behavior; do not treat this record as consent, an approved positive legitimate-interest assessment or a closed exemption finding. The unresolved questions are whether monthly deduplication is necessary for the confirmed maintenance purpose and whether this exact third-party/native implementation meets the analytics exemption conditions. Reducing linkage can improve the assessment but cannot alone prove the exemption. No legal approval or release authorization has been inferred from the publisher's purpose confirmation.


## Further necessity analysis and provider evidence — 2026-10-17

The concrete engineering interest is to allocate compatibility testing and version support according to active installations rather than launch frequency. Synthetic counterexample: one installation on OS A reporting on 30 days and one on OS B reporting once produce event shares of 30/31 and 1/31, although installation shares are 1/2 each. This is an illustrative calculation, not production evidence. Summing daily unique counts has the same problem; daily totals cannot recover the monthly union without linkage or a different protocol. Download counts include inactive copies and repeat downloads. Bug reports measure reported failures rather than the installed version distribution. Opt-in statistics can have participation bias, but bias alone does not establish lawful necessity or justify ignoring objections. Monthly identifiers therefore have a genuine technical justification for this metric; describing them as useful only for convenience would understate that justification.

The current protocol is not shown to be the least intrusive equally effective option. For monthly installation counts alone, one report per installation per month, with local suppression and no recurring server identifier, is a relevant alternative. It loses within-month version changes and daily unique counts; those additional objectives need their own necessity argument. Failed sends, offline installations, reinstalls, opt-out and clock behavior also limit accuracy. Do not describe the current counts as complete or unbiased. No maintenance thresholds, actual support decisions or provider account settings have been invented.

Additional public sources checked:

- [Architecture and security overview](https://telemetrydeck.com/use-case/architecture-security/) states that customer data are separated by namespace and user identifiers are not handed over for tracking across external platforms. These support isolation and restricted use, but do not independently establish every condition of the Italian third-party analytics exemption. Several security sections are questions rather than documented answers.
- The same overview advertises one-time or automatic deletion by arrangement. This improves the available remediation path, but does not establish an enabled retention policy for this account or resolve the privacy FAQ's lack of a guaranteed cold-storage deletion deadline. No deletion arrangement has been requested or assumed.
- [Garante cookie FAQ, questions 4–5](https://www.garanteprivacy.it/faq/Cookie) explicitly allows qualifying minimized analytics without consent, including third-party analytics subject to limits on combination and onward disclosure. This is a conditional exemption, not a blanket requirement that all analytics be opt-in, nor proof that this particular native integration qualifies.

Assessment outcome: a concrete maintenance interest and a technically valid monthly deduplication rationale are documented. A positive finding on the whole default-on implementation is still unsupported because purpose-limited retention, necessity of recurring events and the conditions for third-party terminal-access exemption remain unresolved. Client-side hashing and the provider's claim of anonymous processing cannot substitute for that assessment. Further rewording of this record alone cannot resolve missing service/configuration evidence. Default-on remains in the draft, with C08 open; this is not approval for release.


## TelemetryDeck-only remediation package — 2026-10-17

Owner constraint: retain TelemetryDeck, default-on and opt-out. A replacement service or self-hosted collector is not the selected solution. No change to daily/monthly metrics is assumed. Application code remains unchanged from the validated code commit; this section is a concrete evidence/contract proposal, not a positive legal opinion.

The direct client uses the documented v2 ingest endpoint. That supports technical compatibility; it does not prove the supplemental agreement's SDK-specific warranties apply to it. Neither changing to the SDK nor accepting provider anonymity language automatically resolves terminal-access lawfulness. A full independent server audit is not assumed mandatory: applicable contractual assurances and sufficiently specific technical documentation can be evidence. The unanswered question is their scope for this client, not a demand to prove every server operation independently.

### Conditions to resolve with the existing provider

1. Preserve a record of the applicable account terms. Establish whether the binding [German supplemental agreement](https://telemetrydeck.com/avv/) and its Sections 3 and 5 cover this direct API client, including server hashing, hourly timestamps, IP handling and infrastructure access. Its Section 2 denies an Article 28 processor role; do not call this an Article 28 DPA merely because of its page title. If identifiable data are actually processed, assess the factual role and obtain the corresponding agreement instead of relying on labels.
2. Obtain applicable restrictions against identifying users, combining these events with other customers or external datasets, independent secondary use, and onward disclosure beyond service infrastructure under appropriate guarantees. Namespace isolation alone is not equivalent to all these restrictions. Assess the answer against the Italian exemption rather than treating a generic GDPR assurance as an exemption decision.
3. Request a concrete retention arrangement: proposed maximum 90 days for linkable events, including archives, with a documented backup expiry or irreversible anonymization deadline. The proposed term is not active or owner-approved. It covers up to three calendar-month maintenance comparisons; a longer horizon should use genuinely non-identifying aggregates with small-cohort safeguards. No absolute numerical threshold guarantees anonymity. Provider feasibility, scope, cost and the purpose justification must be recorded before selecting a term.
4. Complete a single processing-specific legitimate-interest assessment for collection/transmission and a separate terminal-access exemption analysis using that evidence. Explicitly assess the monthly deduplication rationale, alternatives, daily frequency, retained versions, small cohorts, objections and prior notice. Provider agreement alone cannot make this legal assessment positive. Request qualified privacy review of the exact configuration and evidence if the native exemption remains uncertain; no paid engagement is authorized here.

### Ready-to-send provider request — NOT SENT

Subject: BeepBar — direct Ingest v2 privacy guarantees and bounded retention

We use TelemetryDeck for maintenance and compatibility statistics in a native macOS app, with default-on reporting and an opt-out. Before relying on this configuration, we need confirmation specific to the following direct API client, rather than a general compliance statement.

Our app sends at most one best-effort request per UTC day to your documented v2 namespace endpoint. Each event contains appID, type BeepBar.dailyActive, clientUser = SHA256(appID + ':' + a randomly generated installation UUID that is independently replaced each UTC calendar month), and only app version, platform macOS, operating system macOS and major macOS version in payload. No account ID, email, device identifier, course, file, language, settings, session ID or custom timestamp is sent. Disabling stops future sends and removes the local UUID. Requests use an ephemeral HTTP session without cookies, credentials, cache or redirects. The server necessarily receives a connection IP.

Please confirm or correct each point and identify the applicable contractual clause or technical documentation:

- Do your current supplemental agreement and anonymization/security warranties cover this direct v2 client? Which terms apply to our account, and how can we retain evidence of their applicability?
- Does this endpoint apply server-side salted hashing, timestamp rounding, and the published no-IP-storage policy across ingestion, logs and infrastructure? What additional fields, location information or identifiers are derived or retained for this path?
- What binding restrictions cover identification, combination with external/customer datasets, independent secondary use, and disclosure to additional recipients? Please distinguish service infrastructure from other recipients and explain the applicable role for any personal data before anonymization.
- Can we configure or agree to deletion or irreversible anonymization of linkable events after at most 90 days, covering cold storage and a stated backup expiry? Please state any exceptions, available aggregate-only retention, activation evidence and cost. This is a proposed arrangement, not a request to delete existing production data or enable a paid feature.
- Please supply the relevant technical and organizational measures and describe the treatment of previously collected events separately from future configuration.

We are assessing Italian analytics-exemption conditions as well as GDPR legitimate interest. We are not asking you to certify our app's overall compliance; we need facts and enforceable guarantees applicable to this configuration.

### Stop condition for this iteration

The public-document-only scope has been exhausted for the questions above. This request is prepared but not sent because the owner previously prohibited provider outreach. No account settings, contractual acceptance, deletion policy, budget or legal-review engagement has been changed. A later authorization to use TelemetryDeck does not by itself revoke that outreach restriction. C08 stays open until the missing evidence and the application-specific legal assessment support closure; a negative or incomplete answer must remain visible.
