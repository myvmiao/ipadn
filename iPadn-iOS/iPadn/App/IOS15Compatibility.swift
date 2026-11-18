import SwiftUI
import UIKit

// MARK: - iOS 15 compatibility layer
//
// iPadn targets iOS 16 by default. This file backports the small set of
// iOS 16-only SwiftUI conveniences the app relies on so the same source can
// also build for iOS 15 (TrollStore on 15.x). Everything that has a native
// iOS 16 implementation keeps using it; the fallbacks only run on iOS 15.

// MARK: Navigation

/// A navigation container without a programmatic path. Uses `NavigationStack`
/// on iOS 16+, and a plain stack-styled `NavigationView` on iOS 15.
struct CompatStack<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack { content }
        } else {
            NavigationView { content }
                .navigationViewStyle(.stack)
        }
    }
}

/// A navigation container driven by a typed path. `NavigationStack` already
/// accepts `Binding<[Route]>`, so iOS 16+ keeps the native behaviour. On iOS 15
/// the path is rendered as a chain of hidden `NavigationLink`s, which pushes
/// one `NavigationView` level per path element.
struct CompatPathStack<Route: Hashable, Content: View>: View {
    @Binding private var path: [Route]
    private let content: Content
    private let destination: (Route) -> AnyView

    init<Destination: View>(
        path: Binding<[Route]>,
        @ViewBuilder content: () -> Content,
        @ViewBuilder destination: @escaping (Route) -> Destination
    ) {
        self._path = path
        self.content = content()
        self.destination = { AnyView(destination($0)) }
    }

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack(path: $path) {
                content.navigationDestination(for: Route.self) { destination($0) }
            }
        } else {
            NavigationView {
                LegacyStackLevel(path: $path, depth: 0, destination: destination) { content }
            }
            .navigationViewStyle(.stack)
            .environment(\.compatRouteResolver, { any in
                guard let route = any.base as? Route else { return AnyView(EmptyView()) }
                return destination(route)
            })
        }
    }
}

/// One level of the iOS 15 path emulation. Each level owns the link to the
/// next one, so popping (including the interactive back gesture) truncates
/// the bound path in the same way `NavigationStack` does.
private struct LegacyStackLevel<Route: Hashable, Content: View>: View {
    @Binding var path: [Route]
    let depth: Int
    let destination: (Route) -> AnyView
    let content: () -> Content

    init(
        path: Binding<[Route]>,
        depth: Int,
        destination: @escaping (Route) -> AnyView,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self._path = path
        self.depth = depth
        self.destination = destination
        self.content = content
    }

    var body: some View {
        content()
            .background(link)
    }

    private var link: some View {
        NavigationLink(isActive: Binding(
            get: { path.count > depth },
            set: { isActive in
                if !isActive, path.count > depth {
                    path = Array(path.prefix(depth))
                }
            }
        )) {
            if path.count > depth {
                LegacyStackLevel(path: $path, depth: depth + 1, destination: destination) {
                    destination(path[depth])
                }
            }
        } label: {
            EmptyView()
        }
        .hidden()
    }
}

private struct CompatRouteResolverKey: EnvironmentKey {
    static let defaultValue: ((AnyHashable) -> AnyView)? = nil
}

extension EnvironmentValues {
    /// Resolves a value-based navigation route on iOS 15, where
    /// `NavigationLink(value:)` does not exist.
    var compatRouteResolver: ((AnyHashable) -> AnyView)? {
        get { self[CompatRouteResolverKey.self] }
        set { self[CompatRouteResolverKey.self] = newValue }
    }
}

/// `NavigationLink(value:)` for iOS 15+.
struct CompatNavigationLink<Route: Hashable, Label: View>: View {
    private let value: Route
    private let label: Label
    @Environment(\.compatRouteResolver) private var resolver

    init(value: Route, @ViewBuilder label: () -> Label) {
        self.value = value
        self.label = label()
    }

    var body: some View {
        if #available(iOS 16.0, *) {
            NavigationLink(value: value) { label }
        } else if let resolver {
            NavigationLink {
                resolver(AnyHashable(value))
            } label: {
                label
            }
        } else {
            // No registered destination (debug-only stacks). Keep the row
            // visible instead of dropping it.
            label
        }
    }
}

extension View {
    /// `navigationDestination(isPresented:)` for iOS 15+.
    @ViewBuilder
    func compatNavigationDestination<Destination: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        if #available(iOS 16.0, *) {
            navigationDestination(isPresented: isPresented, destination: destination)
        } else {
            background(
                NavigationLink(isActive: isPresented) {
                    destination()
                } label: {
                    EmptyView()
                }
                .hidden()
            )
        }
    }
}

// MARK: LabeledContent

/// Backport of SwiftUI's `LabeledContent`. Declared in the app module so it
/// shadows the iOS 16 type on every OS version and keeps all 70 call sites
/// source-compatible. Renders like a list row: primary label, secondary value
/// aligned trailing.
struct LabeledContent<Label: View, Content: View>: View {
    private let label: Label
    private let content: Content

