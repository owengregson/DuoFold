import AppKit

/// `kill`, ctrl-c in a terminal and launchd tearing a session down send
/// signals whose default action ends the process without
/// `applicationWillTerminate`, which puts the lid sensor's report interval
/// back. That interval outlives the process, so these signals are routed
/// through an ordinary quit instead. SIGKILL cannot be; `lidprobe reset`
/// restores the interval after one.
@MainActor
enum TerminationSignals {
    private static var sources: [DispatchSourceSignal] = []

    static func routeToTerminate() {
        guard sources.isEmpty else { return }
        for number in [SIGTERM, SIGINT, SIGHUP] {
            // The dispatch source sees the signal only once the default
            // action, which ends the process at once, is out of the way.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
            source.resume()
            sources.append(source)
        }
    }
}
