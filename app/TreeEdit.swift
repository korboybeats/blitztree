import Foundation

/// Arrays an edited `Tree` owns. Allocated once per edit, freed with the tree.
nonisolated final class TreeStorage: @unchecked Sendable {
    let parents: UnsafeMutablePointer<UInt32>
    let alloc: UnsafeMutablePointer<UInt64>
    let logical: UnsafeMutablePointer<UInt64>
    let nFiles: UnsafeMutablePointer<UInt32>
    let flags: UnsafeMutablePointer<UInt8>
    let childOff: UnsafeMutablePointer<UInt32>
    var childArr: UnsafeMutablePointer<UInt32>
    var extraBlob: UnsafeMutablePointer<UInt8>?

    init(count: Int) {
        parents = .allocate(capacity: count)
        alloc = .allocate(capacity: count)
        logical = .allocate(capacity: count)
        nFiles = .allocate(capacity: count)
        flags = .allocate(capacity: count)
        childOff = .allocate(capacity: count + 1)
        childArr = .allocate(capacity: 1)
    }

    deinit {
        parents.deallocate(); alloc.deallocate(); logical.deallocate()
        nFiles.deallocate(); flags.deallocate(); childOff.deallocate()
        childArr.deallocate(); extraBlob?.deallocate()
    }
}

/// What an edit changed, for views that update in place instead of reloading.
nonisolated struct TreeEditInfo: Sendable {
    /// Folders whose child list changed (members or order).
    var changedParents: Set<Int>
    /// Nodes no longer in the tree (outermost only; their subtrees went too).
    var removed: Set<Int>
}

/// One change to apply to the scan tree, by node id.
nonisolated enum TreeOp: @unchecked Sendable {
    /// The item is gone from disk.
    case remove(Int)
    /// The item was renamed into `parent` (a Trash inside the scan), maybe
    /// under a new name.
    case move(Int, to: Int, name: String?)
    /// The folder was rescanned: its contents become `scan`'s.
    case replace(Int, with: Tree)
    /// A folder that is new to the tree, scanned into `scan`.
    case insert(Tree, under: Int, name: String)
    /// A file that is new to the tree.
    case insertFile(under: Int, name: String, alloc: UInt64, logical: UInt64)
    /// A file whose size changed.
    case resize(Int, alloc: UInt64, logical: UInt64)
}