    init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.content = content()
        self.label = label()
    }

    init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) where Label == Text {
        self.init(content: content) { Text(titleKey) }
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) where Label == Text {
        self.init(content: content) { Text(title) }
    }

    init(_ titleKey: LocalizedStringKey, value: String) where Label == Text, Content == Text {
        self.init(content: { Text(verbatim: value) }) { Text(titleKey) }
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, value: String) where Label == Text, Content == Text {
        self.init(content: { Text(verbatim: value) }) { Text(title) }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            label.foregroundStyle(.primary)
            Spacer(minLength: 12)
            content
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: Presentation

enum CompatDetent: Hashable {
    case medium
    case large
    case height(CGFloat)
}

extension View {
    @ViewBuilder
    func compatPresentationDetents(_ detents: [CompatDetent]) -> some View {
        if #available(iOS 16.0, *) {
            presentationDetents(Set(detents.map { detent -> PresentationDetent in
                switch detent {
                case .medium: return .medium
                case .large: return .large
                case .height(let height): return .height(height)
                }
            }))
        } else {
            self
        }
    }

    @ViewBuilder
    func compatPresentationDragIndicator(_ visibility: Visibility = .automatic) -> some View {
        if #available(iOS 16.0, *) {
            presentationDragIndicator(visibility)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatInteractiveKeyboardDismissal() -> some View {
        if #available(iOS 16.0, *) {
            scrollDismissesKeyboard(.interactively)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatHideScrollContentBackground() -> some View {
        if #available(iOS 16.0, *) {
            scrollContentBackground(.hidden)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatScrollDisabled(_ disabled: Bool) -> some View {
        if #available(iOS 16.0, *) {
            scrollDisabled(disabled)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatTabBarChrome() -> some View {
        if #available(iOS 16.0, *) {
            toolbarBackground(.visible, for: .tabBar)
                .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        } else {
            self
        }
    }

    /// `View.fontWeight` is iOS 16; call sites that already receive `Text`
    /// keep using `Text.fontWeight` directly.
    @ViewBuilder
    func compatFontWeight(_ weight: Font.Weight) -> some View {
        if #available(iOS 16.0, *) {
            fontWeight(weight)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatContentTransitionOpacity() -> some View {
        if #available(iOS 16.0, *) {
            contentTransition(.opacity)
        } else {
            self
        }
    }

    @ViewBuilder
    func compatNumericTextTransition() -> some View {
        if #available(iOS 16.0, *) {
            contentTransition(.numericText())
        } else {
            self
        }
    }

    @ViewBuilder
    func compatAccessibilityActions<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if #available(iOS 16.0, *) {
            accessibilityActions(content)
        } else {
            self
        }
    }
}

// MARK: Sharing

/// `ShareLink` for iOS 15+. The value is held type-erased so URL and String
/// call sites share one implementation.
struct CompatShareLink<Label: View>: View {
    private let item: Any
    private let label: Label
    @State private var presenting = false

    init(item: URL, @ViewBuilder label: () -> Label) {
        self.item = item
        self.label = label()
    }

    init(item: String, @ViewBuilder label: () -> Label) {
        self.item = item
        self.label = label()
    }

    var body: some View {
        if #available(iOS 16.0, *) {
            if let url = item as? URL {
                ShareLink(item: url) { label }
            } else if let string = item as? String {
                ShareLink(item: string) { label }
            } else {
                label
            }
        } else {
            Button {
                presenting = true
            } label: {
                label
            }
            .sheet(isPresented: $presenting) {
                ShareSheet(items: [item])
            }
        }
    }
}

// MARK: Async sleep

/// `Task.sleep(for:)` takes a `Duration` (iOS 16). The nanosecond API is
/// available everywhere the app runs.
@inline(__always)
func compatSleep(seconds: Double) async throws {
    try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
}

@inline(__always)
func compatSleep(milliseconds: Double) async throws {
    try await Task.sleep(nanoseconds: UInt64(max(0, milliseconds) * 1_000_000))
}

// MARK: Geometry reporting

private struct CompatGeometryPreferenceKey<T: Equatable>: PreferenceKey {
    typealias Value = T?
    static var defaultValue: T? { nil }
    static func reduce(value: inout T?, nextValue: () -> T?) {
        if let next = nextValue() { value = next }
    }
}

extension View {
    /// `onGeometryChange(for:of:action:)` is iOS 16; on iOS 15 the same values
    /// are reported through a background `GeometryReader` and a preference.
    @ViewBuilder
    func compatOnGeometryChange<Value: Equatable>(
        for type: Value.Type = Value.self,
        of transform: @escaping (GeometryProxy) -> Value,
        action: @escaping (Value) -> Void
    ) -> some View {
        if #available(iOS 16.0, *) {
            onGeometryChange(for: type, of: transform, action: action)
        } else {
            background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: CompatGeometryPreferenceKey<Value>.self,
                        value: transform(proxy)
                    )
                }
            )
            .onPreferenceChange(CompatGeometryPreferenceKey<Value>.self) { value in
                if let value { action(value) }
            }
        }
    }
}

// MARK: Adaptive stack

/// Replaces `AnyLayout(VStackLayout/HStackLayout)` switches on iOS 15, where
/// `AnyLayout` does not exist.
struct AdaptiveStack<Content: View>: View {
    private let isVertical: Bool
    private let verticalAlignment: HorizontalAlignment
    private let verticalSpacing: CGFloat
    private let horizontalAlignment: VerticalAlignment
    private let horizontalSpacing: CGFloat
    private let content: Content

    init(
        isVertical: Bool,
        verticalAlignment: HorizontalAlignment = .leading,
        verticalSpacing: CGFloat,
        horizontalAlignment: VerticalAlignment = .firstTextBaseline,
        horizontalSpacing: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.isVertical = isVertical
        self.verticalAlignment = verticalAlignment
        self.verticalSpacing = verticalSpacing
        self.horizontalAlignment = horizontalAlignment
        self.horizontalSpacing = horizontalSpacing
        self.content = content()
    }

    var body: some View {
        if isVertical {
            VStack(alignment: verticalAlignment, spacing: verticalSpacing) { content }
        } else {
            HStack(alignment: horizontalAlignment, spacing: horizontalSpacing) { content }
        }
    }
}
