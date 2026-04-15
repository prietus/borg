import Foundation

/// A discovered SSH private key on the local machine.
struct LocalSSHKey: Identifiable, Hashable {
    var id: String { privatePath }
    let privatePath: String
    let publicPath: String
    let type: String        // ed25519, rsa, ecdsa, dsa, …
    let comment: String

    var displayName: String {
        let filename = (privatePath as NSString).lastPathComponent
        if comment.isEmpty {
            return "\(filename) (\(type))"
        }
        return "\(filename) (\(type)) — \(comment)"
    }
}

/// Lists private SSH keys under `~/.ssh` by pairing each non-`.pub` file with
/// a matching `.pub` and parsing its first line for the algorithm + comment.
enum SSHKeyDiscovery {
    private static let blacklistedNames: Set<String> = [
        "config", "known_hosts", "known_hosts.old",
        "authorized_keys", "authorized_keys2",
        "environment", "rc",
    ]
    private static let blacklistedExtensions: Set<String> = [
        "pub", "old", "bak", "crt",
    ]

    static func list() -> [LocalSSHKey] {
        let sshDir = ("~/.ssh" as NSString).expandingTildeInPath
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: sshDir) else {
            return []
        }
        var result: [LocalSSHKey] = []
        for file in entries {
            if file.hasPrefix(".") { continue }
            if blacklistedNames.contains(file) { continue }
            let ext = (file as NSString).pathExtension
            if blacklistedExtensions.contains(ext) { continue }

            let privatePath = "\(sshDir)/\(file)"
            let publicPath = "\(privatePath).pub"
            guard FileManager.default.fileExists(atPath: publicPath) else { continue }

            guard let raw = try? String(contentsOfFile: publicPath, encoding: .utf8) else {
                continue
            }
            let line = raw
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let typeRaw = String(parts[0])
            let type = typeRaw.replacingOccurrences(of: "ssh-", with: "")
            let comment = parts.count >= 3 ? String(parts[2]) : ""

            result.append(LocalSSHKey(
                privatePath: privatePath,
                publicPath: publicPath,
                type: type,
                comment: comment
            ))
        }
        return result.sorted { $0.privatePath < $1.privatePath }
    }
}

enum SSHKeyGenError: LocalizedError {
    case keygenFailed(String)
    case readPublicKeyFailed

    var errorDescription: String? {
        switch self {
        case .keygenFailed(let msg):
            return "ssh-keygen failed: \(msg)"
        case .readPublicKeyFailed:
            return "Could not read the generated public key"
        }
    }
}

enum SSHKeyGen {
    /// Generates a new ed25519 key pair under `~/.ssh/borgmac_<slug>` with no
    /// passphrase. Returns the private key path and the public key contents
    /// (the full single line, ready to upload to BorgBase).
    /// If a key with the same path already exists it is reused (no overwrite).
    static func generate(slug: String, comment: String) throws -> (privatePath: String, publicKey: String) {
        let sshDir = ("~/.ssh" as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(
            atPath: sshDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let safeSlug = slug
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        let privatePath = "\(sshDir)/borgmac_\(safeSlug)"
        let publicPath = "\(privatePath).pub"

        if !FileManager.default.fileExists(atPath: privatePath) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            process.arguments = [
                "-t", "ed25519",
                "-f", privatePath,
                "-N", "",
                "-C", comment,
                "-q",
            ]
            let stderr = Pipe()
            process.standardError = stderr
            process.standardOutput = Pipe()
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let err = String(
                    data: stderr.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                throw SSHKeyGenError.keygenFailed(err)
            }
        }

        guard let pubKeyContents = try? String(contentsOfFile: publicPath, encoding: .utf8) else {
            throw SSHKeyGenError.readPublicKeyFailed
        }
        let trimmed = pubKeyContents.trimmingCharacters(in: .whitespacesAndNewlines)
        return (privatePath, trimmed)
    }
}
