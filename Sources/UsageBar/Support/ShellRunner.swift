import Foundation

// A one-shot Process wrapper that returns stdout on success (exit 0), nil
// otherwise, and hard-terminates the process after `timeout` seconds.  Used
// for `security find-generic-password` which can hang on a first-run
// permission dialog that no one dismisses.
enum ShellRunner {

    struct DetailedResult {
        let exit: Int32
        let stdout: String
        let stderr: String
    }

    static func run(_ path: String, args: [String], timeout: TimeInterval) -> String? {
        let r = runDetailed(path, args: args, timeout: timeout)
        guard r.exit == 0 else { return nil }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Same as `run`, but never returns nil — always yields exit + both streams
    /// so callers (like Keychain deletion) can react to specific error codes.
    static func runDetailed(_ path: String, args: [String], timeout: TimeInterval) -> DetailedResult {
        let task = Process()
        task.launchPath = path
        task.arguments = args
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do { try task.run() } catch {
            return DetailedResult(exit: -1, stdout: "", stderr: "\(error)")
        }

        let deadline = DispatchTime.now() + timeout
        let killer = DispatchWorkItem { [weak task] in
            guard let t = task, t.isRunning else { return }
            t.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: deadline, execute: killer)

        task.waitUntilExit()
        killer.cancel()

        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        return DetailedResult(exit: task.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
