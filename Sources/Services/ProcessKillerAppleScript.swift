//  ProcessKillerAppleScript.swift
//  BatKill
//
//  Pure, file-level AppleScript helpers for controlling another app's window
//  visibility via `System Events` (used by ProcessKiller to hide a window
//  before suspending an app, and unhide it after resume). Extracted into a
//  separate file so ProcessKiller.swift stays under the SwiftLint file-length
//  limit and these pure functions are unit-testable (CHANGE-062).

import Foundation

/// Escapes a string for safe embedding in an AppleScript string literal:
/// backslash → `\\`, double quote → `\"`, newline → `\n`. Extracted so the
/// escaping rules are unit-testable.
func escapeAppleScriptText(_ str: String) -> String {
    str.replacingOccurrences(of: "\\", with: "\\\\")
       .replacingOccurrences(of: "\"", with: "\\\"")
       .replacingOccurrences(of: "\n", with: "\\n")
}

/// Builds an AppleScript that sets a process's visibility via `System Events`,
/// matched by the app's display name. `escapeAppleScriptText` guards against
/// script injection from a crafted display name. Extracted so the generated
/// script is unit-testable (CHANGE-062).
func appVisibilityScript(appName: String, visible: Bool) -> String {
    let target = "first process whose name is \"\(escapeAppleScriptText(appName))\""
    return "tell application \"System Events\" to set visible of \(target) to \(visible ? "true" : "false")"
}

/// The name used to match a process in `System Events` for visibility control.
/// Uses the **executable name** (`processName` = `CFBundleExecutable`), NOT the
/// display name (`name`): System Events' `name` attribute is the executable
/// name. Apps whose display name differs from their process name (e.g. WeCom:
/// list shows "wecom" but the process is "企业微信") would otherwise fail to
/// match (-1719), leaving a frozen window on screen. Extracted so the match
/// source is unit-testable (CHANGE-062 fix).
func appVisibilityMatchName(_ app: AppItem) -> String {
    app.processName
}
