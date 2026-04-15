import AppKit

// The same executable serves double duty: normally it launches the full
// SwiftUI app, but when launchd fires a scheduled backup it invokes us with
// `--run-backup <uuid>`. In that case we skip SwiftUI entirely, run the
// backup synchronously, and exit — no menu bar icon, no windows, nothing.
let args = CommandLine.arguments
if args.count >= 4, args[1] == "--run-backup" {
    ScheduledBackupRunner.run(repoIdString: args[2], scheduleIdString: args[3])
}

BorgMacApp.main()
