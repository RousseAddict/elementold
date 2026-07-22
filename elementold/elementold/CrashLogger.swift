import Foundation

// Simple debug-only crash reporter for this ad-hoc/no-Xcode-console pipeline.
//
// Earlier version redirected stderr via freopen() at launch — that turned out
// to be risky enough on this legacy runtime that it looked like it caused a
// crash-at-launch itself. This version does nothing invasive at startup: it
// just installs an NSException handler + a few POSIX signal handlers that
// stash a short message in UserDefaults (no FILE*/stream surgery, no file
// I/O in the handler itself), then reads it back and clears it on the next
// launch.
//
// Bug fixed here: an uncaught NSException's default Foundation handler calls
// abort() right after invoking our NSSetUncaughtExceptionHandler callback —
// which raises SIGABRT and fires our *signal* handler too. That signal
// handler was unconditionally overwriting the detailed NSException message
// (name/reason/callstack) with a generic "Signal 6" string, so we were
// always seeing the useless generic message instead of the real crash
// reason. `capturedException` now gates the signal handler so it only
// writes the generic message if the exception handler didn't already record
// something more specific.
private var capturedException = false

enum CrashLogger {
    private static let defaultsKey = "elementold.lastCrashLog"

    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            let msg = "NSException: \(exception.name.rawValue)\n\(exception.reason ?? "(no reason)")\n"
                + exception.callStackSymbols.joined(separator: "\n")
            UserDefaults.standard.set(msg, forKey: CrashLogger.defaultsKey)
            UserDefaults.standard.synchronize()
            capturedException = true
        }
        for sig in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP] {
            signal(sig) { s in
                if !capturedException {
                    UserDefaults.standard.set("Signal \(s) (fatal error / trap / force-unwrap crash, no NSException)",
                                               forKey: CrashLogger.defaultsKey)
                    UserDefaults.standard.synchronize()
                }
                exit(s)
            }
        }
    }

    // The last recorded crash message, if any. Read on demand (Settings →
    // Diagnostics) rather than popped up at launch — reading does NOT clear it,
    // so it stays inspectable until the next crash overwrites it or the user
    // clears it explicitly.
    static var lastCrash: String? {
        return UserDefaults.standard.string(forKey: defaultsKey)
    }

    static func clearCrash() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.synchronize()
    }
}
