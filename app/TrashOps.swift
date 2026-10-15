import AppKit
import Foundation

/// Where a path sits relative to a macOS Trash, and what a delete is allowed to do.
///
/// `trashItem` cannot move something that is already in a Trash, and it fails
/// outright on another user's files. Callers use this to choose a permanent
/// delete, a normal Trash move, or one administrator retry.

nonisolated enum TrashPaths {
    static func normalize(_ path: String) -> String {
        var s = (path as NSString).expandingTildeInPath
        s = (s as NSString).standardizingPath
        if s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? "/" : s
    }

    static func resolve(_ path: String) -> String {
        var s = (normalize(path) as NSString).resolvingSymlinksInPath
        if s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? "/" : s
    }

    /// Standardized form and, when it differs, the symlink-resolved form.
    static func forms(_ path: String) -> [String] {
        let plain = normalize(path)
        let resolved = resolve(path)
        return plain == resolved ? [plain] : [plain, resolved]
    }

    static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    /// `~/.Trash` for this user, in every path form macOS might report.
    static func homeTrashForms() -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for form in forms(NSHomeDirectory() + "/.Trash") where seen.insert(form).inserted {
            out.append(form)
        }
        return out
    }
}

nonisolated enum TrashPlace {
    /// True when `path` is a Trash directory or something inside one.
    /// Moving it to the Trash cannot succeed: it is already there.
    static func contains(_ path: String) -> Bool {
        let homes = TrashPaths.homeTrashForms()
        return TrashPaths.forms(path).contains { form in
            isUserTrash(form) || isVolumeTrash(form) || homes.contains { form == $0 || form.hasPrefix($0 + "/") }
        }
    }

    /// `/Users/<name>/.Trash` and the Data-volume firmlink of the same folder.
    /// A project directory that happens to be named `.Trash` is not a Trash.
    static func isUserTrash(_ path: String) -> Bool {
        let parts = TrashPaths.components(path)
        guard let users = parts.firstIndex(of: "Users") else { return false }
        let prefix = Array(parts[..<users])
        guard prefix.isEmpty || prefix == ["System", "Volumes", "Data"] else { return false }
        let name = parts.index(after: users)
        guard name < parts.endIndex else { return false }
        let trash = parts.index(after: name)
        return trash < parts.endIndex && parts[trash] == ".Trash"
    }

    /// `/Volumes/<vol>/.Trashes/<uid>` and its contents. The `.Trashes` directory
    /// itself is the parent of every user's trash on that volume, not one trash.
    static func isVolumeTrash(_ path: String) -> Bool {
        let parts = TrashPaths.components(path)
        guard parts.count >= 4, parts[0] == "Volumes", parts[2] == ".Trashes" else { return false }
        return !parts[3].isEmpty && parts[3].allSatisfy(\.isNumber)
    }
}

nonisolated enum TrashSafety {
    /// Exact paths a delete must never remove. Children of these are still
    /// allowed: the scan root's contents are the files the user picked.
    static let critical: Set<String> = [
        "/", "/System", "/System/Volumes", "/System/Volumes/Data",
        "/usr", "/bin", "/sbin", "/private", "/dev", "/etc", "/var",
        "/opt", "/Library", "/System/Library", "/Applications",
        "/Users", "/Volumes",
        "/private/etc", "/private/var", "/private/tmp",
        "/System/Volumes/Data/Users", "/System/Volumes/Data/Applications",
        "/System/Volumes/Data/Library", "/System/Volumes/Data/opt",
        "/System/Volumes/Data/private",
    ]

    /// This user's home, plus its firmlink twin, so `/var/root` is covered too.
    static let homePaths: Set<String> = {
        var set = Set(TrashPaths.forms(NSHomeDirectory()))
        for form in set {
            let parts = TrashPaths.components(form)
            if parts.count == 2, parts[0] == "Users" {
                set.insert("/System/Volumes/Data/Users/\(parts[1])")
            }
            if parts.count == 5, parts[0] == "System", parts[1] == "Volumes",
               parts[2] == "Data", parts[3] == "Users" {
                set.insert("/Users/\(parts[4])")
            }
        }
        return set
    }()

    /// Every account's home directory, not the files inside it. Deleting
    /// `/Users/tgm` would wipe that account; deleting a file inside it would not.
    static func isHomeRoot(_ path: String) -> Bool {
        let parts = TrashPaths.components(path)
        if parts.count == 2, parts[0] == "Users" { return true }
        if parts.count == 5, parts[0] == "System", parts[1] == "Volumes",
           parts[2] == "Data", parts[3] == "Users" { return true }
        return false
    }

    static func isBlocked(_ path: String, scanRoot: String = "") -> Bool {
        if path.isEmpty { return true }
        let roots = scanRoot.isEmpty ? [] : TrashPaths.forms(scanRoot).filter { $0 != "/" }
        for form in TrashPaths.forms(path) {
            if critical.contains(form) || isHomeRoot(form) || homePaths.contains(form) { return true }
            if roots.contains(form) { return true }
        }
        return false
    }

    static func allows(_ path: String, scanRoot: String = "") -> Bool {
        !isBlocked(path, scanRoot: scanRoot)
    }

    static func refused(_ path: String) -> NSError {
        NSError(domain: "BlitzTree", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "BlitzTree won't delete \(path).",
        ])
    }
}

