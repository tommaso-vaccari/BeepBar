import AppKit
import Testing
@testable import BeepbarApp

/// The player's pure decisions (issue #148, package G): speed list and stepping, the remembered
/// speed, the >2x cap, skip and jump targets, the resume position and the key map. Each test
/// covers the boundaries a plausible edit would move.
struct RecordingPlayerPolicyTests {
    typealias Policy = RecordingPlayerPolicy

    /// The offered speeds are exactly the product owner's list, slowest first. Guards against a
    /// speed silently dropped or reordered (stepping relies on the order).
    @Test func theSpeedListIsTheAgreedOne() {
        #expect(Policy.speeds == [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3])
        #expect(Policy.speeds == Policy.speeds.sorted())
    }

    /// Without fast-forward support only speeds up to 2x are offered (AVFoundation guarantees
    /// no more); with it, all of them. Guards against offering 2.5x/3x on a stream that cannot
    /// play them.
    @Test func fastSpeedsNeedFastForward() {
        #expect(Policy.availableSpeeds(canPlayFastForward: true) == Policy.speeds)
        #expect(Policy.availableSpeeds(canPlayFastForward: false) == [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2])
        #expect(Policy.effectiveSpeed(preferred: 3, canPlayFastForward: false) == 2)
        #expect(Policy.effectiveSpeed(preferred: 2.5, canPlayFastForward: false) == 2)
        #expect(Policy.effectiveSpeed(preferred: 3, canPlayFastForward: true) == 3)
        #expect(Policy.effectiveSpeed(preferred: 2, canPlayFastForward: false) == 2)
        #expect(Policy.effectiveSpeed(preferred: 0.5, canPlayFastForward: false) == 0.5)
    }

    /// A rate matches a listed speed only within float rounding.
    @Test func ratesMatchListedSpeedsOnly() {
        #expect(Policy.speed(matching: 0.75) == 0.75)
        #expect(Policy.speed(matching: 0.7505) == 0.75)
        #expect(Policy.speed(matching: 1.1) == nil)
        #expect(Policy.speed(matching: 3.5) == nil)
        #expect(Policy.speed(matching: .nan) == nil)
        #expect(Policy.speed(matching: .infinity) == nil)
    }

    /// The remembered speed is used only when it is a listed speed; anything else plays at 1x.
    /// Guards against a corrupted or outdated preference making every lecture play oddly.
    @Test func theStoredSpeedFallsBackToNormal() {
        #expect(Policy.storedSpeed(nil) == 1)
        #expect(Policy.storedSpeed(NSNumber(value: 1.5)) == 1.5)
        #expect(Policy.storedSpeed(NSNumber(value: 3.0)) == 3)
        #expect(Policy.storedSpeed(NSNumber(value: 1.6)) == 1)
        #expect(Policy.storedSpeed(NSNumber(value: 0)) == 1)
        #expect(Policy.storedSpeed(NSNumber(value: -2)) == 1)
        #expect(Policy.storedSpeed("2") == 1)
        #expect(Policy.storedSpeed(Data()) == 1)
    }

    /// `<` / `>` step to the neighbouring speed and stop at the ends, for every speed in both
    /// lists; a rate between two speeds steps to the nearest in that direction.
    @Test func speedStepsWalkTheListAndStopAtTheEnds() {
        for canFastForward in [false, true] {
            let available = Policy.availableSpeeds(canPlayFastForward: canFastForward)
            for (index, speed) in available.enumerated() {
                let faster = Policy.steppedSpeed(from: speed, faster: true, available: available)
                let slower = Policy.steppedSpeed(from: speed, faster: false, available: available)
                #expect(faster == (index + 1 < available.count ? available[index + 1] : nil))
                #expect(slower == (index > 0 ? available[index - 1] : nil))
            }
        }
        let all = Policy.speeds
        #expect(Policy.steppedSpeed(from: 1.1, faster: true, available: all) == 1.25)
        #expect(Policy.steppedSpeed(from: 1.1, faster: false, available: all) == 1)
        #expect(Policy.steppedSpeed(from: 2, faster: true, available: Policy.availableSpeeds(canPlayFastForward: false)) == nil)
    }

    /// Skips land inside the lecture: never before 0, never past the duration, unclamped above
    /// only when the duration is unknown.
    @Test func skipsAreClampedToTheLecture() {
        #expect(Policy.skipTarget(from: 20, by: 10, duration: 60) == 30)
        #expect(Policy.skipTarget(from: 20, by: -10, duration: 60) == 10)
        #expect(Policy.skipTarget(from: 5, by: -10, duration: 60) == 0)
        #expect(Policy.skipTarget(from: 20, by: -30, duration: 60) == 0)
        #expect(Policy.skipTarget(from: 55, by: 10, duration: 60) == 60)
        #expect(Policy.skipTarget(from: 45, by: 30, duration: 60) == 60)
        #expect(Policy.skipTarget(from: 55, by: 10, duration: nil) == 65)
        #expect(Policy.skipTarget(from: 55, by: 10, duration: .infinity) == 65)
        #expect(Policy.skipTarget(from: .nan, by: 10, duration: 60) == 10)
    }

