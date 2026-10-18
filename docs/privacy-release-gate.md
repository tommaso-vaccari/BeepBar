# Privacy release gate — issue #180

Status: **Technical remediation delivered; legal/release gate OPEN. Not a GDPR compliance declaration.** Baseline: dev `039dc4092d29c23682ee3a8e802f40923af6ffce`, reviewed 2026-10-17. This PR targets dev. Do not release through #150 until the blockers below are resolved and the final binary is verified.

## Current implementation and reasoned assessment — 2026-10-18

This section supersedes the monthly-UUID analysis below. The product constraints are TelemetryDeck, at-most-daily reporting, minimal metadata, default-on and effective opt-out. The monthly **metric** is retained without a monthly installation **identity**. Only public sources are used; no provider contact, account change or production transmission is authorized. The owner also authorized merging #181 to dev **when the lawful-basis assessment is sufficiently supported**; this is conditional, not permission to waive an adverse finding or release to main.

### Concrete change: count locally, do not deduplicate people at the server

Every installation uses the literal public `clientUser = aggregate`. The first attempted report in a later UTC calendar month has type `BeepBar.monthlyActive.v2`; subsequent reports use `BeepBar.dailyActive.v2`. Both types count towards daily reporting installations; only the former counts towards monthly reporting installations. A monotonic local month marker prevents repeat counting and survives opt-out. Previous UUIDs are deleted even when telemetry is enabled. Failures consume the daily/monthly attempt; no retry queue is introduced. App and major OS versions remain the only variable payload fields. User-Agent and Accept-Language are fixed. See [protocol and limitations](telemetry.md).

This deliberately gives up server-side unique-user, funnel and individual-retention queries. Monthly figures are counts of first reporting attempts received, not an exact census: failed first attempts undercount, preference resets can overcount, and the month's version segment is the first-attempt configuration. Old UUID-based events remain in the provider's history; changing the client does not erase them or retroactively establish their lawfulness.

An IT/EN notice precedes the first enabled/configured launch, including upgrades. It explains the interest, purpose, optionality, data, recipient, provider retention statement and rights before request construction or scheduling. Continue is information acknowledgement, not consent; Disable persists opt-out without losing functionality. A scrollable text area keeps the full telemetry-specific information accessible. The separate all-processing [privacy notice](privacy-notice.md) is still a draft and is not silently approved by this runtime change.

### Article 6(1)(f): strongest supportable case for the changed protocol

**Purpose — supported.** Maintain compatibility and reliability by measuring the deployed app/major-OS combinations among currently running installations, including the first days after an update. This is the stated actual maintenance purpose, not advertising, personal profiling, a condition for synchronization or a claim that downloading is consent.

**Necessity — substantially strengthened.** A monthly first report describes configurations at their first observation, whereas a change-only report describes transitions, not the distribution still running on a particular day. Neither supplies the same daily compatibility-exposure measure. Weekly reporting loses observation windows after releases; sampling adds estimation uncertainty and is an alternative for later reassessment, not equivalent data. One attempt per UTC day is the chosen bounded observation resolution. Crucially, the new counter obtains the monthly measure without linking any installation's daily events: the previous necessity objection to recurring monthly identity is removed rather than justified with wording. No claim of invented maintenance decisions, numerical thresholds or measured production benefits is made.

**Balancing — favorable safeguards, residual risks recorded.** Reporting discloses no accounts, course activity, content, settings, individual identifier or client timestamps. It is optional, described before collection, subject to immediate opposition, and adds no queue or retry history. Students may be minors; the assessment does not presume adulthood. The receiver still processes the connection IP, event time and version combination; rare cohorts, historical UUID events and the provider's retained events remain relevant. The argument for Article 6(1)(f) is materially stronger because it no longer depends on individual tracking. It is a reasoned candidate basis for the identifiable collection/transmission, not a substitute for the separate terminal-access analysis or a declaration that all subsequent processing is anonymous.