nonisolated struct TrashFailure: Sendable {
    var label: String
    var path: String
    var message: String
    var permission: Bool
    var inTrash: Bool
    var bytes: UInt64

    func replacing(message: String, permission: Bool) -> TrashFailure {
        TrashFailure(label: label, path: path, message: message, permission: permission,
                     inTrash: inTrash, bytes: bytes)
    }
}

nonisolated struct TrashTarget: Sendable {
    var path: String
    var label: String
    var bytes: UInt64
    var inTrash: Bool
}

nonisolated enum TrashError {
    /// Permission failures are retried once, as administrator. An injected
    /// benchmark error ("injected failure") must not match.
    static func isPermission(_ error: Error) -> Bool {
        var seen = Set<String>()
        return check(error as NSError, seen: &seen)
    }

    private static func check(_ error: NSError, seen: inout Set<String>) -> Bool {
        let key = "\(error.domain) \(error.code)"
        if !seen.insert(key).inserted { return false }
        if error.domain == NSCocoaErrorDomain,
           error.code == NSFileReadNoPermissionError || error.code == NSFileWriteNoPermissionError {
            return true
        }
        if error.domain == NSPOSIXErrorDomain,
           error.code == Int(EACCES) || error.code == Int(EPERM) {
            return true
        }
        let text = error.localizedDescription.lowercased()
        if text.contains("permission") || text.contains("not permitted") { return true }
        if let reason = error.localizedFailureReason?.lowercased(),
           reason.contains("permission") || reason.contains("not permitted") {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, check(underlying, seen: &seen) {
            return true
        }
        if let many = error.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] {
            for item in many where check(item, seen: &seen) { return true }
        }
        return false
    }
}

