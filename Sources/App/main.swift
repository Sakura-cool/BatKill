//  Main.swift
//  BatKill
//
//  AppKit entry point using a plain @main struct (not SwiftUI's `App`
//  protocol), to avoid the persistent scene view graph that SwiftUI
//  maintains even when idle.

import AppKit

@main
enum EntryPoint {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
