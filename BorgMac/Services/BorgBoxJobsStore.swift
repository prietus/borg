import Foundation
import SwiftUI

/// Tracks in-flight BorgBox daemon jobs (check / prune / compact / …) and
/// subscribes to `GET /jobs/<id>/stream` for live log + status updates.
///
/// Scoped per panel instance — `BorgBoxServerPanel` holds a `@StateObject`
/// of this type so streams are torn down automatically when the panel closes.
@MainActor
final class BorgBoxJobsStore: ObservableObject {
    @Published private(set) var jobs: [String: BorgBoxJob] = [:]
    /// Live log tail accumulated from SSE `log` events. Keyed by job id.
    /// Capped per-job so a chatty borg run doesn't grow unbounded.
    @Published private(set) var logs: [String: [String]] = [:]

    private var streamTasks: [String: Task<Void, Never>] = [:]

    private static let maxLogLines = 500

    /// Registers a freshly started job and opens its event stream.
    func register(initial: BorgBoxJobStart, kind: String, repo: String, server: BorgBoxServer) {
        let placeholder = BorgBoxJob(
            id: initial.jobId,
            repo: repo,
            kind: kind,
            status: initial.status,
            startedAt: nil,
            finishedAt: nil,
            exitCode: nil,
            logTail: nil
        )
        jobs[placeholder.id] = placeholder
        logs[placeholder.id] = []
        startStreaming(jobId: placeholder.id, server: server)
    }

    /// Seed the store with a snapshot from `GET /jobs` — typically called
    /// when the panel opens, so any job that started before the app launched
    /// shows up immediately. Non-terminal jobs get a live stream attached.
    func hydrate(from list: [BorgBoxJob], server: BorgBoxServer) {
        for job in list {
            if jobs[job.id] != nil { continue }
            jobs[job.id] = job
            // Prime the live log buffer with whatever snapshot the REST
            // endpoint returned so the UI doesn't flash an empty area
            // while the stream reconnects.
            logs[job.id] = job.logTail ?? []
            if !job.isTerminal {
                startStreaming(jobId: job.id, server: server)
            }
        }
    }

    /// User dismissed the job from the drawer — stop streaming and drop state.
    func dismiss(jobId: String) {
        streamTasks[jobId]?.cancel()
        streamTasks[jobId] = nil
        jobs.removeValue(forKey: jobId)
        logs.removeValue(forKey: jobId)
    }

    /// Sorted view for the UI — active jobs above terminal ones, newest-first.
    var orderedJobs: [BorgBoxJob] {
        jobs.values.sorted { a, b in
            if a.isTerminal != b.isTerminal {
                return !a.isTerminal && b.isTerminal
            }
            return (a.startedAt ?? "") > (b.startedAt ?? "")
        }
    }

    // MARK: - Streaming

    private func startStreaming(jobId: String, server: BorgBoxServer) {
        streamTasks[jobId]?.cancel()
        streamTasks[jobId] = Task { [weak self] in
            print("[BorgBoxJobsStore] opening SSE stream for job \(jobId)")
            do {
                let stream = try BorgBoxClient.shared.streamJob(server: server, jobId: jobId)
                for try await event in stream {
                    if Task.isCancelled { break }
                    print("[BorgBoxJobsStore] event type=\(event.type) line=\(event.line?.prefix(80) ?? "") status=\(event.status ?? "")")
                    self?.apply(event: event, jobId: jobId)
                }
                print("[BorgBoxJobsStore] stream closed cleanly for job \(jobId)")
            } catch {
                print("[BorgBoxJobsStore] stream threw for job \(jobId): \(error)")
                if let finalJob = try? await BorgBoxClient.shared.job(server: server, jobId: jobId) {
                    await MainActor.run { self?.jobs[jobId] = finalJob }
                }
            }
            // Stream closed cleanly: pull the final job state so the UI has
            // authoritative exit_code / finished_at fields that aren't sent
            // over SSE directly.
            if let finalJob = try? await BorgBoxClient.shared.job(server: server, jobId: jobId) {
                await MainActor.run { self?.jobs[jobId] = finalJob }
            }
            await MainActor.run { self?.streamTasks[jobId] = nil }
        }
    }

    private func apply(event: BorgBoxJobStreamEvent, jobId: String) {
        switch event.type {
        case "log":
            if let line = event.line, !line.isEmpty {
                var buffer = logs[jobId] ?? []
                buffer.append(line)
                if buffer.count > Self.maxLogLines {
                    buffer.removeFirst(buffer.count - Self.maxLogLines)
                }
                logs[jobId] = buffer
            }
        case "status":
            if let current = jobs[jobId], let newStatus = event.status, !newStatus.isEmpty {
                jobs[jobId] = BorgBoxJob(
                    id: current.id,
                    repo: current.repo,
                    kind: current.kind,
                    status: newStatus,
                    startedAt: current.startedAt,
                    finishedAt: current.finishedAt,
                    exitCode: event.exitCode ?? current.exitCode,
                    logTail: current.logTail
                )
            }
        case "end":
            break // the outer stream loop will exit on its own
        default:
            break
        }
    }
}