nonisolated enum TrashCopy {
    struct Prompt: Sendable {
        var title: String
        var message: String
        var button: String
    }

    static func deletion(permanent: Int, permanentBytes: UInt64, move: Int, moveBytes: UInt64, name: String?) -> Prompt {
        if permanent > 0, move == 0 {
            let title = permanent == 1
                ? "Delete \u{201C}\(name ?? "this item")\u{201D} permanently?"
                : "Delete \(permanent) items permanently?"
            let message = permanent == 1
                ? "\(Fmt.size(permanentBytes)) in the Trash. This can't be undone."
                : "\(permanent) items, \(Fmt.size(permanentBytes)), already in the Trash. This can't be undone."
            return Prompt(title: title, message: message, button: "Delete Permanently")
        }
        if permanent > 0, move > 0 {
            let title = "Delete \(permanent) \(permanent == 1 ? "item" : "items") and move \(move) to the Trash?"
            let message = "\(describe(permanent, permanentBytes)) \(permanent == 1 ? "is" : "are") already in the Trash and will be deleted permanently. This can't be undone. \(describe(move, moveBytes)) will move to the Trash, and you can put \(move == 1 ? "it" : "them") back until you empty it."
            return Prompt(title: title, message: message, button: "Delete and Move")
        }
        let title = move == 1
            ? "Move \u{201C}\(name ?? "this item")\u{201D} to the Trash?"
            : "Move \(move) items to the Trash?"
        let message = move == 1
            ? "\(Fmt.size(moveBytes)). You can put it back from the Trash until you empty it."
            : "\(Fmt.size(moveBytes)). You can put them back from the Trash until you empty it."
        return Prompt(title: title, message: message, button: "Move to Trash")
    }

    /// Delete in this app means "move to the Trash", which can be undone.
    /// Administrator rights follow that: a file already in a Trash is removed
    /// for good, and any other file is moved into its owner's Trash.
    static func authorization(permanent: Int, permanentBytes: UInt64, move: Int, moveBytes: UInt64) -> Prompt {
        if permanent > 0, move == 0 {
            let noun = permanent == 1 ? "item" : "items"
            return Prompt(
                title: "Delete \(permanent) \(noun) permanently?",
                message: "\(permanent == 1 ? "It's" : "They're") already in the Trash (\(Fmt.size(permanentBytes))), and you don't have permission to delete \(permanent == 1 ? "it" : "them"). This can't be undone. macOS will ask for an administrator password.",
                button: "Delete Permanently")
        }
        if move > 0, permanent == 0 {
            let noun = move == 1 ? "item" : "items"
            return Prompt(
                title: "Move \(move) \(noun) to the Trash?",
                message: "You don't have permission to move \(move == 1 ? "it" : "them") (\(Fmt.size(moveBytes))). \(move == 1 ? "It goes" : "They go") into the owner's Trash, and you can put \(move == 1 ? "it" : "them") back from there. macOS will ask for an administrator password.",
                button: "Authorize")
        }
        return Prompt(
            title: "Delete \(permanent) and move \(move) with an administrator password?",
            message: "\(describe(permanent, permanentBytes)) \(permanent == 1 ? "is" : "are") already in the Trash and will be deleted permanently. This can't be undone. \(describe(move, moveBytes)) will move into the owner's Trash, which you can put back.",
            button: "Authorize")
    }

    private static func describe(_ count: Int, _ bytes: UInt64) -> String {
        let noun = count == 1 ? "item" : "items"
        return "\(count) \(noun) (\(Fmt.size(bytes)))"
    }
}

nonisolated enum TrashReport {
    struct Summary: Sendable {
        var title: String
        var reason: String
        var details: String
        var count: Int
    }

    static func summarize(_ failures: [TrashFailure]) -> Summary {
        summarize(lines: failures.map { "\($0.label): \($0.message)" },
                  permission: failures.filter(\.permission).count)
    }

    static func summarize(lines: [String]) -> Summary {
        let permission = lines.filter { line in
            let text = line.lowercased()
            return text.contains("permission") || text.contains("not permitted")
        }.count
        return summarize(lines: lines, permission: permission)
    }

    private static func summarize(lines: [String], permission: Int) -> Summary {
        let count = lines.count
        let details = lines.joined(separator: "\n")
        if count == 0 { return Summary(title: "", reason: "", details: "", count: 0) }
        if count == 1 {
            let line = lines[0]
            let label: String
            let message: String
            if let range = line.range(of: ": ") {
                label = String(line[..<range.lowerBound])
                message = String(line[range.upperBound...])
            } else {
                label = line
                message = line
            }
            let reason = permission == 1 ? "Permission denied." : message
            return Summary(title: "\u{201C}\(label)\u{201D} couldn't be deleted", reason: reason, details: details, count: 1)
        }
        if permission == count {
            return Summary(title: "\(count) items couldn't be deleted: permission denied",
                           reason: "You don't have permission to change them.",
                           details: details, count: count)
        }
        if permission == 0 {
            return Summary(title: "\(count) items couldn't be deleted",
                           reason: "Something went wrong.",
                           details: details, count: count)
        }
        return Summary(title: "\(count) items couldn't be deleted",
                       reason: "\(permission) permission denied, \(count - permission) failed for another reason.",
                       details: details, count: count)
    }
}

