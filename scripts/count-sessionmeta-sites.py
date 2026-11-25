#!/usr/bin/env python3
"""Count `SessionMeta` *construction* sites in the Haskell sources.

Why a script and not a grep: the predicate has three shapes and a grep cannot
separate them from type-level uses.

  shape A (record)      `SessionMeta` followed by `{`, possibly with the brace on
                        the next line
  shape B (positional)  `SessionMeta` followed on the same line by >= 3 argument
                        tokens (the sites in this tree pass 13 arguments)

Both shapes are matched only when the occurrence is not one of:

  * a type position      `:: SessionMeta`, `-> SessionMeta`
  * a container element  `[SessionMeta]`, `(Maybe SessionMeta, Text)`
  * a declaration        `data SessionMeta`, `newtype ...`
  * an import            `Seal.Session.Meta (SessionMeta (..))`
  * a doc-comment        any line whose first non-space characters are `--`

Usage:
    python3 scripts/count-sessionmeta-sites.py           # summary + per-file counts
    python3 scripts/count-sessionmeta-sites.py --files   # bare list of files

Exits 0 always; this is a measurement tool, not a gate. The gate is in the plan's
DoD: the total must be 0 outside `src/Seal/Session/Meta.hs`.
"""

import os
import re
import sys

ROOTS = ("src", "test", "src-chat-channels", "src-gateway-types")
EXEMPT = os.path.join("src", "Seal", "Session", "Meta.hs")

# A type-position prefix on the same line, immediately before the word.
TYPE_PREFIX = re.compile(r"(::|->|\bdata\b|\bimport\b|\bnewtype\b|\btype\b)\s*$")
# A container/application prefix that makes the occurrence a type, not a value.
CONTAINER_PREFIX = re.compile(r"(\bIO|\bMaybe|\[|\(|,)\s*$")


def is_type_use(before: str, after: str) -> bool:
    """True when this occurrence is a type, not the constructor applied."""
    if re.match(r"\s*\(\.\.\)", after):          # SessionMeta (..) in an import
        return True
    if re.match(r"\s*->", after):                # SessionMeta -> IO ()
        return True
    if TYPE_PREFIX.search(before):
        return True
    if "::" in before:                          # anywhere in the signature
        return True
    if "Seal.Session.Meta" in before:           # the import line itself
        return True
    # A trailing type context: `IO (Maybe SessionMeta)` / `[SessionMeta]` /
    # `(SessionMeta, Text)` at end of line. A CONSTRUCTOR there is followed by
    # an argument, so the discriminator is "nothing but a closer follows".
    if CONTAINER_PREFIX.search(before) and re.match(r"\s*[,)\]]*\s*$", after):
        return True
    return False


def constructors_in_line(line: str) -> int:
    if line.lstrip().startswith("--"):
        return 0
    n = 0
    for m in re.finditer(r"\bSessionMeta\b", line):
        before, after = line[: m.start()], line[m.end() :]
        if is_type_use(before, after):
            # A record construction whose `{` sits on the NEXT line cannot be
            # distinguished on this line alone; the caller handles it.
            continue
        if re.match(r"\s*\{", after):
            n += 1
            continue
        tokens = [t for t in re.split(r"\s+", after.strip()) if t]
        if len(tokens) >= 3 and re.match(r"\s+\S", after):
            n += 1
    return n


def record_brace_on_next_line(line: str, following: str) -> bool:
    """`  SessionMeta` here, `  { field = …` next line."""
    if not re.search(r"\bSessionMeta\s*$", line):
        return False
    if re.search(r"(::|->|\[|\bIO|\bMaybe)\s*$", line):
        return False
    return following.lstrip().startswith("{")


def count_file_shapes(path: str) -> tuple[int, int]:
    """(record-form, positional) construction sites in one file.

    The split matters: a new field on `SessionMeta` breaks record literals via
    `-Wmissing-fields`, but breaks *positional* applications via **arity**, which
    `-Wmissing-fields` does not report. They need different fixes, so a bare
    total is not enough to scope the work.
    """
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().split("\n")
    rec = pos = 0
    for i, line in enumerate(lines):
        if line.lstrip().startswith("--"):
            continue
        for m in re.finditer(r"\bSessionMeta\b", line):
            before, after = line[: m.start()], line[m.end() :]
            if is_type_use(before, after):
                continue
            if re.match(r"\s*\{", after):
                rec += 1
                continue
            tokens = [t for t in re.split(r"\s+", after.strip()) if t]
            if len(tokens) >= 3 and re.match(r"\s+\S", after):
                pos += 1
        nxt = lines[i + 1] if i + 1 < len(lines) else ""
        if record_brace_on_next_line(line, nxt):
            rec += 1
    return rec, pos


def count_file(path: str) -> int:
    rec, pos = count_file_shapes(path)
    return rec + pos


def main() -> int:
    files_only = "--files" in sys.argv
    per_file = {}
    shapes = {}
    for root in ROOTS:
        for dirpath, _dirs, names in os.walk(root):
            for name in names:
                if not name.endswith(".hs"):
                    continue
                path = os.path.join(dirpath, name)
                rec, pos = count_file_shapes(path)
                n = rec + pos
                if n:
                    per_file[path] = n
                    shapes[path] = (rec, pos)

    counted = {p: n for p, n in per_file.items() if p != EXEMPT}
    total = sum(counted.values())
    rec_total = sum(shapes[p][0] for p in counted)
    pos_total = sum(shapes[p][1] for p in counted)

    if files_only:
        for path in sorted(counted):
            print(path)
        return 0

    print(f"construction sites: {total} in {len(counted)} files")
    print(f"  record form  : {rec_total}  (break via -Wmissing-fields)")
    print(f"  positional   : {pos_total}  (break via ARITY, which -Wmissing-fields")
    print(f"                 does not report — these need rewriting, not a base record)")
    print(f"(excluded: {EXEMPT} — it holds `defaultSessionMeta` itself)")
    print()
    for path, n in sorted(counted.items(), key=lambda kv: (-kv[1], kv[0])):
        rec, pos = shapes[path]
        print(f"{n:4d}  ({rec:2d} rec / {pos:2d} pos)  {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
