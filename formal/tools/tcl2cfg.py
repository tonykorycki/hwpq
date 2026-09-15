#!/usr/bin/env python3
"""Convert a per-module proof script into a declarative .cfg.

The .cfg carries only what a proof needs: sources, top, parameters, clock,
reset and the verdict expectations. Everything the old scripts repeated -- the
mode plumbing, the define marshalling, the source/dispatch tail -- is generic
and now lives in formal/drive.tcl.

Comments are carried across in place. The converter refuses to guess: any line
it does not recognise is a hard error, because silently dropping a line here
would silently change what gets proven.

usage: tcl2cfg.py <in.tcl> [...]   -- writes formal/config/<name>.cfg
       tcl2cfg.py --check <in.tcl> -- print, compare, do not write
"""
import os, re, sys

DROP_LINE = [
    r"^clear\s+-all\s*$",
    r"^set\s+HWPQ_(SELFTEST|UNGATED)\s+0\s*$",
    r"^if\s*\{\[info exists ::env\(HWPQ_(SELFTEST|UNGATED)\)\)?\]\}.*$",
    r"^set\s+hwpq_(defs|dflags)\s*\{\}\s*$",
    r"^foreach\s+d\s+\$hwpq_defs\b.*$",
    r"^analyze\b.*$",
    r"^source\s+.*common\.tcl\s*$",
    r"^hwpq_prove_and_exit\s*$",
]

class Unrecognised(Exception):
    pass

def braces(s):
    return s.count("{") - s.count("}")

def convert(path):
    src = open(path, encoding="utf-8").read().splitlines()
    out, i, n = [], 0, len(src)
    seen = set()

    while i < n:
        raw = src[i]
        line = raw.strip()

        if not line or line.startswith("#"):
            out.append(raw.rstrip())
            i += 1
            continue

        if any(re.match(p, line) for p in DROP_LINE):
            i += 1
            continue

        # set src { ...files... }
        m = re.match(r"^set\s+src\s*\{\s*$", line)
        if m:
            i += 1
            while i < n and src[i].strip() != "}":
                f = src[i].strip()
                if f and not f.startswith("#"):
                    out.append(f"source              {f}")
                elif f.startswith("#"):
                    out.append(src[i].rstrip())
                i += 1
            i += 1
            seen.add("source")
            continue

        # elaborate -top X [-parameter N V]...  (backslash continuations)
        if re.match(r"^elaborate\b", line):
            buf = line
            while buf.rstrip().endswith("\\") and i + 1 < n:
                i += 1
                buf = buf.rstrip()[:-1] + " " + src[i].strip()
            mt = re.search(r"-top\s+(\S+)", buf)
            if not mt:
                raise Unrecognised(f"elaborate without -top: {buf}")
            out.append(f"top                 {mt.group(1)}")
            for pn, pv in re.findall(r"-parameter\s+(\S+)\s+(\S+)", buf):
                out.append(f"param               {pn} {pv}")
            leftover = re.sub(r"-top\s+\S+|-parameter\s+\S+\s+\S+|^elaborate", "", buf).strip()
            if leftover:
                raise Unrecognised(f"unhandled elaborate options: {leftover!r}")
            seen.add("top")
            i += 1
            continue

        for kw, out_kw in (("clock", "clock"), ("reset", "reset")):
            m = re.match(rf"^{kw}\s+(.+?)\s*$", line)
            if m and kw not in seen:
                out.append(f"{out_kw:<19} {m.group(1)}")
                seen.add(kw)
                break
        else:
            m = re.match(r"^set\s+HWPQ_MODULE\s+(\S+)\s*$", line)
            if m:
                out.append(f"module              {m.group(1)}")
                seen.add("module")
                i += 1
                continue

            m = re.match(r"^set\s+HWPQ_ALLOW_BOUNDED\s+(\S+)\s*$", line)
            if m:
                out.append(f"allow_bounded       {m.group(1)}")
                i += 1
                continue

            m = re.match(r"^set\s+HWPQ_EXPECT_CEX\s*\{(.*)\}\s*$", line)
            if m:
                out.append(f"expect_cex          {m.group(1).strip()}".rstrip())
                i += 1
                continue

            # if {$HWPQ_SELFTEST|$HWPQ_UNGATED} { ... } [else { ... }]
            m = re.match(r"^if\s*\{\$HWPQ_(SELFTEST|UNGATED)\}\s*\{\s*$", line)
            if m:
                mode = m.group(1)
                block, depth, i = [], 1, i + 1
                while i < n and depth > 0:
                    depth += braces(src[i])
                    if depth > 0:
                        block.append(src[i].strip())
                    i += 1
                els = []
                if i < n and src[i].strip().startswith("else"):
                    depth, i = 1, i + 1
                    while i < n and depth > 0:
                        depth += braces(src[i])
                        if depth > 0:
                            els.append(src[i].strip())
                        i += 1
                body = " ".join(block)
                mc = re.search(r"set\s+HWPQ_EXPECT_CEX\s*\{(.*?)\}", body)
                if mc:
                    key = "expect_cex_ungated" if mode == "UNGATED" else "expect_cex_selftest"
                    out.append(f"{key:<19} {mc.group(1).strip()}".rstrip())
                    mo = re.search(r"set\s+HWPQ_EXPECT_CEX\s*\{(.*?)\}", " ".join(els))
                    if mo:
                        out.append(f"{'expect_cex':<19} {mo.group(1).strip()}".rstrip())
                elif all(re.match(r"^(puts\b|lappend\s+hwpq_defs\b)", b) for b in block if b):
                    pass          # mode banner / define marshalling: generic now
                else:
                    raise Unrecognised(f"{path}: unhandled if-block: {body[:90]}")
                continue

            raise Unrecognised(f"{path}:{i+1}: unrecognised line: {line!r}")
        i += 1

    for need in ("module", "top", "source", "clock", "reset"):
        if need not in seen:
            raise Unrecognised(f"{path}: no '{need}' found")

    while out and not out[-1].strip():
        out.pop()
    return "\n".join(out) + "\n"

if __name__ == "__main__":
    args = sys.argv[1:]
    check = "--check" in args
    args = [a for a in args if a != "--check"]
    if not args:
        sys.exit(__doc__)
    rc = 0
    for path in args:
        try:
            text = convert(path)
        except Unrecognised as e:
            print(f"ERROR: {e}", file=sys.stderr)
            rc = 2
            continue
        # Keep the baseline/ split: run.sh --all globs formal/config/*.cfg, and
        # the baseline configs are CONTROL runs that are meant to fail. Flatten
        # them into the same directory and --all would start reporting them.
        name = os.path.basename(path)[:-4] + ".cfg"
        sub = os.path.basename(os.path.dirname(os.path.abspath(path)))
        dest = os.path.join("formal/config", "baseline" if sub == "baseline" else "", name)
        if check:
            cur = open(dest, encoding="utf-8").read() if os.path.exists(dest) else None
            print(f"{'SAME' if cur == text else 'DIFF'}  {dest}")
            if cur != text:
                rc = 1
        else:
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            open(dest, "w", encoding="utf-8").write(text)
            print(f"wrote {dest}")
    sys.exit(rc)
