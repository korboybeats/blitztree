#!/usr/bin/env python3
"""Build a real SwiftUI/AppKit scan-handoff harness with agent startup disabled.

Sources are frozen in a temporary directory; only the harness's ContentView gets
an injected model and loses launch-time scan/agent callbacks. No preferences in
the installed BlitzTree bundle are changed. Run the binary with a scan path.
"""
import argparse
import pathlib
import re
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--ref", help="Git source revision; defaults to working tree")
parser.add_argument("--output", type=pathlib.Path, required=True)
parser.add_argument("--wmo", action="store_true")
parser.add_argument("--ui-current", action="store_true", help="Use current Model/ContentView with --ref renderers")
args = parser.parse_args()
work = pathlib.Path(tempfile.mkdtemp(prefix="blitztree-handoff-"))
try:
    files = []
    for path in sorted((ROOT / "app").glob("*.swift")):
        if path.name == "Main.swift":
            continue
        current_ui = {"Model.swift", "ContentView.swift", "Cleanup.swift", "Agent.swift", "TrashOps.swift"}
        if not args.ref or (args.ui_current and path.name in current_ui):
            source = path.read_text()
        else:
            try:
                source = subprocess.check_output(["git", "show", f"{args.ref}:app/{path.name}"], cwd=ROOT).decode()
            except subprocess.CalledProcessError:
                continue
        if path.name == "ContentView.swift":
            source = source.replace("@State private var model = ScanModel()", "@State var model: ScanModel")
            source = source.replace("    var body: some View {", "    var body: some View {\n        let _ = UIHandoffMetrics.rootBodies += 1", 1)
            source = re.sub(r"        \.task \{\n            model.agentEnv.*?\n        \}", "", source, count=1, flags=re.S)
            source = re.sub(r"        \.onAppear \{\n            // Never start.*?\n        \}", "", source, count=1, flags=re.S)
        if path.name == "Model.swift":
            source = source.replace('let doneAt = Date()', 'let doneAt = Date(); UIHandoffMetrics.engineDoneAt = doneAt', 1)
            source = source.replace('    static func read(_ path: String) -> VolumeSpace {',
                '    static func read(_ path: String) -> VolumeSpace {\n'
                '        if let delay = ProcessInfo.processInfo.environment["BZ_VOLUME_DELAY"].flatMap(Double.init) { Thread.sleep(forTimeInterval: delay) }')
            source = source.replace('            if let vals = try? URL(fileURLWithPath: scanRoot).resourceValues(',
                '            let volumeStarted = Date()\n            if let vals = try? URL(fileURLWithPath: scanRoot).resourceValues(')
            if 'let volumeStarted = Date()' in source:
                source = source.replace('            // Coverage honesty:',
                    '            NSLog("BZ capacity query: %.3f ms", -volumeStarted.timeIntervalSinceNow * 1000)\n            // Coverage honesty:')
            source = re.sub(r'( +)activity = nil\n', lambda m: m[0] + m[1] + 'NSLog("BZ completion reached: %.3f ms", -doneAt.timeIntervalSinceNow * 1000)\n', source)
        dest = work / path.name
        dest.write_text(source)
        files.append(str(dest))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", *files, str(ROOT / "benchmarks/UIHandoff.swift"),
                    "-import-objc-header", str(ROOT / "app/bz.h"),
                    "-O", "-parse-as-library", "-swift-version", "6", "-default-isolation", "MainActor",
                    *( ["-whole-module-optimization"] if args.wmo else [] ),
                    "-target", "arm64-apple-macos14.0", "-L", str(ROOT / "target/release"), "-lblitztree",
                    "-framework", "AppKit", "-framework", "SwiftUI", "-o", str(args.output.resolve())], check=True)
finally:
    shutil.rmtree(work)
