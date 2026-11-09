#!/usr/bin/env python3
"""Lists the core-module imports of a compiled Kotlin/Wasm agent that the `kotlin-agent` world does
not provide (missing interface or missing function).  Existence check only: a function whose
*signature* changed still shows as present -- `wasm-tools component new` validates signatures.

Async intrinsics are checked too (exports are modules named `[export]<interface>`): `$root` waitable/subtask builtins are accepted, `[async-lower]fn` function imports must
name an existing function, and the mangled stream/future intrinsics (`[async-lower][stream-read-0]fn`, `[stream-new-0]fn`, ...) must name a function of the interface whose
signature has that many streams/futures.

Usage: scripts/check-imports.py <core.wasm>   (default: example/build/compileSync/.../counter-agent.wasm)
       scripts/check-imports.py --sources     check every @WasmImport in sdk/src (not just those a given agent reaches)
"""
import collections
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
default = HERE / "example/build/compileSync/wasmWasi/main/productionExecutable/kotlin/counter-agent.wasm"
sources = len(sys.argv) > 1 and sys.argv[1] == "--sources"
core = Path(sys.argv[1]) if len(sys.argv) > 1 and not sources else default

wit = json.loads(subprocess.check_output(["wasm-tools", "component", "wit", str(HERE / "wit-native"), "--json"]))
world = next(w for w in wit["worlds"] if w["name"] == "kotlin-agent")
avail = {}
resources = {}
iface_ids = {}  # module key -> interface id, for imported interfaces and (with an `[export]` prefix) exported ones
for section, prefix in (("imports", ""), ("exports", "[export]")):
    for v in world[section].values():
        if "interface" not in v:
            continue
        i = wit["interfaces"][v["interface"]["id"]]
        pkg = wit["packages"][i["package"]]["name"]
        base, _, ver = pkg.partition("@")
        key = prefix + f"{base}/{i['name']}" + (f"@{ver}" if ver else "")
        avail[key] = set(i["functions"])
        iface_ids[key] = v["interface"]["id"]
        resources[key] = {n for n, tid in i["types"].items() if wit["types"][tid]["kind"] == "resource"}

ROOT_BUILTINS = {"[waitable-set-new]", "[waitable-set-wait]", "[waitable-set-poll]", "[waitable-join]",
                 "[waitable-set-drop]", "[subtask-drop]", "[subtask-cancel]"}
STREAM_INTRINSIC = re.compile(
    r"^(?:\[async-lower\])?\[(stream|future)-(?:new|read|write|cancel-read|cancel-write|drop-readable|drop-writable)-(\d+)\](.+)$")


def stream_future_types(func):
    """Distinct stream/future type ids reachable from a function signature, in encounter order."""
    found, seen = [], set()

    def walk(t):
        if t is None or isinstance(t, str) or t in seen:
            return
        seen.add(t)
        kind = wit["types"][t]["kind"]
        if not isinstance(kind, dict):
            return
        (kk, v), = kind.items()
        if kk in ("stream", "future"):
            found.append(t)
        if kk == "record":
            for f in v["fields"]:
                walk(f["type"])
        elif kk == "variant":
            for c in v["cases"]:
                walk(c.get("type"))
        elif kk == "tuple":
            for x in v["types"]:
                walk(x)
        elif kk == "result":
            walk(v.get("ok"))
            walk(v.get("err"))
        elif kk in ("option", "list", "type", "stream", "future"):
            walk(v)

    for prm in func["params"]:
        walk(prm["type"])
    walk(func.get("result"))
    return found


def kotlin_string(expr, consts):
    """Resolves a Kotlin string literal (with `$NAME` templates) or a const identifier; None if not constant."""
    expr = expr.strip()
    if re.fullmatch(r"[A-Za-z_]\w*", expr):
        return consts.get(expr)
    m = re.fullmatch(r'"((?:[^"\\]|\\.)*)"', expr)
    if not m:
        return None
    text = m.group(1).replace("\\$", "$").replace("\\\\", "\\")
    for name, val in sorted(consts.items(), key=lambda kv: -len(kv[0])):  # longest first: `$A_B` must not match the const `A`
        text = text.replace("${" + name + "}", val).replace("$" + name, val)
    return text


if sources:
    printed = ""
    pairs = []
    for f in sorted((HERE / "sdk/src").rglob("*.kt")):
        src = f.read_text()
        consts = dict(re.findall(r'const val (\w+)\s*=\s*"([^"]*)"', src))
        for a, b in re.findall(r"@kotlin\.wasm\.WasmImport\(\s*([^,()]+?)\s*,\s*([^()]+?)\s*\)\s*\n", src) + \
                re.findall(r"@WasmImport\(\s*([^,()]+?)\s*,\s*([^()]+?)\s*\)", src):
            mod, name = kotlin_string(a, consts), kotlin_string(b, consts)
            if mod is None or name is None:
                print(f"warning: unresolved WasmImport({a}, {b}) in {f.name}", file=sys.stderr)
                continue
            pairs.append((mod, name))
else:
    printed = subprocess.check_output(["wasm-tools", "print", str(core)], text=True)
    pairs = re.findall(r'\(import "([^"]+)" "([^"]+)"', printed)
missing = collections.defaultdict(list)
present = 0
for mod, name in pairs:
    if mod.startswith("wasi_snapshot"):
        continue
    if mod == "$root":
        if name in ROOT_BUILTINS:
            present += 1
        else:
            missing[mod].append(f"(unknown $root builtin) {name}")
        continue
    sm = STREAM_INTRINSIC.match(name)
    if sm and mod in avail:
        kind, idx, func = sm.group(1), int(sm.group(2)), sm.group(3)
        if func not in avail[mod]:
            missing[mod].append(f"(stream intrinsic names no such function) {name}")
        elif idx >= len(stream_future_types(wit["interfaces"][iface_ids[mod]]["functions"][func])):
            missing[mod].append(f"(stream index out of range) {name}")
        else:
            present += 1
        continue
    if mod.startswith("[export]") and name.startswith("[task-return]"):
        # task.return of an async-lifted export: the function must be an (async) export of the interface
        func = name[len("[task-return]"):]
        if mod in avail and func in avail[mod]:
            present += 1
        else:
            missing[mod].append(f"(task-return names no such exported function) {name}")
        continue
    if name.startswith("[async-lower]"):
        # an async function lowered to the async ABI: the underlying function must exist
        name = name[len("[async-lower]"):]
    if mod not in avail:
        missing[mod].append(f"(interface not imported by world) {name}")
    elif name.startswith("[resource-drop]"):
        # implicit for every resource: ok iff some function of the interface mentions the resource
        res = name[len("[resource-drop]"):]
        if res in resources[mod] or any(f.split("]", 1)[-1].split(".")[0] == res for f in avail[mod]):
            present += 1
        else:
            missing[mod].append(f"(no such resource) {res}")
    elif name not in avail[mod]:
        missing[mod].append(f"(no such function) {name}")
    else:
        present += 1
print(f"{present} core imports resolve against the world")
for mod, items in sorted(missing.items()):
    print(mod)
    for i in items:
        print("   ", i)
sys.exit(1 if missing else 0)
