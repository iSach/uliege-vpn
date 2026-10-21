import AppKit
import ServiceManagement
import SwiftUI

@MainActor private final class SliderFixtureState: ObservableObject {
    @Published var minutes = 60
    @Published var enabled = true
}

private struct SliderFixture: View {
    @ObservedObject var state: SliderFixtureState
    var body: some View {
        SessionMinuteSlider(value: $state.minutes)
            .disabled(!state.enabled).frame(width: 300, height: 22)
    }
}

@MainActor private final class DisclosureFixtureState: ObservableObject {
    @Published var expanded = false
}

private struct DisclosureFixture: View {
    @ObservedObject var state: DisclosureFixtureState
    var body: some View {
        VStack {
            Text("VPN status")
            DisclosureGroup("Settings", isExpanded: $state.expanded) {
                ForEach(0..<30) { index in Text("Setting \(index)").frame(height: 30) }
            }
        }.padding(18)
    }
}

@main struct MenuBarPreferencesTests {
    @MainActor static var checks = 0

    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    @MainActor static func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }

    @MainActor static func findSlider(_ view: NSView) -> MinuteSliderControl? {
        if let slider = view as? MinuteSliderControl { return slider }
        return view.subviews.lazy.compactMap { findSlider($0) }.first
    }

    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var status: SMAppService.Status = .notRegistered
        var registrations = 0
        var unregistrations = 0
        let login = LoginItemSettings(readStatus: { status }, register: {
            registrations += 1
            status = .enabled
        }, unregister: {
            unregistrations += 1
            status = .notRegistered
        })
        check(!login.isOn && registrations == 0, "Creating settings must not register a login item")
        await login.setEnabled(true)
        check(login.isOn && registrations == 1 && !login.changing, "Explicit enable registers the app")
        await login.setEnabled(true)
        check(registrations == 1, "An enabled item must not be registered twice")
        status = .requiresApproval
        login.refresh()
        check(login.isOn && login.requiresApproval, "Pending macOS approval is represented separately")
        await login.setEnabled(false)
        check(!login.isOn && unregistrations == 1, "Disabling a pending item unregisters it")
        status = .enabled
        login.refresh()
        check(login.isOn, "An external System Settings change is reflected")
        status = .notRegistered
        login.refresh()
        check(!login.isOn, "An externally disabled item is reflected")

        let failure = NSError(domain: "SyntheticLoginItemFailure", code: 1)
        let failed = LoginItemSettings(readStatus: { .notRegistered }, register: { throw failure }, unregister: {})
        await failed.setEnabled(true)
        check(!failed.isOn && failed.errorMessage != nil && !failed.changing, "A failed registration must not show enabled")
        let denied = LoginItemSettings(readStatus: { status }, register: {
            status = .requiresApproval
            throw failure
        }, unregister: { throw failure })
        await denied.setEnabled(true)
        check(denied.requiresApproval && denied.errorMessage == nil, "User approval remains actionable after a denial")
        await denied.setEnabled(false)
        check(denied.isOn && denied.errorMessage != nil && !denied.changing, "Unregister failure preserves the real system state")
        status = .enabled
        denied.refresh()
        check(denied.isOn && denied.errorMessage == nil, "An external correction clears stale login-item errors")

        let sliderState = SliderFixtureState()
        let sliderHost = NSHostingView(rootView: SliderFixture(state: sliderState))
        let sliderWindow = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 350, height: 50),
                                    styleMask: .borderless, backing: .buffered, defer: false)
        sliderWindow.contentView = sliderHost
        sliderHost.layoutSubtreeIfNeeded()
        settle()
        let slider = findSlider(sliderHost)!
        check(slider.numberOfTickMarks == 0, "Native slider must have no dots or tick marks")
        check(slider.integerValue == 60, "Saved duration is shown by the native control")
        slider.doubleValue = 67
        slider.sendAction(slider.action!, to: slider.target)
        check(sliderState.minutes == 60 && slider.integerValue == 60, "Mouse input snaps to the nearest 15 minutes")
        slider.doubleValue = 68
        slider.sendAction(slider.action!, to: slider.target)
        check(sliderState.minutes == 75 && slider.integerValue == 75, "Mouse input can advance to the next interval")
        let rightArrow = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: sliderWindow.windowNumber, context: nil,
                                         characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}",
                                         isARepeat: false, keyCode: 124)!
        slider.keyDown(with: rightArrow)
        check(sliderState.minutes == 90, "Keyboard arrows retain 15-minute steps")
        check(slider.accessibilityPerformIncrement() && sliderState.minutes == 105, "VoiceOver can increase the value")
        check(slider.accessibilityPerformDecrement() && sliderState.minutes == 90, "VoiceOver can decrease the value")
        sliderState.minutes = 1440
        settle()
        check(slider.integerValue == 1440, "A changed model updates the native slider")
        _ = slider.accessibilityPerformIncrement()
        check(sliderState.minutes == 1440, "Increment cannot exceed 24 hours")
        sliderState.minutes = 0
        settle()
        _ = slider.accessibilityPerformDecrement()
        check(sliderState.minutes == 0, "Decrement cannot go below always-fresh")
        sliderState.enabled = false
        settle()
        check(!slider.isEnabled && !slider.accessibilityPerformIncrement(), "Working-state disabling reaches the native control")
        check(sliderState.minutes == 0, "Disabled accessibility input must not change the preference")

        let sizing = PopoverSizing()
        let disclosureState = DisclosureFixtureState()
        let host = NSHostingView(rootView: FittingPopoverContent(sizing: sizing) {
            DisclosureFixture(state: disclosureState)
        })
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 350, height: 260),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        sizing.onResize = { size in window.setContentSize(size) }
        host.layoutSubtreeIfNeeded()
        settle()
        let compactHeight = sizing.height
        check(compactHeight > 0 && compactHeight < 260, "Collapsed content produces a compact popup")
        disclosureState.expanded = true
        settle()
        check(sizing.height > compactHeight, "Expanding real SwiftUI content grows the popup")
        check(sizing.height == 720, "Tall content is capped for scrolling")
        disclosureState.expanded = false
        settle()
        check(abs(sizing.height - compactHeight) < 1, "Collapsing content shrinks the popup again")
        check(abs(window.contentView!.bounds.height - compactHeight) < 1, "The native window follows the measured height")
        print("Menu bar preferences: \(checks) assertions passed")
    }
}
