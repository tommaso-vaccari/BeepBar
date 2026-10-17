# Privacy operations — proposed procedure

Owner approval and a synthetic dry run are still required; see [release gate](privacy-release-gate.md). Public contact: [draft notice](privacy-notice.md). Never place actual requests, account details, incidents or secrets in GitHub issues or this repository.

## Requests

1. Record receipt date, requested right and minimum contact data in a private, access-controlled register. Acknowledge receipt and identify the processing concerned. Do not request passwords, cookies, tokens or course content.
2. Check identity proportionately only when needed. Distinguish locally controlled app data, information held for support, telemetry, and university/Webex data. Route third-party service requests appropriately; do not promise authority over their records.
3. Respond without undue delay and within one month under GDPR Article 12(3). A justified extension of up to two further months must be explained within the original month. Document refusals, applicable exceptions and complaint routes.
4. For local erasure, guide the user; do not access their device without separate authorization. For telemetry establish whether records can actually be linked and the provider's assistance; GDPR Article 11 does not require collecting extra identifiers solely for identification. Opt-out only stops future sends.
5. Send exports privately, verify recipient and exclude other people's data. Retain only evidence necessary to handle/account for the request; proposed support retention is 90 days after closure, pending owner approval.

## Local cleanup guidance

Disconnect the university account and disable Recordings. Resolve any deletion error in Settings → Data and privacy before assuming session deletion succeeded. Revoke the university mobile token through the university's supported mechanism if revocation is needed; deleting a local token does not revoke it remotely.

Quit BeepBar. Preserve the materials folder and local edits first. App state is in `~/Library/Application Support/Beepbar` and preferences for bundle `io.github.tvaccari.beepbar`; removing all of these resets app state, including sync history and per-account study choices. This is a whole-app reset, not a per-account erasure operation. Check the selected materials folder separately; do not delete it unintentionally. Uninstalling the app alone is not data erasure. Backups, macOS notifications, clipboard/Now Playing and system-managed diagnostics need separate consideration; do not promise remote or backup erasure from an app reset. Relaunch only after intentionally completing the reset because enabled features can create new data.

## Suspected breach

Record discovery time, affected data/systems, access, scope, likely consequences and mitigation privately. Contain the issue, restrict access/revoke exposed tokens where authorized, preserve minimal evidence, and contact the privacy owner immediately. Never attach secrets or unredacted user logs to public issues.

Assess GDPR Articles 33–34: notify the competent authority within 72 hours of awareness where required; document delay and report in stages if necessary. Inform affected people without undue delay where high risk requires it, subject to the legal exceptions. Document the assessment even if no notification is required. Do not automatically classify every bug as a reportable breach.

## Owner sign-off

Record treatment purposes/roles/bases, retention and recipients, provider terms/security/transfer evidence, access to the mailbox, deletion/export test results and incident contacts. Assess proportional Article 30 records, DPIA under Article 35 and DPO under Article 37 against the actual operations; a small user count is not a blanket exemption. Do not mark the release gate closed from passing unit tests alone.
