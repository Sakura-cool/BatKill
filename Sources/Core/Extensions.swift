//  Extensions.swift
//  BatKill
//
//  Shared Swift extensions used across multiple source files.
//  Contains:
//    - Binding.onChange: A macOS 13-compatible wrapper that fires a handler
//      whenever the binding value changes (replaces the native .onChange modifier).
//    - Notification.Name: Custom notification names used for inter-component
//      communication (e.g., opening settings or temperature windows from the menu bar).
//
//  Extracted from: ContentView.swift (Binding.onChange), MenuBarManager.swift (Notification.Name)

import SwiftUI

// MARK: - Binding onChange Extension

extension Binding {
    /// Returns a new `Binding` that fires `handler` whenever the wrapped value is set.
    ///
    /// This is a compatibility shim for macOS 13 / iOS 16 where the native
    /// `.onChange(of:)` view modifier behaves differently. By wrapping the binding
    /// itself, the callback fires on every `wrappedValue` write — including from
    /// child views — without requiring the parent to observe a separate state.
    ///
    /// Usage:
    /// ```swift
    /// Toggle(isOn: $enabled.onChange { newValue in
    ///     print("Toggled to \(newValue)")
    /// })
    /// ```
    ///
    /// - Parameter handler: Closure called with the new value after each write.
    /// - Returns: A `Binding<Value>` that delegates to the original binding and invokes `handler`.
    func onChange(_ handler: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(
            get: { self.wrappedValue },
            set: { newValue in
                self.wrappedValue = newValue
                handler(newValue)
            }
        )
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when the user requests the settings/preferences window to open.
    /// Listened by: `MenuBarManager` (right-click menu) and `AppDelegate`.
    static let showSettings = Notification.Name("showSettings")

    /// Posted when the user requests the temperature monitoring window to open.
    /// Listened by: `MenuBarManager` (menu bar temperature icon) and `AppDelegate`.
    static let showTemperature = Notification.Name("showTemperature")
}
