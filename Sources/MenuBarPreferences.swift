import AppKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class LoginItemSettings: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var changing = false
    @Published private(set) var errorMessage: String?

    private let readStatus: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () async throws -> Void

    init(readStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
         register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
         unregister: @escaping () async throws -> Void = { try await SMAppService.mainApp.unregister() }) {
        self.readStatus = readStatus
        self.register = register
        self.unregister = unregister
        status = readStatus()
    }

    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var requiresApproval: Bool { status == .requiresApproval }

    func refresh() {
        let current = readStatus()
        if current != status { errorMessage = nil }
        status = current
    }

    func setEnabled(_ enabled: Bool) async {
        guard !changing else { return }
        refresh()
        guard enabled != isOn else { return }
        changing = true
        errorMessage = nil
        defer {
            refresh()
            changing = false
        }
        do {
            if enabled { try register() }
            else { try await unregister() }
        } catch {
            refresh()
            if enabled != isOn {
                errorMessage = "macOS couldn’t update launch at login. Try again from the installed app or check Login Items in System Settings."
            }
        }
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
final class PopoverSizing: ObservableObject {
    static let width: CGFloat = 350
    @Published private(set) var height: CGFloat = 260
    private var contentHeight: CGFloat = 260
    private var maximumHeight: CGFloat = 720
    var onResize: ((NSSize) -> Void)?

    func updateContentHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        contentHeight = ceil(height)
        resize()
    }

    func updateScreen(_ screen: NSScreen?) {
        maximumHeight = min(720, max(1, (screen?.visibleFrame.height ?? 760) - 40))
        resize()
    }

    private func resize() {
        let next = min(contentHeight, maximumHeight)
        guard abs(next - height) > 0.5 else { return }
        height = next
        onResize?(NSSize(width: Self.width, height: next))
    }
}

private struct PopoverContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct FittingPopoverContent<Content: View>: View {
    @ObservedObject var sizing: PopoverSizing
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: PopoverContentHeight.self, value: geometry.size.height)
                })
        }
        .frame(width: PopoverSizing.width, height: sizing.height)
        .onPreferenceChange(PopoverContentHeight.self) { sizing.updateContentHeight($0) }
    }
}

/// Native tick-free slider. Mouse, keyboard and accessibility retain 15-minute steps.
struct SessionMinuteSlider: NSViewRepresentable {
    @Binding var value: Int
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> MinuteSliderControl {
        let slider = MinuteSliderControl()
        slider.minValue = 0
        slider.maxValue = Double(SessionReusePolicy.maximumMinutes)
        slider.numberOfTickMarks = 0
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setAccessibilityLabel("Maximum saved sign-in age")
        return slider
    }

    func updateNSView(_ slider: MinuteSliderControl, context: Context) {
        context.coordinator.parent = self
        slider.integerValue = value
        slider.isEnabled = isEnabled
        slider.setAccessibilityValueDescription(value == 0 ? "Always fresh" :
            SessionReusePolicy.ageDescription(TimeInterval(value) * 60))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor final class Coordinator: NSObject {
        var parent: SessionMinuteSlider
        init(parent: SessionMinuteSlider) { self.parent = parent }

        @objc func changed(_ slider: MinuteSliderControl) {
            let minutes = Int((slider.doubleValue / 15).rounded()) * 15
            let bounded = max(0, min(minutes, SessionReusePolicy.maximumMinutes))
            slider.integerValue = bounded
            parent.value = bounded
        }
    }
}

final class MinuteSliderControl: NSSlider {
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 125: _ = adjust(to: doubleValue - 15)
        case 124, 126: _ = adjust(to: doubleValue + 15)
        case 115: _ = adjust(to: minValue)
        case 119: _ = adjust(to: maxValue)
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformIncrement() -> Bool { adjust(to: doubleValue + 15) }
    override func accessibilityPerformDecrement() -> Bool { adjust(to: doubleValue - 15) }

    private func adjust(to value: Double) -> Bool {
        guard isEnabled else { return false }
        doubleValue = min(maxValue, max(minValue, value))
        if let action { sendAction(action, to: target) }
        return true
    }
}
