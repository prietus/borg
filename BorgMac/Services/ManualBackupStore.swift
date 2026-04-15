import Foundation
import SwiftUI

/// An in-flight manual backup (user clicked "Iniciar backup" in the detail
/// sheet). Lives entirely in memory — if the app quits, the backup dies
/// with it. That's by design: we can't resume a killed borg process.
struct ManualBackupJob: Identifiable, Equatable {
    let id: UUID
    let repoId: UUID
    let repoName: String
    let archiveName: String
    let startedAt: Date
    var status: Status
    var errorMessage: String?

    enum Status: Equatable {
        case running
        case succeeded
        case failed
        case cancelled
    }

    var isTerminal: Bool {
        switch status {
        case .running:                  return false
        case .succeeded, .failed, .cancelled: return true
        }
    }
}

/// Tracks in-flight manual backups so the user can close the launch sheet
/// and keep the backup running in the background. Progress visibility lives
/// in the menu bar — the row has a cancel button that sends SIGTERM via
/// `BorgClient`'s cancellation handler.
@MainActor
final class ManualBackupStore: ObservableObject {
    @Published private(set) var jobs: [ManualBackupJob] = []

    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// Kicks off a new manual backup. Returns the job id so the caller can
    /// reference it later (cancel, dismiss). The `onCompleted` callback
    /// fires on success so the repo detail view can refresh its archives
    /// list if it happens to still be showing this repo.
    @discardableResult
    func start(
        repo: Repository,
        archiveName: String,
        paths: [String],
        excludes: [String],
        onCompleted: @escaping () -> Void
    ) -> UUID {
        let job = ManualBackupJob(
            id: UUID(),
            repoId: repo.id,
            repoName: repo.name,
            archiveName: archiveName,
            startedAt: Date(),
            status: .running,
            errorMessage: nil
        )
        jobs.append(job)

        tasks[job.id] = Task { [weak self] in
            do {
                try await BorgClient.shared.createBackup(
                    repo: repo,
                    archiveName: archiveName,
                    paths: paths,
                    excludes: excludes
                )
                await self?.finish(jobId: job.id, status: .succeeded, error: nil)
                Notifications.postSuccess(repoName: repo.name, archiveName: archiveName)
                onCompleted()
            } catch {
                if Task.isCancelled {
                    await self?.finish(jobId: job.id, status: .cancelled, error: nil)
                } else {
                    await self?.finish(
                        jobId: job.id,
                        status: .failed,
                        error: error.localizedDescription
                    )
                    Notifications.postManualFailure(
                        repoName: repo.name,
                        errorMessage: error.localizedDescription
                    )
                }
            }
        }
        return job.id
    }

    /// Sends SIGTERM to the underlying borg process via the task's
    /// cancellation handler. Leaves the job in the list (as cancelled) so
    /// the user can see it happened — they have to `dismiss` it explicitly.
    func cancel(jobId: UUID) {
        tasks[jobId]?.cancel()
    }

    /// Removes a terminal job from the list. No-op for running jobs.
    func dismiss(jobId: UUID) {
        if let idx = jobs.firstIndex(where: { $0.id == jobId }), jobs[idx].isTerminal {
            jobs.remove(at: idx)
            tasks[jobId] = nil
        }
    }

    /// Convenience for the menu bar section — newest-first, running above
    /// terminal.
    var orderedJobs: [ManualBackupJob] {
        jobs.sorted { a, b in
            if a.isTerminal != b.isTerminal { return !a.isTerminal && b.isTerminal }
            return a.startedAt > b.startedAt
        }
    }

    // MARK: - Internals

    private func finish(jobId: UUID, status: ManualBackupJob.Status, error: String?) {
        if let idx = jobs.firstIndex(where: { $0.id == jobId }) {
            jobs[idx].status = status
            jobs[idx].errorMessage = error
        }
        tasks[jobId] = nil
    }
}
