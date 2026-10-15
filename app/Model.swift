import AppKit
import SwiftUI
import Foundation
import Observation

/// Zero-copy view over the Rust engine's flat tree arrays.
/// Read-only after init, so sharing it across threads is safe.
nonisolated final class Tree: @unchecked Sendable {
    private let handle: OpaquePointer
    let count: Int
    let parents: UnsafePointer<UInt32>
    let alloc: UnsafePointer<UInt64>
    let logical: UnsafePointer<UInt64>
    let nFiles: UnsafePointer<UInt32>
    let flags: UnsafePointer<UInt8>
    let childOff: UnsafePointer<UInt32>
    let childArr: UnsafePointer<UInt32>
    let nameOff: UnsafePointer<UInt32>
    let nameBlob: UnsafePointer<UInt8>
    let cleanupCount: Int
    let cleanupNodes: UnsafePointer<UInt32>
    let errors: UInt64

    init?(handle: OpaquePointer) {
        let n = bz_take_tree(handle)
        guard n > 0,
              let parents = bz_parents(handle),
              let alloc = bz_alloc(handle),
              let logical = bz_logical(handle),
              let nFiles = bz_nfiles(handle),
              let flags = bz_flags(handle),
              let childOff = bz_child_off(handle),
              let childArr = bz_children(handle),
              let nameOff = bz_name_off(handle),
              let nameBlob = bz_name_blob(handle),
              let cleanupNodes = bz_cleanup_nodes(handle)
        else { return nil }
        self.handle = handle
        self.count = Int(n)
        self.parents = parents
        self.alloc = alloc
        self.logical = logical
        self.nFiles = nFiles
        self.flags = flags
        self.childOff = childOff
        self.childArr = childArr
        self.nameOff = nameOff
        self.nameBlob = nameBlob
        self.cleanupCount = Int(bz_cleanup_count(handle))
        self.cleanupNodes = cleanupNodes
        self.errors = bz_errors(handle)
    }

    deinit { bz_free(handle) }

    func isDir(_ i: Int) -> Bool { flags[i] & 1 != 0 }

    func cleanupDescription(_ index: Int) -> String {
        guard let label = bz_cleanup_description(handle, UInt64(index)) else { return "" }
        return String(cString: label)
    }

    func name(_ i: Int) -> String {
        let start = Int(nameOff[i])
        let end = Int(nameOff[i + 1])
        let buf = UnsafeBufferPointer(start: nameBlob + start, count: end - start)
        return String(decoding: buf, as: UTF8.self)
    }

    func children(_ i: Int) -> UnsafeBufferPointer<UInt32> {
        let start = Int(childOff[i])
        let end = Int(childOff[i + 1])
        return UnsafeBufferPointer(start: childArr + start, count: end - start)
    }

    /// Human-facing path: the Data-volume firmlink prefix reads as "/".
    func displayPath(_ i: Int) -> String {
        let p = path(i)
        let prefix = "/System/Volumes/Data"
        if p.hasPrefix(prefix) {
            let rest = String(p.dropFirst(prefix.count))
            return rest.isEmpty ? "/" : rest
        }
        return p
    }

    /// Full path: root's name is the scanned path itself.
    func path(_ i: Int) -> String {
        var parts: [String] = []
        var cur = i
        while cur != 0 {
            parts.append(name(cur))
            cur = Int(parents[cur])
            if cur == Int(UInt32.max) { break }
        }
        var p = name(0)
        if p.hasSuffix("/") { p.removeLast() }
        for part in parts.reversed() { p += "/" + part }
        return p
    }

    /// Chain of ancestors from root to node (inclusive), for breadcrumbs.
    func ancestry(_ i: Int) -> [Int] {
        var chain = [i]
        var cur = i
        while cur != 0 && cur != Int(UInt32.max) {
            cur = Int(parents[cur])
            chain.append(cur)
        }
        return chain.reversed()
    }

    /// What a map draws for `node`: itself, or when it has no shape of its
    /// own (merged into an "A ▸ B" box, too deep for the rings) the nearest
    /// drawn folder that is mostly it. Nil when only a much larger folder is.
    func drawn(_ node: Int, isDrawn: (Int) -> Bool) -> Int? {
        var cur = node
        while !isDrawn(cur) {
            let parent = parents[cur]
            guard parent != UInt32.max, alloc[Int(parent)] <= 2 * alloc[node] else { return nil }
            cur = Int(parent)
        }
        return cur
    }
}

