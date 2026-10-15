import AppKit
import Foundation

private struct Fixture {
    var names = ["/fixture"]
    var parents = [UInt32.max]
    var sizes: [UInt64] = [0]
    var flags: [UInt8] = [1]
    var children: [[UInt32]] = [[]]

    @discardableResult
    mutating func add(_ name: String, to parent: Int = 0, bytes: UInt64 = 0, directory: Bool = true) -> Int {
        let id = names.count
        names.append(name)
        parents.append(UInt32(parent))
        sizes.append(bytes)
        flags.append(directory ? 1 : 0)
        children.append([])
        children[parent].append(UInt32(id))
        return id
    }

    func tree() -> Tree {
        var alloc = sizes
        for id in (1..<names.count).reversed() { alloc[Int(parents[id])] += alloc[id] }
        var offsets: [UInt32] = [0]
        var edges: [UInt32] = []
        var nameOffsets: [UInt32] = [0]
        var blob: [UInt8] = []
        for id in names.indices {
            edges.append(contentsOf: children[id].sorted { alloc[Int($0)] > alloc[Int($1)] })
            offsets.append(UInt32(edges.count))
            blob.append(contentsOf: names[id].utf8)
            nameOffsets.append(UInt32(blob.count))
        }
        let handle = bz_fixture_create(UInt32(names.count), parents, alloc, flags, offsets, edges, nameOffsets, blob)!
        // Synthetic tests measure the Swift presentation adapter. Rule parity
        // against Rust is exercised by --scan-path and the Rust rule tests.
        let reference = Tree(handle: handle)!
        let populated = bz_fixture_create(UInt32(names.count), parents, alloc, flags, offsets, edges, nameOffsets, blob)!
        for item in ReferenceCleanup.find(in: reference) {
            bz_fixture_add_cleanup(populated, UInt32(item.node), item.kind)
        }
        return Tree(handle: populated)!
    }
}

