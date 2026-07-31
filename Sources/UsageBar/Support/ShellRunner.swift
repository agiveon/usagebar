import Foundation

// A one-shot Process wrapper that returns stdout on success (exit 0), nil
// otherwise, and hard-terminates the process after `timeout` seconds.  Used
// for `security find-generic-password` which can hang on a first-run
// permission dialog that no one dismisses.
enum ShellRunner {

    static func run(_ path: String, args: [String], timeout: TimeInterval) -> String? {
        let task = Process()
        task.launchPath = path
        task.arguments = args
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do { try task.run() } catch { return nil }

        // Fire a timer that terminates the process if it outlives `timeout`.
        let deadline = DispatchTime.now() + timeout
        let killer = DispatchWorkItem { [weak task] in
            guard let t = task, t.isRunning else { return }
            t.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: deadline, execute: killer)

        task.waitUntilExit()
        killer.cancel()

        guard task.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