/// Applies deletes and moves to a scan without rescanning it.
///
/// The engine's arrays are read-only and shared with views drawing on other
/// threads, so an edit is copy-on-write: one O(n) copy of the numeric arrays
/// (memcpy, ~30 bytes a node), size deltas walked up each touched node's
/// ancestors (O(depth)), and child lists rebuilt only where they changed.
/// Names stay in the engine's blob; only new names are stored. Node ids stay
/// stable, so selection, zoom, and outline rows keep pointing at the same
/// items. This runs off the main thread; the main thread only swaps the tree.
nonisolated enum TreeEdit {
    static func apply(_ ops: [TreeOp], to base: Tree) -> Tree {
        let n0 = base.count
        var added = 0
        for op in ops {
            switch op {
            case .insert(let g, _, _): added += g.count
            case .replace(_, let g): added += g.count - 1
            case .insertFile: added += 1
            default: break
            }
        }
        let n = n0 + added
        let st = TreeStorage(count: n)
        st.parents.update(from: base.parents, count: n0)
        st.alloc.update(from: base.alloc, count: n0)
        st.logical.update(from: base.logical, count: n0)
        st.nFiles.update(from: base.nFiles, count: n0)
        st.flags.update(from: base.flags, count: n0)

        var kids: [Int: [UInt32]] = [:]
        var resort = Set<Int>()
        var removed = Set<Int>()
        var extraNames: [Int: Range<Int>] = [:]
        var blob: [UInt8] = []
        var next = n0

        // Names earlier edits gave (renames, added nodes) carry over.
        for id in base.extraNameIDs {
            let bytes = base.nameBytes(id)
            let start = blob.count
            blob.append(contentsOf: bytes)
            extraNames[id] = start..<blob.count
        }

        func list(_ p: Int) -> [UInt32] {
            if let k = kids[p] { return k }
            return p < n0 ? Array(base.children(p)) : []
        }
        func setName(_ id: Int, _ name: String) {
            let start = blob.count
            blob.append(contentsOf: name.utf8)
            extraNames[id] = start..<blob.count
        }
        func files(_ i: Int) -> UInt64 { st.flags[i] & 1 != 0 ? UInt64(st.nFiles[i]) : 1 }
        /// Add (or with `sign` -1 subtract) sizes on `from` and every ancestor.
        func propagate(from: Int, alloc a: UInt64, logical l: UInt64, files f: UInt64, sign: Int) {
            var cur = from
            while cur != Int(UInt32.max) {
                if sign > 0 {
                    st.alloc[cur] &+= a; st.logical[cur] &+= l; st.nFiles[cur] &+= UInt32(truncatingIfNeeded: f)
                } else {
                    st.alloc[cur] = st.alloc[cur] >= a ? st.alloc[cur] - a : 0
                    st.logical[cur] = st.logical[cur] >= l ? st.logical[cur] - l : 0
                    st.nFiles[cur] = st.nFiles[cur] >= UInt32(truncatingIfNeeded: f) ? st.nFiles[cur] - UInt32(truncatingIfNeeded: f) : 0
                }
                let parent = Int(st.parents[cur])
                if parent != Int(UInt32.max) { resort.insert(parent) }
                cur = parent
            }
        }
        func detach(_ node: Int) {
            let p = Int(st.parents[node])
            guard p != Int(UInt32.max) else { return }
            kids[p] = list(p).filter { Int($0) != node }
            propagate(from: p, alloc: st.alloc[node], logical: st.logical[node], files: files(node), sign: -1)
        }
        func attach(_ node: Int, to p: Int) {
            st.parents[node] = UInt32(p)
            kids[p] = list(p) + [UInt32(node)]
            propagate(from: p, alloc: st.alloc[node], logical: st.logical[node], files: files(node), sign: 1)
        }
        /// Mark everything under `node` (not `node` itself) removed.
        func dropDescendants(_ node: Int) {
            var stack = list(node).map(Int.init)
            while let i = stack.popLast() {
                st.flags[i] |= Tree.removedFlag
                stack.append(contentsOf: list(i).map(Int.init))
                kids[i] = nil
            }
            kids[node] = []
        }
        /// Copy scan `g` in: its root becomes `root`, the rest get new ids.
        func graft(_ g: Tree, root: Int) {
            let offset = next - 1
            next += g.count - 1
            func id(_ j: Int) -> Int { j == 0 ? root : offset + j }
            for j in 1..<max(g.count, 1) {
                let i = id(j)
                st.parents[i] = UInt32(id(Int(g.parents[j])))
                st.alloc[i] = g.alloc[j]; st.logical[i] = g.logical[j]
                st.nFiles[i] = g.nFiles[j]; st.flags[i] = g.flags[j] & 1
                setName(i, g.name(j))
            }
            for j in 0..<g.count where g.isDir(j) {
                kids[id(j)] = g.children(j).map { UInt32(id(Int($0))) }
            }
            st.alloc[root] = g.alloc[0]; st.logical[root] = g.logical[0]
            st.nFiles[root] = g.nFiles[0]; st.flags[root] = g.flags[0] & 1
        }
        func live(_ i: Int) -> Bool {
            guard i >= 0, i < next else { return false }
            var cur = i
            while cur != Int(UInt32.max) {
                if st.flags[cur] & Tree.removedFlag != 0 || removed.contains(cur) { return false }
                cur = Int(st.parents[cur])
            }
            return true
        }

        // Removals last: a move into a folder that is also deleted goes with it.
        let ordered = ops.filter { if case .remove = $0 { return false }; return true }
            + ops.filter { if case .remove = $0 { return true }; return false }
        for op in ordered {
            switch op {
            case .remove(let node):
                guard node > 0, live(node) else { continue }
                detach(node)
                st.flags[node] |= Tree.removedFlag
                dropDescendants(node)
                kids[node] = nil
                removed.insert(node)
            case .move(let node, let to, let name):
                guard node > 0, live(node), live(to), st.flags[to] & 1 != 0 else { continue }
                // Not into itself.
                var cur = to, inside = false
                while cur != Int(UInt32.max) { if cur == node { inside = true; break }; cur = Int(st.parents[cur]) }
                guard !inside else { continue }
                detach(node)
                attach(node, to: to)
                if let name { setName(node, name) }
            case .replace(let node, let g):
                guard live(node), g.count > 0 else { continue }
                let p = Int(st.parents[node])
                let old = (st.alloc[node], st.logical[node], files(node))
                dropDescendants(node)
                graft(g, root: node)
                if p != Int(UInt32.max) {
                    propagate(from: p, alloc: old.0, logical: old.1, files: old.2, sign: -1)
                    propagate(from: p, alloc: st.alloc[node], logical: st.logical[node], files: files(node), sign: 1)
                    resort.insert(p)
                }
            case .insert(let g, let under, let name):
                guard live(under), st.flags[under] & 1 != 0, g.count > 0 else { continue }
                let root = next
                next += 1
                graft(g, root: root)
                setName(root, name)
                attach(root, to: under)
            case .insertFile(let under, let name, let a, let l):
                guard live(under), st.flags[under] & 1 != 0 else { continue }
                let i = next
                next += 1
                st.alloc[i] = a; st.logical[i] = l; st.nFiles[i] = 0; st.flags[i] = 0
                setName(i, name)
                attach(i, to: under)
            case .resize(let node, let a, let l):
                guard node > 0, live(node), st.flags[node] & 1 == 0 else { continue }
                let p = Int(st.parents[node])
                propagate(from: p, alloc: st.alloc[node], logical: st.logical[node], files: 0, sign: -1)
                st.alloc[node] = a; st.logical[node] = l
                propagate(from: p, alloc: a, logical: l, files: 0, sign: 1)
            }
        }
        // Slots reserved for ops that were skipped: unreachable, marked removed.
        for i in next..<n { st.parents[i] = UInt32.max; st.alloc[i] = 0; st.logical[i] = 0; st.nFiles[i] = 0; st.flags[i] = Tree.removedFlag }

        // Largest first, as the engine sorts: sizes changed up every ancestor chain.
        for p in resort.union(kids.keys) where p < n && st.flags[p] & Tree.removedFlag == 0 {
            kids[p] = list(p).sorted { st.alloc[Int($0)] > st.alloc[Int($1)] || (st.alloc[Int($0)] == st.alloc[Int($1)] && $0 < $1) }
        }

        // Rebuild the child index: untouched lists are copied straight across.
        var total = 0
        for i in 0..<n {
            st.childOff[i] = UInt32(total)
            if st.flags[i] & Tree.removedFlag != 0 { continue }
            if let k = kids[i] { total += k.count }
            else if i < n0 { total += Int(base.childOff[i + 1] - base.childOff[i]) }
        }
        st.childOff[n] = UInt32(total)
        st.childArr.deallocate()
        st.childArr = .allocate(capacity: max(total, 1))
        for i in 0..<n where st.flags[i] & Tree.removedFlag == 0 {
            let at = Int(st.childOff[i])
            if let k = kids[i] {
                k.withUnsafeBufferPointer { (st.childArr + at).update(from: $0.baseAddress!, count: k.count) }
            } else if i < n0 {
                let c = base.children(i)
                if let src = c.baseAddress, c.count > 0 { (st.childArr + at).update(from: src, count: c.count) }
            }
        }
        var extra: UnsafePointer<UInt8>?
        if !blob.isEmpty {
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: blob.count)
            blob.withUnsafeBufferPointer { p.update(from: $0.baseAddress!, count: blob.count) }
            st.extraBlob = p
            extra = UnsafePointer(p)
        }
        let changed = Set(kids.keys.filter { $0 < n && st.flags[$0] & Tree.removedFlag == 0 })
        return Tree(editing: base, storage: st, count: n, extraNames: extraNames, extraBlob: extra,
                    edit: TreeEditInfo(changedParents: changed, removed: removed))
    }

    /// Not removed, and no folder above it was.
    static func isLive(_ node: Int, in tree: Tree) -> Bool {
        guard node >= 0, node < tree.count else { return false }
        var cur = node
        while cur != Int(UInt32.max) {
            if tree.isRemoved(cur) { return false }
            cur = Int(tree.parents[cur])
        }
        return true
    }

    /// Node for an absolute path, or nil when it isn't in the tree.
    static func node(for path: String, in tree: Tree) -> Int? {
        let root = tree.path(0)
        var rel: Substring
        if path == root { return 0 }
        if root == "/" {
            guard path.hasPrefix("/") else { return nil }
            rel = path.dropFirst()
        } else {
            guard path.hasPrefix(root + "/") else { return nil }
            rel = path.dropFirst(root.count + 1)
        }
        var cur = 0
        for part in rel.split(separator: "/") {
            let want = Array(part.utf8)
            var found: Int?
            for k in tree.children(cur) {
                let name = tree.nameBytes(Int(k))
                if name.count == want.count, name.elementsEqual(want) { found = Int(k); break }
            }
            guard let f = found else { return nil }
            cur = f
        }
        return cur
    }
}

