//  BatKillFanCLI.swift
//  BatKill
//
//  Standalone privileged CLI entry point for fan writes (CHANGE-019).
//
//  Installed to /usr/local/BatKill/batkill-fan (root-owned) and invoked by
//  the app via `sudo -n`. Reuses handleCLIArgs() so the same whitelist
//  validation governs both the in-app CLI path and the sudo path.

import Foundation

@main
struct BatKillFanCLI {
    static func main() {
        if handleCLIArgs() { exit(0) }
        // No recognized fan-write argument → non-CLI invocation.
        fputs("batkill-fan: expected --set-fan <index> <speed> or --set-fan-mode <index> <0|1>\n",
              stderr)
        exit(2)
    }
}