enum FDA {
    /// FDA-protected paths deny silently (no dialog), so probing is safe.
    static func isActive() -> Bool {
        let home = NSHomeDirectory()
        for p in ["\(home)/Library/Messages", "\(home)/Library/Mail", "\(home)/Library/Safari"] {
            if (try? FileManager.default.contentsOfDirectory(atPath: p)) != nil {
                return true
            }
        }
        return false
    }

    @MainActor
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }
}

/// How the scan is drawn: WizTree-style boxes or DaisyDisk-style rings.
enum MapStyle: String {
    case treemap, rings
}

/// Directory-list selection helpers shared by the outline and its tests.
enum ListSelection {
    /// Drop ids whose parent is also selected. Trashing a folder already
    /// takes its selected children; trashing the child afterwards fails
    /// because the path is gone.
    static func outermost(_ ids: [Int], parents: UnsafePointer<UInt32>) -> [Int] {
        let chosen = Set(ids)
        return ids.filter { id in
            var parent = Int(parents[id])
            while parent != Int(UInt32.max) {
                if chosen.contains(parent) { return false }
                parent = Int(parents[parent])
            }
            return true
        }
    }
}

@Observable
@MainActor
final class ScanModel {
    var files: UInt64 = 0
    var dirs: UInt64 = 0
    var bytes: UInt64 = 0
    var scanning = false
    var elapsed: Double = 0
    var tree: Tree?
    var scanRoot: String = {
        // `BlitzTree /some/path` scans that path on launch (also handy for QA).
        if CommandLine.arguments.count > 1 {
            var isDir: ObjCBool = false
            let p = (CommandLine.arguments[1] as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                return p
            }
        }
        // Whole disk by default: the user-data volume of the boot volume group.
        return "/System/Volumes/Data"
    }()
    /// Coding agents found on this Mac (Claude Code, Codex) and the user's PATH.
    var agentEnv = AgentEnvironment()
    /// The agent cleanup on screen, if any.
    var agentRun: AgentRun?
    /// An agent being installed or signed in from the panel.
    var agentSetup: AgentSetup?
    /// The first scan after launch opens the Clean Up panel once.
    private var panelOpenedAfterLaunch = false

    /// The agent to use: the one picked last, else Claude Code, else Codex.
    var preferredAgent: InstalledAgent? {
        let ready = agentEnv.ready
        let picked = UserDefaults.standard.string(forKey: "bz.agent")
        return ready.first { $0.kind.rawValue == picked } ?? ready.first { $0.kind == .claude } ?? ready.first
    }

    func startAgent(_ agent: InstalledAgent) {
        guard let tree, !scanning, !cleanupTrash.running else { return }
        UserDefaults.standard.set(agent.kind.rawValue, forKey: "bz.agent")
        agentRun?.cancel()
        let run = AgentRun(agent: agent, env: agentEnv, tree: tree, scanRoot: scanRoot, known: cleanup) { [weak self] in
            guard let self, !self.scanning else { return }
            self.startScan()
        }
        withAnimation(.snappy) { agentRun = run }
    }

    /// After the launch scan: open the panel on the Clean Up button or the
    /// setup offer. Nothing goes to an agent until the user clicks.
    func openPanelAfterLaunchScan() {
        guard !panelOpenedAfterLaunch, agentEnv.loaded, tree != nil, !scanning,
              !cleanupTrash.running, agentRun == nil else { return }
        panelOpenedAfterLaunch = true
        panelRequests += 1
        // QA only: BZ_QA_SETUP=claude|codex presses the setup button.
        if preferredAgent == nil, let kind = ProcessInfo.processInfo.environment["BZ_QA_SETUP"].flatMap(AgentKind.init) { setUp(kind) }
    }

    /// Bumped to ask the window to open the Clean Up panel.
    var panelRequests = 0