    /// Digits jump to tenths of the duration, and do nothing without a duration.
    @Test func digitsJumpToTenthsOfTheLecture() {
        for digit in 0...9 {
            #expect(Policy.jumpTarget(fraction: Double(digit) / 10, duration: 60) == Double(digit) * 6)
        }
        #expect(Policy.jumpTarget(fraction: 0.5, duration: nil) == nil)
        #expect(Policy.jumpTarget(fraction: 0.5, duration: 0) == nil)
        #expect(Policy.jumpTarget(fraction: 0.5, duration: .nan) == nil)
        #expect(Policy.jumpTarget(fraction: 2, duration: 60) == 60)
    }

    /// A resume position within 5 s of either end, or not a number, starts from the beginning.
    /// Guards against resuming a finished lecture at its last second, or seeking for nothing.
    @Test func theResumePositionIgnoresBothEnds() {
        #expect(Policy.resumePosition(startAt: nil, duration: 60) == nil)
        #expect(Policy.resumePosition(startAt: .nan, duration: 60) == nil)
        #expect(Policy.resumePosition(startAt: .infinity, duration: 60) == nil)
        #expect(Policy.resumePosition(startAt: 4.99, duration: 60) == nil)
        #expect(Policy.resumePosition(startAt: 5, duration: 60) == 5)
        #expect(Policy.resumePosition(startAt: 30, duration: 60) == 30)
        #expect(Policy.resumePosition(startAt: 55, duration: 60) == 55)
        #expect(Policy.resumePosition(startAt: 55.01, duration: 60) == nil)
        #expect(Policy.resumePosition(startAt: 90, duration: 60) == nil)
        #expect(Policy.resumePosition(startAt: 900, duration: nil) == 900)
        #expect(Policy.resumePosition(startAt: 5, duration: 8) == nil)
        #expect(Policy.acceptsStartAt(5) && !Policy.acceptsStartAt(4.9) && !Policy.acceptsStartAt(nil))
    }

    /// The key map, entry by entry, including what must pass through: chords (⌘W, ⌘Q, ⌥←),
    /// unmapped keys and other special keys.
    @Test func keysMapToTheDocumentedShortcuts() {
        func map(_ characters: String?, _ ignoring: String? = nil, special: NSEvent.SpecialKey? = nil, _ modifiers: NSEvent.ModifierFlags = []) -> PlayerShortcut? {
            Policy.shortcut(characters: characters, charactersIgnoringModifiers: ignoring ?? characters, specialKey: special, modifiers: modifiers)
        }
        #expect(map(" ") == .togglePlayPause)
        #expect(map("k") == .pause)
        #expect(map("K", "K", [.shift]) == .pause)
        #expect(map("j") == .skip(-10))
        #expect(map("l") == .skip(10))
        #expect(map("J", "J") == .skip(-10))
        #expect(map("f") == .toggleFullScreen)
        #expect(map("m") == .toggleMute)
        #expect(map("<", ",", [.shift]) == .slower)
        #expect(map(">", ".", [.shift]) == .faster)
        #expect(map("<", "<") == .slower)
        for digit in 0...9 {
            #expect(map("\(digit)") == .jump(Double(digit) / 10))
        }
        #expect(map("1", "&", [.shift]) == .jump(0.1))
        #expect(map("!", "1", [.shift]) == nil)
        #expect(map(nil, special: .leftArrow, [.function, .numericPad]) == .skip(-10))
        #expect(map(nil, special: .rightArrow, [.function, .numericPad]) == .skip(10))
        #expect(map(nil, special: .leftArrow, [.function, .numericPad, .shift]) == .skip(-30))
        #expect(map(nil, special: .rightArrow, [.function, .numericPad, .shift]) == .skip(30))
        #expect(map(nil, special: .upArrow, [.function, .numericPad]) == nil)
        #expect(map(nil, special: .leftArrow, [.function, .option]) == nil)
        #expect(map("f", "f", [.command]) == nil)
        #expect(map("w", "w", [.command]) == nil)
        #expect(map("f", "f", [.command, .control]) == nil)
        #expect(map(" ", " ", [.control]) == nil)
        #expect(map("x") == nil)
        #expect(map("10") == nil)
        #expect(map("") == nil)
    }

    /// Only skips and speed steps repeat while a key is held; toggles would flicker.
    @Test func onlyStepsRepeat() {
        #expect(PlayerShortcut.skip(10).repeats && PlayerShortcut.slower.repeats && PlayerShortcut.faster.repeats)
        for shortcut in [PlayerShortcut.togglePlayPause, .pause, .toggleFullScreen, .toggleMute, .jump(0.5)] {
            #expect(!shortcut.repeats)
        }
    }

    /// Speed labels drop trailing zeros and use the Italian decimal comma (tests run with the
    /// Italian default), and the shortcut help lists every binding.
    @Test func labelsAndHelp() {
        #expect(Policy.speedLabel(1) == "1×")
        #expect(Policy.speedLabel(0.75) == "0,75×")
        #expect(Policy.speedLabel(1.5) == "1,5×")
        #expect(Policy.speedLabel(2.5) == "2,5×")
        #expect(Policy.speedLabel(3) == "3×")
        let help = Policy.shortcutHelp()
        #expect(help.count == 9)
        #expect(help.allSatisfy { !$0.keys.isEmpty && !$0.action.isEmpty })
    }
}
