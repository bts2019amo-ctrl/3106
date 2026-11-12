import Foundation

enum DevicePatchService {
    static func apply(project: PatchProject) throws -> PatchTransactionReceipt {
        let bundleIDs = orderedBundleIdentifiers(in: project)
        return try withResolvedContainers(bundleIDs: bundleIDs) { roots in
            try PatchTransaction.apply(
                project: project,
                backupRoot: try PatchProjectLibrary.backupRootURL(),
                containerResolver: { bundleID in
                    guard let root = roots[bundleID] else {
                        throw PatchPackageError.targetAppUnavailable(bundleID)
                    }
                    return root
                },
                backupCenter: .shared
            )
        }
    }

    static func inspectRestore(receipt: PatchTransactionReceipt) throws -> PatchRestoreInspection {
        let bundleIDs = try PatchTransaction.requiredBundleIdentifiers(for: receipt)
        return try withResolvedContainers(bundleIDs: bundleIDs) { roots in
            try PatchTransaction.inspectRestore(
                receipt: receipt,
                containerResolver: { bundleID in
                    guard let root = roots[bundleID] else {
                        throw PatchPackageError.targetAppUnavailable(bundleID)
                    }
                    return root
                }
            )
        }
    }

    static func restore(
        receipt: PatchTransactionReceipt,
        allowChangedTargets: Bool = false
    ) throws {
        let bundleIDs = try PatchTransaction.requiredBundleIdentifiers(for: receipt)
        try withResolvedContainers(bundleIDs: bundleIDs) { roots in
            try PatchTransaction.restore(
                receipt: receipt,
                allowChangedTargets: allowChangedTargets,
                containerResolver: { bundleID in
                    guard let root = roots[bundleID] else {
                        throw PatchPackageError.targetAppUnavailable(bundleID)
                    }
                    return root
                }
            )
        }
    }

    static func resetToAppliedState(
        receipt: PatchTransactionReceipt,
        project: PatchProject
    ) throws {
        let bundleIDs = try PatchTransaction.requiredBundleIdentifiers(for: receipt)
        try withResolvedContainers(bundleIDs: bundleIDs) { roots in
            try PatchTransaction.resetToAppliedState(
                receipt: receipt,
                fallbackProject: project,
                containerResolver: { bundleID in
                    guard let root = roots[bundleID] else {
                        throw PatchPackageError.targetAppUnavailable(bundleID)
                    }
                    return root
                }
            )
        }
    }

    static func latestReceipt(projectID: UUID) -> PatchTransactionReceipt? {
        guard let backupRoot = try? PatchProjectLibrary.backupRootURL() else { return nil }
        return PatchTransaction.latestReceipt(projectID: projectID, backupRoot: backupRoot)
    }

    private static func orderedBundleIdentifiers(in project: PatchProject) -> [String] {
        project.allBundleIdentifiers
    }

    /// Resolve every target container for the active backend (kernel / bad_query /
    /// worse_query), hold grants for the whole transaction, then run `operation`.
    /// Works on iOS 17/18/26/27.
    private static func withResolvedContainers<T>(
        bundleIDs: [String],
        operation: ([String: URL]) throws -> T
    ) throws -> T {
        var roots: [String: URL] = [:]
        var grants: [Int64] = []
        defer {
            for grant in grants { SandboxAccess.release(grant) }
        }

        prepareSandboxAccessForPatch(grants: &grants)

        for bundleID in bundleIDs {
            guard let path = resolveContainerPathRobust(bundleID: bundleID) else {
                log("patch: FAILED to resolve container for \(bundleID) backend=\(SandboxAccess.backend.displayName)")
                throw PatchPackageError.targetAppUnavailable(bundleID)
            }

            // Per-container + Library grants (no-op / -1 on kernel backend).
            let grant = ContainerStore.grantContainerAccess(path)
            if grant >= 0 { grants.append(grant) }
            let libraryPath = (path as NSString).appendingPathComponent("Library")
            let libraryGrant = ContainerStore.grantContainerAccess(libraryPath)
            if libraryGrant >= 0 { grants.append(libraryGrant) }

            roots[bundleID] = PatchPathValidator.canonicalFileURL(
                URL(fileURLWithPath: path, isDirectory: true)
            )
            log("patch: resolved \(bundleID) -> \(path)")
        }
        return try operation(roots)
    }

    private static func prepareSandboxAccessForPatch(grants: inout [Int64]) {
        switch SandboxAccess.backend {
        case .kernel:
            // Kernel R/W — no container grants needed.
            log("patch: kernel backend — no sandbox grants required")
        case .badQuery:
            if !SandboxAccess.lastProbeSucceeded {
                let ok = SandboxAccess.probe()
                log("patch: pre-apply bad_query probe \(ok ? "OK" : "FAILED")")
            }
            let rootGrant = ContainerStore.grantContainerAccess(ContainerStore.appDataRoot)
            if rootGrant >= 0 {
                grants.append(rootGrant)
                log("patch: held app-data root grant (bad_query)")
            }
        case .worseQuery:
            if !SandboxAccess.lastProbeSucceeded {
                let ok = SandboxAccess.probe()
                log("patch: pre-apply worse_query probe \(ok ? "OK" : "FAILED")")
            }
            let rootGrant = ContainerStore.grantContainerAccess(ContainerStore.appDataRoot)
            if rootGrant >= 0 {
                grants.append(rootGrant)
                log("patch: held app-data root grant (worse_query)")
            } else {
                log("patch: app-data root grant failed (\(rootGrant)) — using per-container grants")
            }
            // Warm path↔identifier maps used on 26.7+/27.x.
            _ = worse_query_path_identifiers()
        case .unsupported:
            log("patch: unsupported backend")
        }
    }

    /// Multi-source resolve for all backends. worse_query path gets an extra
    /// index refresh + direct map lookup on miss (iOS 26.7+/27.x).
    private static func resolveContainerPathRobust(bundleID: String) -> String? {
        if let path = ContainerStore.resolveAppContainerPath(bundleID: bundleID),
           ContainerStore.isApplicationContainerPath(path) {
            return normalizeContainerPath(path)
        }

        if SandboxAccess.backend == .worseQuery {
            _ = worse_query_path_identifiers()
            if let path = ContainerStore.resolveAppContainerPath(bundleID: bundleID),
               ContainerStore.isApplicationContainerPath(path) {
                log("patch: resolved \(bundleID) after index refresh")
                return normalizeContainerPath(path)
            }
            let idToPath = worse_query_identifier_paths()
            if let mapped = idToPath[bundleID],
               ContainerStore.isApplicationContainerPath(mapped) {
                return normalizeContainerPath(mapped)
            }
            let pathToID = worse_query_path_identifiers()
            for (path, identifier) in pathToID {
                if identifier == bundleID, ContainerStore.isApplicationContainerPath(path) {
                    return normalizeContainerPath(path)
                }
            }
        }

        // Last resort: metadata / inode scan (works when sandbox or kernel access is live).
        if let scanned = ContainerStore.resolveAppContainerPathByMetadataScan(bundleID: bundleID),
           ContainerStore.isApplicationContainerPath(scanned) {
            log("patch: resolved \(bundleID) via metadata scan")
            return normalizeContainerPath(scanned)
        }
        return nil
    }

    private static func normalizeContainerPath(_ path: String) -> String {
        if path.hasPrefix("/var/"), !path.hasPrefix("/private/") {
            return "/private" + path
        }
        return path
    }
}