/// Turns "these paths were deleted or moved" into tree edits, checking the
/// disk for each one. Runs off the main thread.
nonisolated enum DiskChanges {
    /// Scan one folder with the engine, synchronously (we are off-main).
    static let scanFolder: @Sendable (String) -> Tree? = { path in
        guard let h = bz_scan_start(path) else { return nil }
        var f: UInt64 = 0, d: UInt64 = 0, b: UInt64 = 0
        var done: Int32 = 0
        while true {
            bz_progress(h, &f, &d, &b, &done)
            if done != 0 { break }
            usleep(2_000)
        }
        guard let tree = Tree(handle: h) else { bz_free(h); return nil }
        return tree
    }

    private static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    private static func fileSizes(_ path: String) -> (alloc: UInt64, logical: UInt64, dir: Bool)? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return (UInt64(max(0, st.st_blocks)) * 512, UInt64(max(0, st.st_size)), (st.st_mode & S_IFMT) == S_IFDIR)
    }

    /// The scan may be `/System/Volumes/Data` while macOS reports a Trash
    /// move as `/Users/…`: the same place through the firmlink.
    static func inScan(_ path: String, root: String) -> String? {
        func inside(_ p: String) -> Bool { root == "/" ? p.hasPrefix("/") : (p == root || p.hasPrefix(root + "/")) }
        if inside(path) { return path }
        let data = "/System/Volumes/Data"
        if root.hasPrefix(data), inside(data + path) { return data + path }
        if path.hasPrefix(data + "/"), inside(String(path.dropFirst(data.count))) { return String(path.dropFirst(data.count)) }
        return nil
    }

    static func edit(_ tree: Tree, paths: [String], moves: [String: String], refresh: [String]) -> Tree? {
        let root = tree.path(0)
        var ops: [TreeOp] = []
        var rescan: [String] = []
        var touched = Set<Int>()
        for path in paths {
            guard let node = TreeEdit.node(for: path, in: tree), node != 0, touched.insert(node).inserted else { continue }
            if exists(path) {
                // Still there: a partial delete, or the move failed. Its size
                // is uncertain, so rescan just this item.
                rescan.append(path)
                continue
            }
            if let dest = moves[path], let inside = inScan(dest, root: root) {
                let parent = (inside as NSString).deletingLastPathComponent
                if let to = TreeEdit.node(for: parent, in: tree), tree.isDir(to) {
                    let name = (inside as NSString).lastPathComponent
                    ops.append(.move(node, to: to, name: name == tree.name(node) ? nil : name))
                    continue
                }
                ops.append(.remove(node))
                rescan.append(inside)
                continue
            }
            ops.append(.remove(node))
        }
        for path in refresh { if let p = inScan(path, root: root) { rescan.append(p) } }
        var seen = Set<String>()
        for path in rescan where seen.insert(path).inserted {
            ops.append(contentsOf: refreshOps(path, tree: tree, root: root))
        }
        guard !ops.isEmpty else { return nil }
        return TreeEdit.apply(ops, to: tree)
    }

    /// Rescan one path: in the tree already, or new (attached under its
    /// nearest folder that is). Never the scan root.
    static func refreshOps(_ path: String, tree: Tree, root: String) -> [TreeOp] {
        guard path != root else { return [] }
        if let node = TreeEdit.node(for: path, in: tree) {
            guard let info = fileSizes(path) else { return [.remove(node)] }
            if !info.dir { return tree.isDir(node) ? [] : [.resize(node, alloc: info.alloc, logical: info.logical)] }
            guard tree.isDir(node), let g = scanFolder(path) else { return [] }
            return [.replace(node, with: g)]
        }
        guard let info = fileSizes(path) else { return [] }
        let parent = (path as NSString).deletingLastPathComponent
        guard let under = TreeEdit.node(for: parent, in: tree) else {
            // Its folder is new too: bring in that folder instead.
            return parent == root || parent.count >= path.count ? [] : refreshOps(parent, tree: tree, root: root)
        }
        let name = (path as NSString).lastPathComponent
        if !info.dir { return [.insertFile(under: under, name: name, alloc: info.alloc, logical: info.logical)] }
        guard let g = scanFolder(path) else { return [] }
        return [.insert(g, under: under, name: name)]
    }

    /// Finder-style: after deleting rows, select the next surviving sibling
    /// of the first deleted one, else the previous, else its folder (unless
    /// that is the folder on screen).
    static func successor(of node: Int, removed: Set<Int>, old: Tree, new: Tree, viewRoot: Int) -> Int? {
        let parent = Int(old.parents[node])
        guard parent != Int(UInt32.max) else { return nil }
        let siblings = old.children(parent).map(Int.init)
        guard let at = siblings.firstIndex(of: node) else { return nil }
        let alive = { (i: Int) in !removed.contains(i) && TreeEdit.isLive(i, in: new) && Int(new.parents[i]) == parent }
        if let after = siblings[(at + 1)...].first(where: alive) { return after }
        if let before = siblings[..<at].last(where: alive) { return before }
        return parent == viewRoot || !TreeEdit.isLive(parent, in: new) ? nil : parent
    }
}