extension Trash {
    /// Permanent delete. Only for something that is already in a Trash, and
    /// never for the scan root or a system path.
    nonisolated static func removeNow(_ path: String, scanRoot: String) throws {
        guard TrashSafety.allows(path, scanRoot: scanRoot) else {
            throw TrashSafety.refused(path)
        }
        try FileManager.default.removeItem(atPath: path)
    }
}

/// One administrator password for a whole batch.
///
/// Files already in a Trash are removed. Everything else is moved into that
/// file's owner's Trash (`/Users/<name>/.Trash`, or `/Volumes/<vol>/.Trashes/<uid>`),
/// so the delete stays reversible. The shell script is fixed; paths travel in a
/// NUL-delimited list and are quoted with AppleScript's `quoted form of`.
@MainActor
enum TrashAdmin {
    struct Outcome: Sendable {
        var moved: [String: String] = [:]
        var removed: Set<String> = []
        var failures: [TrashFailure] = []
        var cancelled = false
    }

    static func retry(_ items: [TrashFailure], scanRoot: String) -> Outcome {
        let eligible = items.filter { $0.permission && TrashSafety.allows($0.path, scanRoot: scanRoot) }
        guard !eligible.isEmpty else {
            return Outcome(failures: items, cancelled: true)
        }
        let prompt = TrashCopy.authorization(
            permanent: eligible.filter(\.inTrash).count,
            permanentBytes: eligible.filter(\.inTrash).reduce(0) { $0 + $1.bytes },
            move: eligible.filter { !$0.inTrash }.count,
            moveBytes: eligible.filter { !$0.inTrash }.reduce(0) { $0 + $1.bytes })
        let alert = NSAlert()
        alert.alertStyle = eligible.contains(where: \.inTrash) ? .critical : .warning
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.addButton(withTitle: prompt.button)
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return Outcome(failures: items, cancelled: true)
        }
        return run(eligible, scanRoot: scanRoot, original: items)
    }

    private static func run(_ eligible: [TrashFailure], scanRoot: String, original: [TrashFailure]) -> Outcome {
        let fallback = TrashPaths.normalize(NSHomeDirectory() + "/.Trash")
        let directory = FileManager.default.temporaryDirectory
        let id = UUID().uuidString
        let scriptURL = directory.appendingPathComponent("blitztree-trash-\(id).sh")
        let listURL = directory.appendingPathComponent("blitztree-trash-\(id).list")
        let resultURL = directory.appendingPathComponent("blitztree-trash-\(id).out")
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: listURL)
            try? FileManager.default.removeItem(at: resultURL)
        }
        do {
            try scriptSource.write(to: scriptURL, atomically: true, encoding: .utf8)
            try listData(eligible).write(to: listURL, options: .atomic)
            FileManager.default.createFile(atPath: resultURL.path, contents: Data(),
                                           attributes: [.posixPermissions: 0o644])
        } catch {
            return Outcome(failures: eligible.map {
                $0.replacing(message: "The administrator authorization failed.", permission: true)
            })
        }
        guard let source = appleSource(script: scriptURL.path, list: listURL.path,
                                        fallback: fallback, result: resultURL.path, scanRoot: scanRoot) else {
            return Outcome(failures: eligible.map {
                $0.replacing(message: "The administrator authorization failed.", permission: true)
            })
        }
        var info: NSDictionary?
        guard let runner = NSAppleScript(source: source) else {
            return Outcome(failures: eligible.map {
                $0.replacing(message: "The administrator authorization failed.", permission: true)
            })
        }
        _ = runner.executeAndReturnError(&info)
        if let info {
            if appleErrorNumber(info) == -128 {
                return Outcome(failures: original, cancelled: true)
            }
            let message = (info[NSAppleScript.errorMessage] as? String) ?? "The administrator authorization failed."
            return Outcome(failures: eligible.map { $0.replacing(message: message, permission: true) })
        }
        let parsed = parse(result: (try? Data(contentsOf: resultURL)) ?? Data())
        var outcome = Outcome()
        for item in eligible {
            guard let row = parsed[item.path] else {
                outcome.failures.append(item)
                continue
            }
            if row.ok {
                if row.extra.isEmpty { outcome.removed.insert(item.path) }
                else { outcome.moved[item.path] = row.extra }
            } else if row.extra == "refused" {
                outcome.failures.append(item.replacing(message: TrashSafety.refused(item.path).localizedDescription,
                                                       permission: false))
            } else {
                outcome.failures.append(item.replacing(message: row.extra.isEmpty ? "permission denied" : row.extra,
                                                       permission: true))
            }
        }
        return outcome
    }

    /// AppleScript string literal. Rejects control characters so a path cannot
    /// break out of the quoted script.
    static func appleString(_ value: String) -> String? {
        if value.unicodeScalars.contains(where: { $0.value < 0x20 }) { return nil }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func appleSource(script: String, list: String, fallback: String, result: String, scanRoot: String) -> String? {
        guard let scriptLit = appleString(script), let listLit = appleString(list),
              let fallbackLit = appleString(fallback), let resultLit = appleString(result),
              let rootLit = appleString(scanRoot) else { return nil }
        return "do shell script \"/bin/bash \" & quoted form of \(scriptLit) & \" \" & quoted form of \(listLit) & \" \" & quoted form of \(fallbackLit) & \" \" & quoted form of \(resultLit) & \" \" & quoted form of \(rootLit) with prompt \"BlitzTree needs permission to change items you can't access.\" with administrator privileges"
    }

    private static func listData(_ items: [TrashFailure]) -> Data {
        var body = Data()
        func add(_ field: String) {
            body.append(contentsOf: field.utf8)
            body.append(UInt8(0))
        }
        for item in items {
            add(item.inTrash ? "rm" : "mv")
            add(item.path)
            add("")
        }
        return body
    }

    private static func parse(result data: Data) -> [String: (ok: Bool, extra: String)] {
        var fields: [String] = []
        var chunk = Data()
        for byte in data {
            if byte == 0 {
                fields.append(String(decoding: chunk, as: UTF8.self))
                chunk.removeAll(keepingCapacity: true)
            } else {
                chunk.append(byte)
            }
        }
        if !chunk.isEmpty { fields.append(String(decoding: chunk, as: UTF8.self)) }
        var map: [String: (ok: Bool, extra: String)] = [:]
        var index = 0
        while index + 2 < fields.count {
            map[fields[index + 1]] = (fields[index] == "ok", fields[index + 2])
            index += 3
        }
        return map
    }

    private static func appleErrorNumber(_ info: NSDictionary) -> Int? {
        let value = info[NSAppleScript.errorNumber] ?? info["NSAppleScriptErrorNumber"]
        if let number = value as? NSNumber { return number.intValue }
        if let number = value as? Int { return number }
        return nil
    }

    nonisolated static let scriptSource = #"""
#!/bin/bash
# Privileged delete/move. Invoked as root via `do shell script ... with
# administrator privileges`. Paths arrive only as NUL records in $1; this
# file never interpolates them into a shell command line.
# Records: mode \0 path \0 dest \0
# Results: status \0 path \0 destination \0   (destination empty when removed)
set -u
list="$1"
fallback="$2"
result="$3"
scanroot="${4:-}"

: > "$result"

write_result() {
  # $1 status, $2 path, $3 destination or message
  printf '%s\0%s\0%s\0' "$1" "$2" "$3" >> "$result"
}

refuse() {
  case "$1" in
    ""|/|.)
      return 0 ;;
    /System|/System/Volumes|/System/Volumes/Data|/usr|/bin|/sbin|/private|/dev|/etc|/var|/opt|/Library|/System/Library|/Applications|/Users|/Volumes)
      return 0 ;;
    /private/etc|/private/var|/private/tmp)
      return 0 ;;
    /System/Volumes/Data/Users|/System/Volumes/Data/Applications|/System/Volumes/Data/Library|/System/Volumes/Data/opt|/System/Volumes/Data/private)
      return 0 ;;
  esac
  case "$1" in
    /*) ;;
    *) return 0 ;;
  esac
  case "$1" in
    /Users/*)
      rest="${1#/Users/}"
      case "$rest" in
        */*) ;;
        *) return 0 ;;
      esac
      ;;
    /System/Volumes/Data/Users/*)
      rest="${1#/System/Volumes/Data/Users/}"
      case "$rest" in
        */*) ;;
        *) return 0 ;;
      esac
      ;;
  esac
  if [ -n "$scanroot" ] && [ "$1" = "$scanroot" ]; then
    return 0
  fi
  return 1
}

