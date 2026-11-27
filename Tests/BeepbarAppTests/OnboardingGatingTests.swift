import Foundation
import AppKit
import SwiftUI
import Testing
@testable import BeepbarApp

struct OnboardingGatingTests {
    /// The first-run page explains the action needed, without prompting during loading or sync-ready states.
    @Test func coursesNextStep() {
        #expect(HomePage.nextStep(loading: false, signedIn: false, courseCount: 0, enabledCount: 0) == .signIn)
        #expect(HomePage.nextStep(loading: false, signedIn: true, courseCount: 2, enabledCount: 0) == .enableCourse)
        #expect(HomePage.nextStep(loading: true, signedIn: false, courseCount: 0, enabledCount: 0) == .none)
        #expect(HomePage.nextStep(loading: false, signedIn: true, courseCount: 0, enabledCount: 0) == .none)
        #expect(HomePage.nextStep(loading: false, signedIn: true, courseCount: 2, enabledCount: 1) == .none)
    }
    @Test func freshInstallNeedsOnboarding() {
        #expect(WeBeepAuthenticationController.resolveNeedsOnboarding(existingRootURL: nil, onboardingAlreadyCompleted: false) == true)
    }

    @Test func existingInstallUpdatingNeverRetriggersOnboardingEvenIfFlagWasNeverSet() {
        // This is the exact scenario for every user who set up Beepbar before onboarding existed:
        // they have a root but the flag was never written. An existing root must win on its own.
        let root = URL(fileURLWithPath: "/tmp/some-existing-root")
        #expect(WeBeepAuthenticationController.resolveNeedsOnboarding(existingRootURL: root, onboardingAlreadyCompleted: false) == false)
    }

    @Test func completedOnboardingWithRootDoesNotReappear() {
        let root = URL(fileURLWithPath: "/tmp/some-existing-root")
        #expect(WeBeepAuthenticationController.resolveNeedsOnboarding(existingRootURL: root, onboardingAlreadyCompleted: true) == false)
    }

    @Test func completedOnboardingSurvivesRootGoingMissing() {
        // e.g. the user deleted the sync folder from Finder without redoing setup: onboarding
        // must not come back just because storedRootURL() now resolves to nil.
        #expect(WeBeepAuthenticationController.resolveNeedsOnboarding(existingRootURL: nil, onboardingAlreadyCompleted: true) == false)
    }
}

extension ProbeHostedUI {
@MainActor @Suite(.serialized) struct CoursesSignInTests {
    /// Each visible sign-in action starts the real controller flow instead of opening Settings.
    @Test(arguments: [0, 1]) func signInButtonStartsLogin(index: Int) async throws {
        let controller = WeBeepAuthenticationController(testRootURL: FileManager.default.temporaryDirectory)
        controller.setDisconnectedForTesting()
        AssistiveClient.acquire()
        defer { AssistiveClient.release() }
        var openedSettings = false
        let host = NSHostingView(rootView: HomePage(authentication: controller, open: { _ in openedSettings = true }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        func buttons(_ element: Any, depth: Int = 0) -> [AnyObject] {
            guard depth < 40 else { return [] }
            let object = element as AnyObject
            let role: NSAccessibility.Role? = object.accessibilityRole?() ?? nil
            let label: String = (object.accessibilityLabel?() ?? nil) ?? ""
            let current = role == .button && label == "Accedi a WeBeep" ? [object] : []
            return current + ((object.accessibilityChildren?() ?? nil) ?? []).flatMap { buttons($0, depth: depth + 1) }
        }
        let deadline = Date().addingTimeInterval(10)
        var found: [AnyObject] = []
        repeat {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            found = buttons(window).sorted { ($0.accessibilityFrame?() ?? .zero).midY > ($1.accessibilityFrame?() ?? .zero).midY }
            if found.count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        } while Date() < deadline
        #expect(found.count == 2, "Both Corsi sign-in buttons must be visible")
        guard found.count == 2 else { return }
        #expect(found[index].accessibilityPerformPress?() == true)
        #expect(controller.isAuthenticating)
        #expect(!openedSettings)
    }
}
}