    func setUp(_ kind: AgentKind) {
        agentSetup?.cancel()
        let installed = agentEnv.agents.first { $0.kind == kind }
        agentSetup = AgentSetup(kind: kind, installed: installed, envPath: agentEnv.path) { [weak self] env in
            guard let self else { return }
            agentEnv = env
            agentSetup = nil
            if let agent = env.ready.first(where: { $0.kind == kind }) { startAgent(agent) }
        }
    }
    /// A tree has been shown at least once, so the views exist (see ContentView).
    var hasShownTree = false
    var viewRoot: Int = 0 {
        didSet {
            guard let tree else { return }
            // A selection outside the folder on screen would read as over 100%.
            if let sel = selection, !tree.ancestry(sel).contains(viewRoot) {
                selection = nil
                return
            }
            let kept = listSelection.filter { tree.ancestry($0).contains(viewRoot) }
            if kept != listSelection {
                selectionFromList = true
                listSelection = kept
                selectionFromList = false
            }
        }
    }
    /// The row the map outlines. Assigning it from the map or a scan replaces
    /// the directory list's selection with that one node. The list writes a
    /// multi-selection through `replaceListSelection` instead.
    var selection: Int? = nil {
        didSet {
            guard !selectionFromList else { return }
            listSelection = selection.map { [$0] } ?? []
        }
    }
    /// Nodes highlighted in the directory list, in outline row order.
    var listSelection: [Int] = []
    /// Set while the list is publishing its own selection, so `selection`'s
    /// didSet does not collapse that selection back to one row.
    private var selectionFromList = false
    /// A directory-list trash is in flight. Scans wait until it finishes so
    /// a rescan cannot snapshot the disk before the move lands.
    var trashingSelection = false

    /// Select a node from a list, zooming out first if it is outside the
    /// folder on screen (it would have nothing to outline).
    func reveal(_ node: Int) {
        if let tree, !tree.ancestry(node).contains(viewRoot) { viewRoot = 0 }
        selection = node
    }

    /// Record the outline's selection without letting the single-node
    /// assignment replace it.
    func replaceListSelection(_ ids: [Int], anchor: Int?) {
        selectionFromList = true
        listSelection = ids
        let next = anchor ?? ids.last
        if selection != next { selection = next }
        selectionFromList = false
    }

    func selectedPaths() -> [String] {
        guard let tree else { return [] }
        return listSelection.map { tree.path($0) }
    }

    /// Paths to move: a selected folder already contains its selected
    /// descendants, and the scan root is the volume itself.
    func pathsForTrash() -> [String] {
        guard let tree else { return [] }
        let root = tree.path(0)
        var seen = Set<String>()
        return ListSelection.outermost(listSelection, parents: tree.parents).compactMap { id in
            guard id != 0 else { return nil }
            let path = tree.path(id)
            guard path != root, path != "/", seen.insert(path).inserted else { return nil }
            guard TrashSafety.allows(path, scanRoot: root), TrashSafety.allows(path, scanRoot: scanRoot) else { return nil }
            return path
        }
    }

    /// Every selected path is already in a Trash, so Delete means permanent.
    var listTrashIsPermanent: Bool {
        let paths = pathsForTrash()
        return !paths.isEmpty && paths.allSatisfy(TrashPlace.contains)
    }

    func trashMenuTitle() -> String {
        let paths = pathsForTrash()
        if paths.isEmpty { return "Move to Trash" }
        if paths.allSatisfy(TrashPlace.contains) {
            return paths.count == 1 ? "Delete Permanently" : "Delete \(paths.count) Permanently"
        }
        return paths.count == 1 ? "Move to Trash" : "Move \(paths.count) to Trash"
    }

    func moveListSelectionToTrash() {
        movePathsToTrash(pathsForTrash())
    }