already_trash() {
  local p="$1" home_trash="$2" rest user vol uid
  case "$p" in
    /Users/*)
      rest="${p#/Users/}"
      user="${rest%%/*}"
      rest="${rest#"$user"}"
      case "$rest" in
        /.Trash|/.Trash/*) return 0 ;;
      esac
      ;;
    /System/Volumes/Data/Users/*)
      rest="${p#/System/Volumes/Data/Users/}"
      user="${rest%%/*}"
      rest="${rest#"$user"}"
      case "$rest" in
        /.Trash|/.Trash/*) return 0 ;;
      esac
      ;;
  esac
  case "$p" in
    /Volumes/*/*)
      rest="${p#/Volumes/}"
      vol="${rest%%/*}"
      rest="${rest#"$vol"/}"
      case "$rest" in
        .Trashes/*) ;;
        *) rest="" ;;
      esac
      if [ -n "$rest" ]; then
        rest="${rest#.Trashes/}"
        uid="${rest%%/*}"
        case "$uid" in
          ""|*[!0-9]*) ;;
          *) return 0 ;;
        esac
      fi
      ;;
  esac
  if [ -n "$home_trash" ]; then
    case "$p" in
      "$home_trash"|"$home_trash"/*) return 0 ;;
    esac
  fi
  return 1
}

owner_trash() {
  local p="$1" hint="$2" rest user vol uid
  case "$p" in
    /System/Volumes/Data/Users/*/*)
      rest="${p#/System/Volumes/Data/Users/}"
      user="${rest%%/*}"
      printf '%s' "/System/Volumes/Data/Users/$user/.Trash"
      return
      ;;
    /Users/*/*)
      rest="${p#/Users/}"
      user="${rest%%/*}"
      printf '%s' "/Users/$user/.Trash"
      return
      ;;
    /Volumes/*/*)
      rest="${p#/Volumes/}"
      vol="${rest%%/*}"
      if [ -e "$p" ]; then
        uid=$(/usr/bin/stat -f '%u' "$p" 2>/dev/null) || uid=""
      else
        uid=""
      fi
      if [ -n "$uid" ]; then
        printf '%s' "/Volumes/$vol/.Trashes/$uid"
        return
      fi
      ;;
  esac
  printf '%s' "$hint"
}

