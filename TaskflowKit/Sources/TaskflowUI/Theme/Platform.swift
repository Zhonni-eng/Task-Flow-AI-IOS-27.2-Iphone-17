// Small shims for iOS-only SwiftUI API, so the interface also compiles for macOS (where the
// package is built and tested with the command line tools). On iPhone they are the real modifiers.
import SwiftUI

extension ToolbarItemPlacement {
    static var leadingBar: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    static var trailingBar: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}

extension View {
    /// Hides the navigation bar (the sidebar draws its own brand header).
    func hiddenNavigationBar() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }

    func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    func numberKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.numberPad)
        #else
        self
        #endif
    }

    func plainTextEntry() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        autocorrectionDisabled()
        #endif
    }

    func sentenceTextEntry() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.sentences)
        #else
        self
        #endif
    }

    func sectionSpacing(_ spacing: CGFloat) -> some View {
        #if os(iOS)
        listSectionSpacing(spacing)
        #else
        self
        #endif
    }

    func darkNavigationBar() -> some View {
        #if os(iOS)
        toolbarBackground(Theme.bgApp, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        #else
        self
        #endif
    }

    func sheetDetents(large: Bool = true) -> some View {
        #if os(iOS)
        presentationDetents(large ? [.large] : [.medium, .large]).presentationDragIndicator(.visible)
        #else
        self
        #endif
    }
}

extension View {
    /// Multi-selection in a List needs edit mode on iOS.
    func selectionEditMode(_ active: Bool) -> some View {
        #if os(iOS)
        environment(\.editMode, .constant(active ? .active : .inactive))
        #else
        self
        #endif
    }
}

enum Haptics {
    @MainActor static func success() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    @MainActor static func tap() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}

enum SystemSettings {
    @MainActor static func open() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #endif
    }
}

/// SwiftUI's State property wrapper under another name. On the newest SDKs `@State` is also a macro
/// whose plugin ships only with Xcode; the alias names the property wrapper itself, so the views
/// build both in Xcode and with the command line tools (`swift build`).
typealias LocalState<Value> = SwiftUI.State<Value>
