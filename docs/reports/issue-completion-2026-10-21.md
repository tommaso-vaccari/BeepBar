# Issue completion — 2026-10-21, PR #232

Base dev: `770260a7d245f0f069f0e6636f5423b00bd15fe9`. Final validation and merge SHAs are recorded in PR #232.

## Activity #99

The inner stack now constructs revealed rows lazily, including after Show more has revealed all 15,000 entries. Pagination, row IDs, actions and accessibility labels are unchanged. A hidden hosted regression checks first/last reachability and fewer than 200 unique row constructions initially / 400 after jumping to the end; reverting the inner stack to eager construction must fail. Existing ActivityRowLayout and Activity action tests remain part of the full gate.

Before implementation, `python3 scripts/ui-benchmark.py --ref origin/dev --out PerformanceReports/issue99-base-dev-20261021 --scenarios activity-1000 activity-15000 --runs 5 --warmup 1` ran on Apple M2, 8 GB, AC power. Raw series/traces remain in that local ignored report directory. First expanded-content median/max: 1,000 rows 128.656/130.641 ms; 15,000 rows 135.059/159.401 ms. Window-key median/max: 280.600/285.997 and 294.093/344.665 ms respectively, exceeding the 250 ms window target. These are five samples, not reliable p95 estimates, and reveal only the first 200 rows.

Further foreground app launches were stopped at the owner's request. Hidden hosted tests establish construction bounds and reachability, not compositor/frame-time guarantees. Candidate/base-dev and candidate/main timing comparisons and the 16 ms scrolling budget remain unmeasured. Do not close #99 on the strength of this structural fix alone or describe its performance acceptance as passed.

## Tooling #222

The shared gate now executes the isolated recordings fixture; repairing its extracted debug probe dependency demonstrates the previously untested dependency rot. The extraction checks its source anchor and copies only the needed bulk-scan declaration. The fixture passes 142 tests. UI benchmark and Linux-wrapper regression suites already belong to the gate and remain enabled. Mutation switches intentionally expect failing tests and are not normal green gate invocations.

The wrapper regression clears inherited Git repository environment variables before creating disposable repositories. Both normal and simulated hook-environment runs pass all ten lockfile/signal cases, preserving the caller repository. Linux Core now has a release-PR-only job using digest-pinned Swift 6.2.1 Jammy and explicit SQLite development headers. No development CI or manual release job is triggered. Actual Linux execution awaits the next authorized dev → main PR; this delivery establishes coverage configuration, not a claim that this new online job has already passed.

## Released privacy record #180

Release [v3.0.0](https://github.com/tommaso-vaccari/BeepBar/releases/tag/v3.0.0), published 2026-10-19, points to `07fba3b647577ec08f17e486004129dd5f81357a`. Downloaded `00-Beepbar.dmg`: 6,050,863 bytes, SHA-256 `eb7605865f9cf3dfa6595b7943313398bbf3a60dc4b67c62cae99140d6e2ad8f`, matching GitHub's asset digest. Its arm64 app identifies version 3.0.0 and `io.github.tvaccari.beepbar`; `codesign --verify --deep --strict` passes. This verifies its existing signature, not notarization or an independently attested publisher identity.

Bundled `Contents/Resources/privacy-notice.md` matches both notice copies in tag v3.0.0 byte for byte: SHA-256 `a607a3381c15d5f38d2486b3affc1326850dd6931ffc8b180172387220757bca`. Current main has no difference in these notice copies or Telemetry.swift. The public [BeepBar page](https://www.tommasovaccari.com/beepbar) already links to the main-branch notice. The appcast enclosure identifies the same 3.0.0 asset and byte count and includes an Ed25519 signature; this inspection does not independently verify that Sparkle signature. No installed app was launched, installed or changed for these checks.

This completes the outstanding released-artifact/notice record. Existing qualified v2 assessment and opt-out remain unchanged. Historical UUID events have not been erased or retrospectively validated; no cold-event deletion schedule is assumed. Previously waived packaged-app network/session/backup/erasure manual checks and procedure dry run remain unperformed. No full-app GDPR certification follows. Reassessment triggers and annual review remain in the privacy gate.

## Previously closed work and tracker

#162 and #217 were closed after their issue-specific evidence reconciliation earlier in this delivery. Collaborator tommasoz24 closed #107, #115 and #116 on 2026-10-21. Those state changes are preserved; no new playback scheduling measurements or real-account validation matrix were produced here, and their historical evidence gaps are not relabeled as passing checks. The tracker must keep #99 visibly outstanding even if its own closed state is retained.