Sources: [GDPR Articles 5, 6, 11, 13 and 21; Recitals 26 and 47](https://eur-lex.europa.eu/eli/reg/2016/679/oj), [EDPB lawful processing](https://www.edpb.europa.eu/sme/be-compliant/process-personal-data-lawfully_en). The test is reasonable necessity and proportionate balancing, not proof that analytics are indispensable to downloading lectures.

### Separate terminal-access / analytics test

The full [Garante guidelines, section 7.2](https://www.garanteprivacy.it/home/docweb/-/docweb-display/docweb/9677876), require reduced identifying power and identifiers that can refer to multiple devices, aggregate use confined to the publisher's service, and restrictions on combination and further disclosure. A third-party monthly unique UUID was a substantive difficulty; removing it addresses that condition directly. A literal shared value is not a unique device identifier, and local suppression avoids sending a history for server deduplication. This is stronger than merely rotating or hashing a unique ID.

Own-app aggregate purpose and absence of a cross-app individual join key are code-backed. Provider IP handling, retained metadata and downstream use are not all observable from this repository. Shared identity removes a concrete objection but does not alone prove every condition of the exemption, especially combination/onward processing. The native-app context is not by itself a disqualification; a full independent provider audit is not a statutory prerequisite.

### Public evidence and reasonable reliance

| Matter | Evidence / disposition |
| --- | --- |
| IP / hosting | [FAQ](https://telemetrydeck.com/docs/guides/privacy-faq/), reopened 2026-10-18: no IP retention in database/logs; hosting in EU. Reasonable reliance is possible without outreach or an independent audit. Connection handling remains personal-data processing to assess. |
| Shared value | Client code guarantees the same app-level value for different installations. The provider's [anonymization description](https://telemetrydeck.com/docs/articles/anonymization-how-it-works/) says server hashing occurs on receipt; this is not claimed as an additional individual-identity guarantee or verified runtime fact. |
| Retention | FAQ explicitly offers no guaranteed cold-event deletion schedule and retains analytics after customer account closure. No deletion is assumed. If genuinely anonymous retained statistics are established, GDPR storage limitation does not attach to those statistics; the conclusion must cover the retained dataset, not merely the shared ID. |
| Provider guarantees / roles | [German supplemental agreement](https://telemetrydeck.com/avv/) describes SDK use and anonymity/security assurances. The API is public, but SDK-specific contractual coverage and account acceptance are not evidenced here. Lack of proof is not proof of noncompliance. Do not manufacture a DPA, transfer guarantee or restriction from silence. |
| Combination / onward use | [Architecture overview](https://telemetrydeck.com/use-case/architecture-security/) supports isolation and limited identifier sharing. The changed client supplies no installation join key; metadata and infrastructure roles still require assessment. Hosting alone is not prohibited onward commercial reuse. A complete applicable guarantee is not documented in the reviewed sources. |

### Closure and merge decision

Implemented changes remove the recurring monthly-identification problem, preserve the requested daily/monthly metrics with explicitly changed limitations, and address prior telemetry disclosure. Automated regressions and independent code review validate those technical claims; they do not adjudicate the legal conclusion. The remaining material question is whether the provider's retained dataset and actual further use support the complete analytics exemption/anonymity conclusion for this direct integration, including historical UUID events. The all-processing notice also retains explicit open matters. Public silence is described as **not documented in the reviewed sources**, not as proof that the provider has no answer.

The current record therefore does not authorize an unconditional positive full-compliance or merge finding. Do not treat this as a demand for a provider email, a lawyer's signature, absolute impossibility of identification or an arbitrary retention period. The scope remains public evidence only. Additional favorable claims need substantive evidence; repeating the same source review or accepting product risk cannot create it.

## Delivery scope and acceptance — 2026-10-17

The owner selected completion of the technical remediation and evidence record, with TelemetryDeck, minimal collection and default-on/opt-out retained. This is separate from approval to publish the app with that configuration. Default-on is a product constraint, not evidence of lawfulness. No opt-in migration, provider replacement, production signal, provider outreach or release is authorized by this scope.

| Delivery criterion | Evidence and disposition |
| --- | --- |
| Implement and independently review agreed protections | Code `5812b9ae59acc8516200bdeec7142ef5802d2ff5`; independent review reported no remaining P1/P2 after corrections; automated expiry, backup, deletion, account-erasure and minimized-telemetry regressions passed. |
| Full tests, Release build and CI | Local full suite and Release passed on `5812b9a`. CI on documentation HEAD `7459d443fd6855b2a4ff8f004fb890e502a7bf70` passed tests and Release: [run 39023033345](https://github.com/tommaso-vaccari/BeepBar/actions/runs/39023033345). Later documentation-only commits require their own CI status; these runs are not evidence for an untested later SHA. |
| Accurate notice and retention description | IT/EN draft notice records actual client behavior, approved contact and correspondence retention, opt-out limits and attributed provider statements. Unresolved legal bases/recipient roles remain explicit; it is not a publishable complete Article 13 notice. |
| Document purpose, alternatives and verified safeguards | Assessment and source links below, including SDK review; distinguish implemented safeguards, provider statements and unverified account guarantees. |
| Record excluded manual checks honestly | Packaged/network/backup/expiry/erasure checks and procedure dry run were waived, not performed. They are not outstanding implementation tasks within this delivery; their evidential limits remain for release. |
| Preserve requested telemetry and separate unresolved lawfulness | Minimized direct client retained; issue #180 remains open for legal/operational release evidence. Do not use an automatic issue-closing keyword in this PR. |

Technical delivery does not close C01–C09 as a compliance assessment. No further runtime change is justified solely to make this table green. The remaining legal objective cannot be completed by declaring an unsupported positive result.

### Lawful default-on route: evidence boundaries

The candidate route is Article 6(1)(f) for any personal-data collection/transmission, together with a separately established Italian analytics/terminal-access exemption. If retained server data are genuinely anonymous, that conclusion needs an evidence-backed assessment; it cannot be inferred from hashing alone. A requirement that analytics be indispensable to course synchronization would apply the wrong test: the relevant interest here is compatibility maintenance. Equally effective, reasonably available, less intrusive means must still be assessed for that interest; see [CJEU C-621/22, paragraph 42](https://infocuria.curia.europa.eu/tabs/redirect/juris/documents.jsf?language=en&num=C-621%252F22&page=1).

| Condition | What supports it | What the current record does not establish |
| --- | --- | --- |
| Specific legitimate interest | Actual maintenance/adoption purpose and installation-weighted compatibility rationale below. | No invented support thresholds, maintenance decisions or production measurements. |
| Necessity and balancing | Small allowlisted payload, independently rotated monthly random identity, bounded attempts, opt-out/cancellation and alternatives analysis. | Why recurring daily linkage is necessary compared with one monthly report for the monthly metric; acceptable impact of retained linkable events and small cohorts. |
| Qualifying analytics exemption | [Garante FAQ 4–5](https://www.garanteprivacy.it/faq/Cookie) permits qualifying aggregate analytics without consent, with minimization and restrictions on third-party combination/disclosure. | The exact native/direct-API configuration meets all conditions. The exemption is not ruled out merely because the app is native or the identifier rotates monthly. |
| Provider assurances | Published no-IP-storage/EU-hosting statements and supplemental security/anonymity warranties. | Account-specific applicable terms and whether SDK-described warranties cover this direct client; no claim that every server operation needs an independent audit. |
| Purpose-limited retention | Local monthly rotation and opt-out identity deletion are implemented. | Server-event deletion or sufficiently demonstrated irreversible anonymization. The proposed 90 days is a design option, not a GDPR-prescribed deadline. |

A provider reply, a lawyer's signature and a 90-day term are not universal statutory prerequisites. Sufficient applicable public/contractual evidence could support an assessment without outreach. However, the public materials reviewed here do not resolve the particular gaps above; no server policy or account acceptance can be implemented in this repository. The positive default-on conclusion is therefore **not established**, rather than a finding that all default-on analytics are unlawful. The notice must remain a draft until those gaps and the other processing-specific notice requirements are resolved. Repeating the technical purpose does not supply that evidence.

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

## Default-on assessment — public-evidence decision, 2026-10-17

This assessment uses reasonable documented reliance, not a requirement to independently audit every provider operation. It supersedes any earlier wording implying that provider outreach, a special retention contract or a lawyer's signature is mandatory. Evidence labels distinguish observed client behavior, published provider representations, inferences and unresolved legal conditions. Sources were reopened on 2026-10-17: [provider FAQ](https://telemetrydeck.com/docs/guides/privacy-faq/), [binding German supplemental agreement](https://telemetrydeck.com/avv/), [Garante FAQ 4–5](https://www.garanteprivacy.it/faq/Cookie), and [EDPB lawful processing guide](https://www.edpb.europa.eu/sme/be-compliant/process-personal-data-lawfully_en).

### Reasonable reliance register

| Proposition | Evidence and permitted inference | Limit / reason to reopen |
| --- | --- | --- |
| The provider does not store connection IPs | Source-backed: FAQ explicitly excludes IPs from its server database and logs. Rely on this published operational representation for the assessment without demanding an independent server audit. | IP is still processed in transit. This is not a guarantee that no infrastructure party ever processes it; contradictory technical evidence or a changed policy reopens the finding. |
| Analytics hosting is in the EU | Source-backed: FAQ identifies EU locations. Reasonable inference: ordinary hosting for the described service follows those locations. | This does not establish absence of every international access/transfer or a complete recipient inventory. |
| The documented service has anonymity/security safeguards | Source-backed: supplemental agreement Sections 3 and 5 describe safeguards and documentary evidence. Reasonable inference: these are substantive published assurances rather than an absence of safeguards. | Its stated scope is SDK use. Technical similarity of a documented direct ingest client does not by itself establish contractual coverage or account acceptance. |
| The minimal app signal has lower identification risk than account-linked analytics | Code-backed: random monthly app-specific identity, four allowlisted metadata fields, no account/content/device model, bounded frequency and effective opt-out. Inference: these materially reduce linkage and identification opportunities. | Treat collection/transmission as potentially personal/pseudonymous. A small app/OS cohort and linked activity remain relevant; hashing alone is not an anonymity finding. |
| Retention is bounded | Not adopted: FAQ expressly has no guaranteed cold-storage deletion deadline and keeps analytics after account closure. | It would contradict the source to assume deletion after 90 days, after monthly rotation or on opt-out. Assess the retained data as potentially linkable unless sufficient anonymization evidence supports another conclusion. |
| The Italian analytics exemption applies | A legal conclusion to assess, not a factual assumption that follows from selecting a privacy-oriented provider. | Need a reasoned match to aggregate purpose, identification reduction, and third-party combination/onward-use restrictions; absence of contrary evidence alone does not establish these conditions. |

Recheck reliance when purpose, payload, SDK/client, provider terms or recipients change; use the wiki's existing 90-day policy-review rule. If a representation changes or is contradicted, reopen the affected conclusion. This is a review rule, not an implemented monitoring service or a statutory deadline.

### Purpose, necessity and balancing determination

**Purpose test: supported.** Installation-weighted app/major-OS distribution is a concrete maintenance interest. It helps allocate compatibility testing and version support; it is not a claim that telemetry is required to deliver course materials. No advertising, account profiling or educational-content analysis is part of this purpose.

**Monthly deduplication: technically supported for the chosen metric.** Event totals and sums of daily uniques overweight frequent use; downloads and bug reports measure different populations. Opt-in reduces the observed population and can introduce selection bias. These differences are reasons to evaluate the proposed metric, not a rule that representativeness overrides privacy. The random monthly identity is less persistent than a stable device/account identity.

**Recurring-event necessity: not established for monthly counts alone.** One locally suppressed monthly report is a materially less intrusive alternative for that narrower metric. Current daily reporting additionally observes daily activity and within-month version changes. Those are different benefits; this record does not invent a maintenance requirement for them. The owner retained the current daily/monthly metrics, so no metric change is silently implemented.

**Balancing: favorable client safeguards, unresolved retained-data impact.** Collection is small and unrelated to course content; opt-out stops future attempts and deletes the local identity without affecting core features. These support a low-impact assessment. Against that, pre-choice transmission, monthly linkage, small cohorts and unbounded archived-event retention affect expectations and exposure. A truthful prior notice is still required; downloading/updating is not acceptance. Even granting the reasonable IP/hosting reliance above, a positive overall balance is not supported by the current retention/anonymization record. This is an evidential conclusion, not a claim that indefinite retention of genuinely anonymous statistics is prohibited.

**Separate terminal-access decision: unresolved.** The Garante allows qualifying aggregate analytics without consent, including qualifying third-party tools. Default-on is therefore not categorically excluded. The record does not yet establish that all relevant conditions apply to this native/direct-client configuration, especially combination/onward-use restrictions. Article 6(1)(f) cannot replace that separate assessment.

### Daily reporting justification and exemption check — 2026-10-18

**Proposed maintenance rationale, not a statement of observed operations:** daily sampling of active installations can update the app/major-OS distribution during a release month, instead of freezing it at each installation's first report. A monthly-first-report protocol misses later app/OS upgrades; unrestricted launch events overweight frequent launches. At most one attempt per UTC day bounds both traffic and repeated observations. A monthly identity permits deduplication for installation-weighted statistics. This is a concrete argument for utility and proportionality, not proof that 24 hours is necessary or that a fall in activity establishes a regression. Offline use, opt-out and failed requests limit interpretation. No crash detection, incident-response commitment, actual daily review or maintenance threshold is asserted without evidence.

Suggested purpose wording for the assessment: “Measure, in aggregate, the distribution of app and major operating-system versions among active installations, including changes during the release month, to guide compatibility testing and version support. Limit reporting to at most one attempt per UTC day and use a separately rotated monthly random identifier for deduplication.” This accurately describes a possible use of the existing payload. It is not an approved public lawful-basis statement. Change-only reporting with local suppression is another less intrusive alternative for version-distribution changes; daily activity counts are an additional objective and cannot be made necessary merely by including them in the purpose sentence.

| Garante analytics condition | Application to the current client and provider record | Determination |
| --- | --- | --- |
| Aggregate statistics for the publisher's own app | Only BeepBar activity and version metadata are sent. The maintenance purpose is aggregate, although underlying events are individually linkable within a month. | Purpose supported; aggregate use is distinct from claiming every stored event is anonymous. |
| Prior minimization / reduced identification | Random monthly app-specific identity; no account/content/settings/model/full OS payload. Provider represents no IP storage. | Strong support from client minimization and published IP policy; no blanket anonymity conclusion. |
| No combination with other processing | App-specific randomness prevents direct reuse of an account/email identifier. Provider describes namespace separation and no external-platform identifier handover. | Reduces practical linkage. Does not establish a comprehensive prohibition on the provider's combination or secondary use. |
| No onward transmission beyond what is permissible | Supplemental agreement Section 6 restricts infrastructure access and asserts an anonymity level. | Evaluate the infrastructure function rather than treating every host as automatically prohibited. These SDK-described safeguards do not establish direct-client coverage or every onward-use restriction. |
| Applicable terminal-access framework and transparency | A native client is not exempt merely because it uses no browser cookie. IT/EN notice remains a draft. | A positive exemption and prior notice are not completed by citing the FAQ alone. |

**Retention/anonymity decision:** do not combine two unsupported assumptions (“deleted” and “anonymous”) into a safeguard. The [FAQ](https://telemetrydeck.com/docs/guides/privacy-faq/) explicitly provides no guaranteed cold-storage deletion schedule. The [anonymization description](https://telemetrydeck.com/docs/articles/anonymization-how-it-works/) supports salting/hashing safeguards; it also describes recognition with repeated identifiers. Non-reversibility of a random identifier does not alone resolve singling out, linkage or inference from an event sequence and a small version cohort. A reasoned anonymity assessment must consider the complete retained dataset, accessible auxiliary information and reasonably likely means of identification. No attack or actual identification is alleged. The current documents support reduced risk, not an established deletion policy or a definitive anonymity finding for this client.

**Disposition:** the daily-frequency argument and the condition-by-condition exemption assessment are now recorded. Neither wording nor repeated review can create missing provider restrictions, account applicability or a server retention configuration. With the current hard constraints and evidence, C08 cannot honestly be marked closed. The existing provider request remains an optional route to specific evidence or a retention arrangement, not a statutory requirement to contact the provider. No contact is sent. This assessment does not constitute legal representation or a professional legal opinion.

### Outcome and exact remaining closure routes

The public-evidence assessment is completed with a **qualified, non-positive outcome for release of the current configuration**. Lack of a provider reply or independent server audit is not a blocker in itself. The remaining decisive issues are (1) recurring-event necessity and the impact of retained linkable data, and (2) the exact third-party analytics exemption conditions. Contractual scope/account applicability matters where relying on SDK-specific warranties to resolve these issues.

A positive conclusion needs either applicable public/contractual evidence demonstrating sufficient anonymization and restricted third-party use, or a concrete configuration/protocol change that resolves those conditions with supporting evidence. A bounded-retention arrangement is one possible route, not a universal requirement. Reducing to monthly reports can address recurring linkage but does not alone resolve the exemption. None of these unimplemented alternatives is described as active. Keep default-on and TelemetryDeck in the draft as requested; keep C08 open and the notice unpublished. No provider contact, account change, opt-in migration or release is authorized or performed.

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

The reasonable-reliance assessment above is the current public-document-only outcome for the questions below. This request is prepared but not sent because the owner previously prohibited provider outreach. No account settings, contractual acceptance, deletion policy, budget or legal-review engagement has been changed. A later authorization to use TelemetryDeck does not by itself revoke that outreach restriction. C08 stays open until the missing evidence and the application-specific legal assessment support closure; a negative or incomplete answer must remain visible.


## Official Swift SDK migration assessment — 2026-10-17

The owner authorized using the official Swift SDK if it simplifies the evidence gap. Examined upstream tag `2.14.2`, commit `58f436299d3f6710bcedc18aff26480aaf1879fc`; no SDK was initialized and no signal was sent. A standard migration has not been applied because it would regress the existing minimization and transmission guarantees. This is a source review, not a runtime validation or a legal conclusion.

- [SignalManager.processSignal](https://github.com/TelemetryDeck/SwiftSDK/blob/58f436299d3f6710bcedc18aff26480aaf1879fc/Sources/TelemetryDeck/Signals/SignalManager.swift#L152-L192) unconditionally reads `DefaultSignalPayload.parameters`, then merges enrichers and custom parameters. The public configuration has no payload-key removal hook. [DefaultSignalPayload](https://github.com/TelemetryDeck/SwiftSDK/blob/58f436299d3f6710bcedc18aff26480aaf1879fc/Sources/TelemetryDeck/Signals/Signal.swift#L46-L133) includes device model, architecture, full OS version, language/region, screen, timezone, accessibility and session/retention fields beyond BeepBar's four-field allowlist. Overriding values does not remove keys or prevent their initial collection.
- `sendNewSessionBeganSignal = false`, `sessionStatsEnabled = false`, `defaultUser = <monthly UUID>` and `logHandler = nil` are available controls, but do not remove that unconditional default payload. Setting only the per-event custom ID is insufficient to prevent creation of the SDK's persistent fallback ID: `processSignal` reads `defaultUserIdentifier` even when a custom ID was supplied.
- [SignalCache](https://github.com/TelemetryDeck/SwiftSDK/blob/58f436299d3f6710bcedc18aff26480aaf1879fc/Sources/TelemetryDeck/Signals/SignalCache.swift) restores pending events from disk and backs them up at app termination. There is no supported memory-only cache mode; `cacheLimit = 0` drops all events. The send loop retries failed batches independently of BeepBar's daily-attempt guard.
- `analyticsDisabled` guards signal creation; it is not consulted by the cached-batch transmission method. An SDK migration must therefore explicitly address queued events and in-flight requests at opt-out, rather than treating that flag as cancellation. A custom `urlSession` is supported, but network interception alone would not prevent the SDK's earlier collection and local caching of additional fields.

A suitable migration needs a supported pre-collection payload allowlist, memory-only/no-retry event handling, and verified queue/in-flight cancellation, alongside monthly identity/session separation. A fork or request-rewriting adapter is not automatically equivalent to the contract-described integration and must not be represented as resolving the original warranty-scope question. Until these guarantees are preserved, keep the already minimized direct client; do not expand collection solely to adopt the SDK. The service-retention and terminal-access assessments remain open independently of client selection. No provider contact is authorized.
