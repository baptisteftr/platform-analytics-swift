import SwiftUI
import os

extension View {
    /// Émet `$screen` avec ce nom quand la vue apparaît (`onAppear`). Un même nom émis deux fois de suite
    /// en moins d'une seconde (rafraîchissement de vue) ne compte qu'une fois.
    public func analyticsScreen(_ name: String, props: [String: PropValue] = [:]) -> some View {
        modifier(AnalyticsScreenModifier(name: name, props: props))
    }
}

struct AnalyticsScreenModifier: ViewModifier {
    let name: String
    let props: [String: PropValue]

    func body(content: Content) -> some View {
        content.onAppear {
            if Self.deduplicator.withLock({ $0.shouldEmit(name, at: Date()) }) {
                Analytics.screen(name, props: props)
            }
        }
    }

    static let deduplicator = OSAllocatedUnfairLock(initialState: Deduplicator())

    /// Mémorise le dernier écran émis par le modificateur (tous écrans confondus).
    struct Deduplicator: Sendable {
        static let window: TimeInterval = 1
        private var last: (name: String, at: Date)?

        mutating func shouldEmit(_ name: String, at date: Date) -> Bool {
            if let last, last.name == name, date.timeIntervalSince(last.at) < Self.window, date >= last.at {
                return false
            }
            last = (name, date)
            return true
        }
    }
}