unique_dest() {
  local dir="$1" base="$2" stem ext n dest
  case "$base" in
    .*|*.*)
      case "$base" in
        .*) stem="$base"; ext="" ;;
        *) ext=".${base##*.}"; stem="${base%.*}" ;;
      esac
      ;;
    *) stem="$base"; ext="" ;;
  esac
  dest="$dir/$base"
  if [ ! -e "$dest" ]; then
    printf '%s' "$dest"
    return 0
  fi
  n=2
  while [ -e "$dir/$stem $n$ext" ]; do
    n=$((n + 1))
    if [ "$n" -gt 999 ]; then
      return 1
    fi
  done
  printf '%s' "$dir/$stem $n$ext"
}

process_one() {
  local mode="$1" path="$2" hint="$3" target base dest_file uid gid
  if refuse "$path"; then
    write_result fail "$path" "refused"
    return
  fi
  if already_trash "$path" "$fallback"; then
    mode="rm"
  fi
  case "$mode" in
    rm)
      if ! already_trash "$path" "$fallback"; then
        write_result fail "$path" "refused"
        return
      fi
      if /bin/rm -rf -- "$path"; then
        write_result ok "$path" ""
      else
        write_result fail "$path" "couldn't delete"
      fi
      ;;
    mv)
      if [ -z "$hint" ]; then
        hint="$fallback"
      fi
      target=$(owner_trash "$path" "$hint")
      if [ -z "$target" ] || refuse "$target"; then
        write_result fail "$path" "no trash folder"
        return
      fi
      if [ ! -d "$target" ]; then
        if ! /bin/mkdir -p -- "$target"; then
          write_result fail "$path" "couldn't create trash"
          return
        fi
        # A trash folder we just created should belong to the home's owner,
        # not root, so that person can put the file back.
        if [ -d "${target%/*}" ]; then
          uid=$(/usr/bin/stat -f '%u' "${target%/*}" 2>/dev/null) || uid=""
          gid=$(/usr/bin/stat -f '%g' "${target%/*}" 2>/dev/null) || gid=""
          if [ -n "$uid" ] && [ -n "$gid" ]; then
            /usr/sbin/chown "$uid:$gid" "$target" 2>/dev/null || true
          fi
          /bin/chmod 700 "$target" 2>/dev/null || true
        fi
      fi
      base="${path##*/}"
      if [ -z "$base" ] || [ "$base" = "/" ] || [ "$base" = "." ] || [ "$base" = ".." ]; then
        write_result fail "$path" "refused"
        return
      fi
      dest_file=$(unique_dest "$target" "$base") || {
        write_result fail "$path" "name in use"
        return
      }
      if /bin/mv -- "$path" "$dest_file"; then
        write_result ok "$path" "$dest_file"
      else
        write_result fail "$path" "couldn't move to trash"
      fi
      ;;
    *)
      write_result fail "$path" "refused"
      ;;
  esac
}