private func signature(_ items: [CleanupItem]) -> [String] {
    items.map { "\($0.node)|\($0.path)|\($0.display)|\($0.kind)|\($0.bytes)" }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

private func childrenAreUnmaterialized(_ item: OutlinePanel.Item) -> Bool {
    guard let kids = Mirror(reflecting: item).children.first(where: { $0.label == "kids" }) else {
        fatalError("Item children storage changed; update benchmark inspection")
    }
    return Mirror(reflecting: kids.value).children.isEmpty
}

/// Multi-select bookkeeping and which paths a delete actually moves.
@MainActor private func checkListSelection() {
    var rows = Fixture()
    let fileA = rows.add("a", bytes: 30, directory: false)
    let folder = rows.add("folder")
    let child = rows.add("child", to: folder, bytes: 10, directory: false)
    let fileB = rows.add("b", bytes: 20, directory: false)
    let tree = rows.tree()
    check(ListSelection.outermost([folder, child], parents: tree.parents) == [folder], "Deleting a folder and its child trashes the child twice")
    check(ListSelection.outermost([fileA, fileB], parents: tree.parents) == [fileA, fileB], "Unrelated files collapsed to one delete")
    check(ListSelection.outermost([child], parents: tree.parents) == [child], "A lone file was dropped")

    let model = ScanModel()
    model.tree = tree
    model.selection = fileA
    check(model.listSelection == [fileA], "A map click did not become the list selection")
    model.replaceListSelection([fileA, fileB], anchor: fileB)
    check(model.selection == fileB && model.listSelection == [fileA, fileB], "The list could not keep more than one row")
    model.selection = fileA
    check(model.listSelection == [fileA], "A later single selection left the old rows selected")
    model.replaceListSelection([folder, child, fileB], anchor: folder)
    let paths = model.pathsForTrash()
    check(paths.count == 2, "Trash paths \(paths)")
    check(paths.contains { $0.hasSuffix("/folder") } && paths.contains { $0.hasSuffix("/b") }, "Trash paths kept a child or dropped a sibling: \(paths)")
    check(!paths.contains { $0.hasSuffix("/child") }, "Trash paths included a file inside a selected folder")
    model.selection = nil
    check(model.listSelection.isEmpty, "Clearing the selection left rows highlighted")

    let outline = NSOutlineView()
    outline.allowsMultipleSelection = true
    let coordinator = OutlinePanel.Coordinator()
    coordinator.model = model
    coordinator.outline = outline
    outline.dataSource = coordinator
    outline.delegate = coordinator
    model.tree = tree
    coordinator.rebuildIfNeeded()
    func row(_ name: String) -> Int {
        for index in 0..<outline.numberOfRows {
            let item = outline.item(atRow: index) as! OutlinePanel.Item
            if item.tree.name(item.id) == name { return index }
        }
        fatalError("missing row \(name)")
    }
    outline.selectRowIndexes(IndexSet([row("a"), row("b")]), byExtendingSelection: false)
    coordinator.outlineViewSelectionDidChange(Notification(name: NSOutlineView.selectionDidChangeNotification, object: outline))
    check(Set(model.listSelection) == Set([fileA, fileB]), "Outline selection did not record both rows: \(model.listSelection)")
    model.replaceListSelection([fileA, fileB], anchor: fileA)
    coordinator.syncSelection()
    check(outline.numberOfSelectedRows == 2, "Sync collapsed a multi-selection")
    check(Set((0..<outline.numberOfRows).compactMap { outline.selectedRowIndexes.contains($0) ? (outline.item(atRow: $0) as? OutlinePanel.Item)?.id : nil }) == Set([fileA, fileB]),
          "Synced rows were not the model selection")
}

private func milliseconds(_ work: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    work()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

private func median(_ samples: [Double]) -> Double { samples.sorted()[samples.count / 2] }

/// Deletes edit the scan in place: sizes up every ancestor, removed nodes
/// unreachable, ids stable, moves into a Trash inside the scan re-homed,
/// and the folder on screen, expanded rows, and selection kept.
@MainActor private func checkIncrementalEdit() {
    var rows = Fixture()
    let docs = rows.add("docs")
    let deep = rows.add("deep", to: docs)
    let x = rows.add("x", to: deep, bytes: 100, directory: false)
    let y = rows.add("y", to: deep, bytes: 40, directory: false)
    let z = rows.add("z", to: deep, bytes: 10, directory: false)
    let big = rows.add("big", bytes: 120, directory: false)
    let trash = rows.add(".Trash")
    rows.add("old", to: trash, bytes: 5, directory: false)
    let tree = rows.tree()
    let total = tree.alloc[0]
    check(total == 275, "fixture total \(total)")

    // Remove a file: every ancestor shrinks, ids stay put.
    let removed = TreeEdit.apply([.remove(x)], to: tree)
    check(removed.isRemoved(x) && !TreeEdit.isLive(x, in: removed), "Removed node still live")
    check(removed.alloc[deep] == 50 && removed.alloc[docs] == 50 && removed.alloc[0] == 175, "Ancestor sizes not reduced")
    check(removed.children(deep).map(Int.init) == [y, z], "Removed node still listed: \(Array(removed.children(deep)))")
    check(removed.name(y) == "y" && removed.path(z) == "/fixture/docs/deep/z", "Ids or names shifted")
    check(removed.children(0).map(Int.init) == [big, docs, trash] && tree.children(0).map(Int.init) == [docs, big, trash], "Root children not re-sorted by new size")

    // Remove a folder: its whole subtree goes.
    let noDocs = TreeEdit.apply([.remove(docs)], to: removed)
    check(!TreeEdit.isLive(y, in: noDocs) && noDocs.alloc[0] == 125, "Folder delete left its subtree or size")

    // Move into a Trash inside the scan, renamed: total unchanged.
    let moved = TreeEdit.apply([.move(big, to: trash, name: "big 2")], to: tree)
    check(moved.alloc[0] == total && moved.alloc[trash] == 125, "Move into Trash changed the total or missed the Trash")
    check(moved.path(big) == "/fixture/.Trash/big 2", "Moved node path \(moved.path(big))")
    check(!moved.children(0).contains(UInt32(big)), "Moved node still under its old folder")

    // Graft a rescanned folder in place of an old one.
    var fresh = Fixture()
    let inner = fresh.add("inner")
    fresh.add("new-file", to: inner, bytes: 7, directory: false)
    let graft = fresh.tree()
    let replaced = TreeEdit.apply([.replace(deep, with: graft)], to: tree)
    check(replaced.alloc[deep] == 7 && replaced.alloc[docs] == 7 && replaced.alloc[0] == 132, "Graft sizes wrong")
    check(!TreeEdit.isLive(x, in: replaced) && replaced.children(deep).count == 1, "Graft kept old children")
    let innerID = Int(replaced.children(deep)[0])
    check(replaced.path(Int(replaced.children(innerID)[0])) == "/fixture/docs/deep/inner/new-file", "Grafted names wrong")
    // A second edit keeps names added by the first.
    let again = TreeEdit.apply([.remove(big)], to: replaced)
    check(again.name(innerID) == "inner" && again.alloc[0] == 12, "Second edit lost grafted names or sizes")

    // Disk check: "/fixture/…" does not exist, so these read as deleted.
    let viaDisk = DiskChanges.edit(tree, paths: ["/fixture/docs/deep/x", "/fixture/big"],
                                   moves: ["/fixture/big": "/fixture/.Trash/big"], refresh: [])!
    check(!TreeEdit.isLive(x, in: viaDisk) && viaDisk.parents[big] == UInt32(trash) && viaDisk.alloc[0] == 175,
          "Disk changes were not applied in place")

    // Model and outline state survive the edit.
    let model = ScanModel()
    model.tree = tree
    model.viewRoot = docs
    model.replaceListSelection([x], anchor: x)
    let outline = NSOutlineView()
    outline.allowsMultipleSelection = true
    let coordinator = OutlinePanel.Coordinator()
    coordinator.model = model
    coordinator.outline = outline
    outline.dataSource = coordinator
    outline.delegate = coordinator
    coordinator.rebuildIfNeeded()
    let deepRow = coordinator.roots.first { $0.id == deep }!
    outline.expandItem(deepRow)
    coordinator.syncSelection()
    check(outline.numberOfRows == 4, "Fixture outline rows \(outline.numberOfRows)")
    let edited = TreeEdit.apply([.remove(x)], to: tree)
    model.install(edited, from: tree, selectionBefore: model.listSelection)
    coordinator.rebuildIfNeeded()
    coordinator.syncSelection()
    check(model.viewRoot == docs, "Edit reset the zoomed folder")
    check(model.listSelection == [y] && model.selection == y, "Selection did not move to the next row: \(model.listSelection)")
    check(coordinator.roots.first === deepRow && outline.isItemExpanded(deepRow), "Edit collapsed or replaced an expanded row")
    check(outline.numberOfRows == 3, "Deleted row still in the outline")
    check((outline.item(atRow: outline.selectedRow) as? OutlinePanel.Item)?.id == y, "Outline did not select the next row")
    check(!model.scanning && model.tree === edited, "Edit started a scan")
}

@main
struct UIPerformance {
    @MainActor
    static func main() {
        print("Cleanup timings measure presentation of precomputed candidates; Rust selection is excluded.")
        var fixture = Fixture()
        let positive: [(String, String?)] = [
            ("node_modules", nil), (".venv", nil), ("venv", "pyvenv.cfg"),
            ("target", "Cargo.toml"), (".next", "package.json"),
            ("DerivedData", "Xcode"), ("Caches", "Library"), ("Caches", "CoreSimulator"),
            (".cache", nil), (".npm", nil), (".gradle", nil),
            ("iOS DeviceSupport", nil), ("macOS DeviceSupport", nil), ("watchOS DeviceSupport", nil),
        ]
        var expected = Set<Int>()
        for (index, rule) in positive.enumerated() {
            let parentName = ["Xcode", "Library", "CoreSimulator"].contains(rule.1 ?? "") ? rule.1! : "project-\(index)"
            let parent = fixture.add(parentName)
            let match = fixture.add(rule.0, to: parent, bytes: ReferenceCleanup.minBytes)
            expected.insert(match)
            if let marker = rule.1, marker == "pyvenv.cfg" { fixture.add(marker, to: match, directory: false) }
            if let marker = rule.1, ["Cargo.toml", "package.json"].contains(marker) { fixture.add(marker, to: parent, directory: false) }
        }
        let bun = fixture.add(".bun")
        let install = fixture.add("install", to: bun)
        expected.insert(fixture.add("cache", to: install, bytes: ReferenceCleanup.minBytes))
        let nested = fixture.add("node_modules", bytes: ReferenceCleanup.minBytes)
        expected.insert(nested)
        fixture.add(".venv", to: nested, bytes: ReferenceCleanup.minBytes)
        let trash = fixture.add(".Trash")
        fixture.add("node_modules", to: trash, bytes: ReferenceCleanup.minBytes)
        for name in ["node_modules", ".venv", ".cache", "Caches", "文件😀"] {
            fixture.add(name, bytes: ReferenceCleanup.minBytes - 1)
        }
        for name in ["venv", "target", ".next", "DerivedData", "Caches", "cache"] {
            fixture.add(name, bytes: ReferenceCleanup.minBytes + 1)
        }
        fixture.add("node_modules", bytes: ReferenceCleanup.minBytes + 1, directory: false)
        let edgeTree = fixture.tree()
        check(signature(Cleanup.find(in: edgeTree)) == signature(ReferenceCleanup.find(in: edgeTree)), "Cleanup differs on threshold / marker / nesting cases")
        check(Set(Cleanup.find(in: edgeTree).map(\.node)) == expected, "Cleanup violated explicit matching expectations")

        // Deterministic uneven tree with duplicate sizes, Unicode names, empty
        // folders, and nested rebuildable names. No filesystem mutations.
        var randomFixture = Fixture()
        var state: UInt64 = 0xB1172
        for id in 1...25_000 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let parent = Int(state % UInt64(id))
            let names = ["src", "node_modules", ".cache", "文件😀", "venv", "target", ".Trash", "normal"]
            randomFixture.add(names[Int((state >> 8) % UInt64(names.count))], to: parent,
                              bytes: (state >> 24) % 100_000_000)
        }
        let randomTree = randomFixture.tree()
        check(signature(Cleanup.find(in: randomTree)) == signature(ReferenceCleanup.find(in: randomTree)), "Cleanup differs on randomized tree")

        // Insert qualifying entries last; flattening must sort them ahead of
        // tiny siblings so the threshold break never hides a later match.
        var wideCleanupFixture = Fixture()
        for child in 0..<100_000 { wideCleanupFixture.add("small-\(child)", bytes: 4096, directory: child.isMultiple(of: 2)) }
        wideCleanupFixture.add(".venv", bytes: ReferenceCleanup.minBytes - 1)
        let wideMatch = wideCleanupFixture.add("node_modules", bytes: ReferenceCleanup.minBytes)
        wideCleanupFixture.add("large-file", bytes: 100_000_000, directory: false)
        let wideCleanupTree = wideCleanupFixture.tree()
        check(signature(Cleanup.find(in: wideCleanupTree)) == signature(ReferenceCleanup.find(in: wideCleanupTree)), "Cleanup differs on wide sorted tree")
        check(Cleanup.find(in: wideCleanupTree).map(\.node) == [wideMatch], "Early break skipped an eligible sibling")

        let outline = NSOutlineView()
        let coordinator = OutlinePanel.Coordinator()
        let item = OutlinePanel.Item(id: 0, tree: randomTree)
        check(childrenAreUnmaterialized(item), "Fresh item eagerly created children")
        let count = coordinator.outlineView(outline, numberOfChildrenOfItem: item)
        check(count == randomTree.children(0).count, "Outline child count differs")
        check(childrenAreUnmaterialized(item), "Counting outline rows allocated child wrappers")

        // A map selection must not allocate the contents of an unopened folder.
        // A real outline is needed here because syncSelection goes through its
        // data source and selection callbacks.
        let model = ScanModel()
        model.tree = randomTree
        model.selection = 1
        coordinator.model = model
        coordinator.outline = outline
        outline.dataSource = coordinator
        outline.delegate = coordinator
        coordinator.rebuildIfNeeded()
        coordinator.syncSelection()
        let selected = coordinator.roots.first { $0.id == 1 }!
        check((outline.item(atRow: outline.selectedRow) as? OutlinePanel.Item)?.id == 1, "Selection failed")
        check(childrenAreUnmaterialized(selected), "Selecting collapsed folder allocated its descendants")
        // Refreshing an untouched root with the same shape reuses its row
        // identity, even when Rust assigns different node IDs on the rescan.
        var oldRows = Fixture()
        let oldFolder = oldRows.add("folder")
        oldRows.add("old-child", to: oldFolder, bytes: 1_000, directory: false)
        oldRows.add("small", bytes: 100, directory: false)
        model.tree = oldRows.tree(); model.selection = nil
        coordinator.rebuildIfNeeded()
        let originalRow = coordinator.roots[0]
        var newRows = Fixture()
        newRows.add("small", bytes: 150, directory: false)
        let newFolder = newRows.add("folder")
        newRows.add("new-child", to: newFolder, bytes: 2_000, directory: false)
        let replacementTree = newRows.tree()
        model.tree = replacementTree
        coordinator.rebuildIfNeeded()
        check(coordinator.roots[0] === originalRow, "Same-shape rescan discarded row identity")
        check(originalRow.id == newFolder && originalRow.tree === replacementTree, "Reused row kept a stale node")
        check(outline.selectedRow == -1, "Rescan preserved old selection")
        outline.expandItem(originalRow)
        check(outline.numberOfRows == 3, "Reused outline cached the wrong child count")
        let child = outline.item(atRow: 1) as! OutlinePanel.Item
        check(child.tree === replacementTree && child.tree.name(child.id) == "new-child", "Expanding reused row revealed an old tree")
        outline.collapseItem(originalRow)
        model.tree = newRows.tree()
        coordinator.rebuildIfNeeded()
        check(coordinator.roots[0] !== originalRow, "Materialized children must invalidate reused roots")
        let priorRow = coordinator.roots[0]
        newRows.add("another-child", to: newFolder, bytes: 20, directory: false)
        model.tree = newRows.tree()
        coordinator.rebuildIfNeeded()
        check(coordinator.roots[0] !== priorRow, "Changed child count reused cached outline shape")
        let renamedRow = coordinator.roots[0]
        newRows.names[newFolder] = "renamed"
        model.tree = newRows.tree()
        coordinator.rebuildIfNeeded()
        check(coordinator.roots[0] !== renamedRow, "Renamed root reused stale outline identity")
        checkListSelection()
        checkIncrementalEdit()
        print("PASS: incremental delete edits (sizes, removal, moves, grafts, kept view state); cleanup parity; lazy outline children; rescan row reuse, new IDs, expansion, and shape invalidation")
        guard !CommandLine.arguments.contains("--check-only") else { return }

        // In-place delete on a large tree: one O(n) copy-on-write pass, off-main in the app.
        do {
            var big = Fixture()
            for d in 0..<1_000 {
                let dir = big.add("dir-\(d)")
                for f in 0..<1_000 { big.add("f\(f)", to: dir, bytes: UInt64(f + 1), directory: false) }
            }
            let bigTree = big.tree()
            let victims = (0..<100).map { Int(bigTree.children(Int(bigTree.children(0)[$0]))[0]) }
            let samples = (0..<5).map { _ in milliseconds { _ = TreeEdit.apply(victims.map { .remove($0) }, to: bigTree) } }
            print(String(format: "in-place delete: 100 files from %d nodes median_ms=%.2f", bigTree.count, median(samples)))
        }

        let hasFDA = FDA.isActive()
        let fdaSamples = (0..<31).map { _ in milliseconds { check(FDA.isActive() == hasFDA, "FDA access changed during benchmark") } }
        print(String(format: "FDA probe active=%@ median_ms=%.3f max_ms=%.3f", hasFDA.description, median(fdaSamples), fdaSamples.max()!))

        var largeFixture = Fixture()
        for project in 0..<1_000 {
            let parent = largeFixture.add("project-\(project)")
            largeFixture.add("node_modules", to: parent, bytes: 64_000_000)
            let small = largeFixture.add("sources", to: parent)
            for child in 0..<512 {
                largeFixture.add("directory-with-a-long-name-\(child)", to: small, bytes: 4096)
            }
        }
        let largeTree = largeFixture.tree()
        let expectedItems = ReferenceCleanup.find(in: largeTree)
        check(signature(Cleanup.find(in: largeTree)) == signature(expectedItems), "Large cleanup fixture differs")
        var before: [Double] = [], after: [Double] = []
        for trial in 0..<9 {
            func old() { before.append(milliseconds { check(ReferenceCleanup.find(in: largeTree).count == 1_000, "Baseline count") }) }
            func new() { after.append(milliseconds { check(Cleanup.find(in: largeTree).count == 1_000, "Optimized count") }) }
            if trial.isMultiple(of: 2) { old(); new() } else { new(); old() }
        }
        print(String(format: "cleanup nodes=%d matches=%d baseline_ms=%.3f optimized_ms=%.3f speedup=%.2fx", largeTree.count, expectedItems.count, median(before), median(after), median(before) / median(after)))
        print("cleanup baseline_ms samples=\(before) optimized_ms samples=\(after)")
        before = []; after = []
        for trial in 0..<9 {
            func old() { before.append(milliseconds { check(ReferenceCleanup.find(in: wideCleanupTree).count == 1, "Baseline wide cleanup count") }) }
            func new() { after.append(milliseconds { check(Cleanup.find(in: wideCleanupTree).count == 1, "Optimized wide cleanup count") }) }
            if trial.isMultiple(of: 2) { old(); new() } else { new(); old() }
        }
        print(String(format: "cleanup wide_siblings=%d baseline_ms=%.3f optimized_ms=%.6f", wideCleanupTree.children(0).count, median(before), median(after)))

        var wideFixture = Fixture()
        let wideParent = wideFixture.add("wide-folder")
        for child in 0..<100_000 { wideFixture.add("child-\(child)", to: wideParent) }
        let wideTree = wideFixture.tree()
        before = []; after = []
        for _ in 0..<9 {
            let oldItem = OutlinePanel.Item(id: wideParent, tree: wideTree)
            before.append(milliseconds { check(oldItem.children.count == 100_000, "Baseline outline count") })
            check(!childrenAreUnmaterialized(oldItem), "Baseline did not materialize wrappers")
            let newItem = OutlinePanel.Item(id: wideParent, tree: wideTree)
            after.append(milliseconds { check(coordinator.outlineView(outline, numberOfChildrenOfItem: newItem) == 100_000, "Optimized outline count") })
            check(childrenAreUnmaterialized(newItem), "Wide count allocated wrappers")
        }
        print(String(format: "outline child_count=100000 baseline_ms=%.3f optimized_ms=%.6f baseline_wrappers=100000 optimized_wrappers=0", median(before), median(after)))
    }
}
