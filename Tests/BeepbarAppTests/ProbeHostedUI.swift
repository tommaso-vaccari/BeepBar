import Testing

/// The one serialized scope for every test that hosts a page whose body or rows report to the
/// process-global DEBUG probes (`UIBodyProbe`, `RecordingsPageProbes`) (#280 review).
///
/// Swift Testing runs suites in parallel, and the probes are plain statics: a hosted Courses or
/// Recordings page in another suite would add its body evaluations to a counting test, or find its
/// own probe closure replaced. `.serialized` on a parent applies to every nested suite and test,
/// so none of them can run at the same time as another. A suite that hosts `HomePage`,
/// `RecordingsPage` or `RecordingRow` (and a test that sets a probe) belongs inside this enum, via
/// `extension ProbeHostedUI { ... }`; those extensions are not re-indented to keep the history of
/// the moved suites readable.
@Suite(.serialized) @MainActor struct ProbeHostedUI {}
