# Isolated UI fixture series

Source: `67e17fe7705e9195cf132ce9722b9164f5fd699b`

Validity: **True**

| Scenario | Metric | n | Median | p95 (unstable) | Min | Max |
|---|---|---:|---:|---:|---:|---:|
| recordings-1000 | window key (ms) | 5 | 100.630 | 103.052 | 99.388 | 103.052 |
| recordings-1000 | first recordings (ms) | 5 | 190.947 | 196.689 | 189.697 | 196.689 |
| launch-warm | window key (ms) | 5 | 64.118 | 65.303 | 53.107 | 65.303 |
| launch-warm | first courses (ms) | 5 | 31.965 | 33.555 | 26.780 | 33.555 |

## Observed window key budgets

| Scenario | Target ms | Maximum observed ms | All samples within budget |
|---|---:|---:|---|
| recordings-1000 | 250 | 103.052 | True |
| launch-warm | 100 | 65.303 | True |

## Interpretation

Window key targets: 250ms first-window, 100ms same-process reopen. Icon construction excludes fixture startup and must not be compared to the 200ms app launch budget. Main-thread traces require independent interpretation; this table establishes no compositor/frame-time guarantee.

- Tooling validation is separate from app performance gains.
- Base-dev and main comparisons are not measured; older revisions need a reviewed equivalent UI fixture.
- Cold means first window in a fresh fixture process, not cold filesystem cache or production bootstrap.
- Content onAppear is distinct from compositor presentation. Time Profiler samples establish stacks, not a proof of every <=16ms stall.
- Only synthetic known-content offline refresh is covered; persisted cold offline restoration remains D10.
- Idle runs once, unprofiled, for 30 minutes; real scheduled checks are disabled and count zero by construction.
- Five measured runs cannot establish a reliable p95. Manual scrolling/actions remain required.