    /// Move every path, then rescan. The on-screen tree is the last scan;
    /// trashing files and leaving that tree up is why a delete looked like
    /// it did nothing. Items already in a Trash are deleted instead, and a
    /// permission failure is retried once with an administrator password.
    func movePathsToTrash(_ raw: [String]) {
        guard let tree else { return }
        var seen = Set<String>()
        let root = tree.path(0)
        var sizes: [String: UInt64] = [:]
        for id in ListSelection.outermost(listSelection, parents: tree.parents) where id != 0 {
            sizes[tree.path(id)] = tree.alloc[id]
        }
        let targets: [TrashTarget] = raw.compactMap { path in
            guard !path.isEmpty, path != "/", seen.insert(path).inserted else { return nil }
            guard TrashSafety.allows(path, scanRoot: root), TrashSafety.allows(path, scanRoot: scanRoot) else { return nil }
            return TrashTarget(path: path, label: (path as NSString).lastPathComponent,
                               bytes: sizes[path] ?? 0, inTrash: TrashPlace.contains(path))
        }
        guard !trashingSelection, !scanning, !cleanupTrash.running else { return }
        if targets.isEmpty {
            if raw.contains(where: { !$0.isEmpty && $0 != "/" }) {
                let alert = NSAlert()
                alert.messageText = "These items can't be deleted"
                alert.informativeText = "The selection is the scan root, a home folder, or another system location."
                alert.runModal()
            }
            return
        }
        let permanent = targets.filter(\.inTrash)
        let movable = targets.filter { !$0.inTrash }
        guard TrashUI.confirm(permanent: permanent, movable: movable) else { return }
        trashingSelection = true
        let scan = scanRoot
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> (failed: [TrashFailure], ok: Int) in
                var failed: [TrashFailure] = []
                var ok = 0
                for target in targets {
                    do {
                        if !TrashSafety.allows(target.path, scanRoot: scan) || !TrashSafety.allows(target.path, scanRoot: root) {
                            throw TrashSafety.refused(target.path)
                        }
                        if target.inTrash {
                            try Trash.removeNow(target.path, scanRoot: scan)
                        } else {
                            _ = try Trash.move(target.path)
                        }
                        ok += 1
                    } catch {
                        let ns = error as NSError
                        failed.append(TrashFailure(
                            label: target.label, path: target.path, message: ns.localizedDescription,
                            permission: TrashError.isPermission(ns), inTrash: target.inTrash, bytes: target.bytes))
                    }
                }
                return (failed, ok)
            }.value
            let settled = TrashRetry.settle(outcome.failed, succeeded: outcome.ok, scanRoot: scan)
            trashingSelection = false
            if settled.succeeded > 0 {
                selectionFromList = true
                listSelection = []
                selection = nil
                selectionFromList = false
                startScan()
            }
            if !settled.failed.isEmpty {
                TrashUI.present(settled.failed)
            }
        }
    }
    var hovered: Int? = nil
    var freeBytes: UInt64 = 0
    /// Rebuildable folders worth deleting, largest first.
    var cleanup: [CleanupItem] = []
    let cleanupTrash = CleanupTrashBatch()
    /// Volume-used minus what the scan could see: root-only territory.
    var unscannedBytes: UInt64 = 0
    var showFreeSpace: Bool = UserDefaults.standard.bool(forKey: "bz.showFree") {
        didSet { UserDefaults.standard.set(showFreeSpace, forKey: "bz.showFree") }
    }
    var mapStyle: MapStyle = MapStyle(rawValue: UserDefaults.standard.string(forKey: "bz.mapStyle") ?? "") ?? .treemap {
        didSet { UserDefaults.standard.set(mapStyle.rawValue, forKey: "bz.mapStyle") }
    }

    private var handle: OpaquePointer?
    private var timer: Timer?
    private var startedAt: Date?
    private var activity: NSObjectProtocol?
    private var volumeTask: Task<VolumeSpace, Never>?

    func startScan(path: String? = nil) {
        if scanning || cleanupTrash.running || trashingSelection { return }
        if let path { scanRoot = path }
        tree = nil
        cleanup = []
        viewRoot = 0
        selectionFromList = true
        listSelection = []
        selection = nil
        selectionFromList = false
        hovered = nil
        files = 0; dirs = 0; bytes = 0; elapsed = 0
        lastPollAt = nil; maxPollGap = 0
        scanning = true
        startedAt = Date()
        // Keep the process out of App Nap / timer coalescing while scanning.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Disk scan"
        )
        // Foundation may ask a disk-management service about purgeable space.
        // Read it alongside the scan, before publishing the finished tree, so
        // the main thread never waits synchronously on that service.
        let volumePath = scanRoot
        volumeTask = Task.detached(priority: .userInitiated) { VolumeSpace.read(volumePath) }
        handle = bz_scan_start(scanRoot)

        // 60 Hz: the elapsed time ticks every frame, so the screen keeps
        // moving while the engine assembles the tree after the last file is
        // counted (the counters sit still for that part).
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        // Common modes: keep polling while a control is being clicked.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private var lastPollAt: Date?
    private var maxPollGap: Double = 0

    private func poll() {
        guard let handle else {
            // A slow volume-space service must not freeze progress while the
            // already finished tree waits for its matching volume snapshot.
            if scanning { elapsed = -(startedAt?.timeIntervalSinceNow ?? 0) }
            return
        }
        if let last = lastPollAt { maxPollGap = max(maxPollGap, -last.timeIntervalSinceNow) }
        lastPollAt = Date()
        var f: UInt64 = 0, d: UInt64 = 0, b: UInt64 = 0
        var done: Int32 = 0
        bz_progress(handle, &f, &d, &b, &done)
        files = f; dirs = d; bytes = b
        elapsed = -(startedAt?.timeIntervalSinceNow ?? 0)
        if done != 0 {
            let doneAt = Date()
            let result = Tree(handle: handle)
            self.handle = nil
            if result == nil { bz_free(handle) }
            let pendingVolume = volumeTask
            volumeTask = nil
            Task {
                let space = await pendingVolume?.value ?? VolumeSpace(free: nil, used: nil)
                finishScan(result, space: space, doneAt: doneAt)
            }
        }
    }

    private func finishScan(_ result: Tree?, space: VolumeSpace, doneAt: Date) {
        timer?.invalidate()
        timer = nil
        tree = result
        if tree != nil { hasShownTree = true }
        if ProcessInfo.processInfo.environment["BZ_TIMING"] != nil {
            // Queue latency includes awaiting metadata and UI updates; it is
            // not a measurement of uninterrupted main-thread blocking.
            DispatchQueue.main.async {
                NSLog("BZ hand-off: queued completion %.1f ms after engine done", -doneAt.timeIntervalSinceNow * 1000)
            }
            NSLog("BZ done at %.3f, longest gap between polls %.1f ms", doneAt.timeIntervalSinceReferenceDate, maxPollGap * 1000)
        }
        scanning = false
        if let tree {
            Task {
                let found = await Task.detached(priority: .userInitiated) { Cleanup.find(in: tree) }.value
                // A rescan may have replaced the tree while discovery ran.
                // Node IDs only belong to the scan that produced them.
                guard self.tree === tree else { return }
                cleanup = found
                openPanelAfterLaunchScan()
            }
            NSLog("BZ scan done: %llu nodes, %llu unreadable dirs", UInt64(tree.count), tree.errors)
        }
        freeBytes = space.free ?? 0
        // Coverage honesty: compare scanned bytes with what the volume
        // says it holds. The difference is root-only space (Spotlight
        // index, unified logs, …) no unelevated app can read.
        unscannedBytes = 0
        if let tree, let used = space.used {
            let seen = tree.alloc[0]
            if used > seen {
                unscannedBytes = used - seen
            }
        }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}

