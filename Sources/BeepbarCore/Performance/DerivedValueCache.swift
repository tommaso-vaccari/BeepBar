import Foundation

/// Remembers the last value derived from one set of inputs, so a view whose `body` is evaluated
/// again for an unrelated publication (a spinner flip, a row being opened, a bookmark toggled)
/// does not sort, group and filter the same list again (#100).
///
/// One entry only, on purpose: the page shows one course at a time, and holding every list ever
/// derived would grow with every course and year visited. Going back to an earlier input is a
/// recomputation, never a stale hit.
///
/// It is a class so a SwiftUI view can hold it in `@State` and fill it during `body` without
/// mutating view state (which SwiftUI forbids mid-update): the stored value is a cache, not state
/// the view reacts to. The inputs decide everything the output depends on, so an input left out
/// of `Input` is a stale-display bug: `RecmanCourseListDerivation.Inputs` lists why each is there.
/// Not thread-safe; each instance belongs to one view, on the main actor.
public final class DerivedValueCache<Input: Equatable, Output> {
    /// How many times `compute` ran, so tests can prove that equal inputs cost nothing.
    public private(set) var computations = 0
    private var stored: (input: Input, output: Output)?

    public init() {}

    /// The output for `input`: the stored one when the inputs are equal, otherwise `compute`'s.
    public func value(for input: Input, compute: (Input) -> Output) -> Output {
        if let stored, stored.input == input { return stored.output }
        computations += 1
        let output = compute(input)
        stored = (input, output)
        return output
    }

    /// Forgets the stored value; the next request recomputes.
    public func invalidate() {
        stored = nil
    }
}