while IFS= read -r -d '' mode && IFS= read -r -d '' path && IFS= read -r -d '' hint; do
  process_one "$mode" "$path" "$hint"
done < "$list"
exit 0
"""#
}

@MainActor
enum TrashRetry {
    /// Permission failures get one authorization prompt. Cancelling it leaves
    /// the original errors in place, so a dismissed password dialog is not a
    /// second failure for every file.
    static func settle(_ failed: [TrashFailure], succeeded: Int, scanRoot: String) -> (failed: [TrashFailure], succeeded: Int) {
        let eligible = failed.filter { $0.permission && TrashSafety.allows($0.path, scanRoot: scanRoot) }
        guard !eligible.isEmpty else { return (failed, succeeded) }
        let outcome = TrashAdmin.retry(eligible, scanRoot: scanRoot)
        if outcome.cancelled { return (failed, succeeded) }
        let done = outcome.removed.union(outcome.moved.keys)
        let updates = Dictionary(outcome.failures.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var kept: [TrashFailure] = []
        for item in failed {
            if done.contains(item.path) { continue }
            kept.append(updates[item.path] ?? item)
        }
        return (kept, succeeded + done.count)
    }
}

@MainActor
enum TrashUI {
    static func confirm(permanent: [TrashTarget], movable: [TrashTarget]) -> Bool {
        guard !permanent.isEmpty || !movable.isEmpty else { return false }
        let prompt = TrashCopy.deletion(
            permanent: permanent.count,
            permanentBytes: permanent.reduce(0) { $0 + $1.bytes },
            move: movable.count,
            moveBytes: movable.reduce(0) { $0 + $1.bytes },
            name: (permanent.count + movable.count) == 1 ? (permanent.first ?? movable.first)?.label : nil)
        let alert = NSAlert()
        alert.alertStyle = permanent.isEmpty ? .warning : .critical
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.addButton(withTitle: prompt.button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func present(_ failures: [TrashFailure]) {
        present(TrashReport.summarize(failures))
    }

    static func present(lines: [String]) {
        present(TrashReport.summarize(lines: lines))
    }

    private static func present(_ summary: TrashReport.Summary) {
        guard summary.count > 0 else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = summary.title
        alert.informativeText = summary.reason
        alert.addButton(withTitle: "OK")
        if summary.count > 1 { alert.addButton(withTitle: "Show Details") }
        guard alert.runModal() == .alertSecondButtonReturn, summary.count > 1 else { return }
        let detail = NSAlert()
        detail.alertStyle = .warning
        detail.messageText = summary.title
        detail.informativeText = summary.reason
        detail.accessoryView = detailView(summary.details)
        detail.addButton(withTitle: "OK")
        detail.runModal()
    }

    private static func detailView(_ text: String) -> NSView {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 180))
        view.string = text
        view.isEditable = false
        view.isSelectable = true
        view.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 440, height: CGFloat.greatestFiniteMagnitude)
        view.minSize = NSSize(width: 0, height: 180)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 180))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.documentView = view
        return scroll
    }
}