nonisolated private struct VolumeSpace: Sendable {
    let free: UInt64?
    let used: UInt64?

    static func read(_ path: String) -> VolumeSpace {
        let values = try? URL(fileURLWithPath: path).resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return VolumeSpace(
            free: values?.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) },
            used: path == "/System/Volumes/Data" ? volumeUsedBytes(path) : nil
        )
    }
}

/// Space used by this APFS volume alone, the figure `df` shows. statfs and
/// Foundation's systemSize/systemFreeSize describe the whole container,
/// which also holds the macOS system volume, VM swap and Recovery.
nonisolated func volumeUsedBytes(_ path: String) -> UInt64? {
    var request = attrlist()
    request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    request.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEUSED)
    var reply = (length: UInt32(0), used: UInt64(0))
    let status = withUnsafeMutableBytes(of: &reply) {
        getattrlist(path, &request, $0.baseAddress, $0.count, 0)
    }
    guard status == 0 else { return nil }
    // Packed buffer: u_int32_t length, then off_t at offset 4 (unaligned).
    return withUnsafeBytes(of: &reply) { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self) }
}

nonisolated enum Fmt {
    static func size(_ b: UInt64) -> String { Int64(b).formatted(.byteCount(style: .file)) }
    static func num(_ n: UInt64) -> String { n.formatted() }
}
