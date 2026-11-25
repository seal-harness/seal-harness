#!/usr/bin/env python3
"""Mechanical consistency check for a design/plan document.

The multiple-execution-machines design has miscounted itself in four
consecutive revisions (unit counts, resolution rows, renderings, route
counts, `SessionMeta` sites). Every one of those was caught by a reviewer
rather than by the author. This script is the check the document claimed
to have; it exists so the claim is true.

Usage:
    python3 scripts/check-spec-counts.py docs/superpowers/specs/<doc>.md

Exit code 0 = consistent, 1 = at least one inconsistency (each printed).
"""

from __future__ import annotations

import re
import sys
import os

NUMBER_WORDS = {
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
    "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
    "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
    "sixteen": 16,
}
WORD_FOR = {v: k for k, v in NUMBER_WORDS.items()}


class Report:
    def __init__(self) -> None:
        self.problems: list[str] = []

    def bad(self, msg: str) -> None:
        self.problems.append(msg)

    def ok(self, msg: str) -> None:
        print(f"  ok   {msg}")

    def finish(self) -> int:
        print()
        for p in self.problems:
            print(f"  FAIL {p}")
        print()
        if self.problems:
            print(f"{len(self.problems)} inconsistency(ies)")
            return 1
        print("all checks passed")
        return 0


def check_unit_counts(text: str, r: Report) -> None:
    headings = re.findall(r"^### (WU-[0-9]+[a-z]?)\b", text, re.M)
    declared = re.findall(r"\*\*([A-Za-z]+) units\.\*\*", text)
    if not headings:
        r.bad("no '### WU-N' headings found")
        return
    if not declared:
        r.bad("no '**<Word> units.**' declaration found")
        return
    word = declared[0].lower()
    if word not in NUMBER_WORDS:
        r.bad(f"unit-count declaration {word!r} is not a number word")
        return
    want = NUMBER_WORDS[word]
    if want != len(headings):
        r.bad(
            f"declared {want} units ({word}) but found {len(headings)} "
            f"'### WU-' headings: {headings}"
        )
    else:
        r.ok(f"{len(headings)} unit headings match the declared '{word}'")


def check_test_rows(text: str, r: Report) -> None:
    headings = re.findall(r"^### (WU-[0-9]+[a-z]?)\b", text, re.M)
    if not headings:
        return
    # Test-table rows look like: | WU-7a | ... |  or  | WU-7a (opcode ban) | ... |
    rows = re.findall(r"^\|\s*(WU-[0-9]+[a-z]?)\b", text, re.M)
    missing = [h for h in headings if h not in rows]
    unknown = sorted({x for x in rows if x not in headings})
    if missing:
        r.bad(f"units with no §8 test row: {missing}")
    if unknown:
        r.bad(f"§8 test rows naming a non-existent unit: {unknown}")
    if not missing and not unknown:
        r.ok(
            f"every unit has a test row ({len(rows)} rows for "
            f"{len(headings)} units; extras are sub-rows)"
        )


def check_numbered_rows(text: str, r: Report) -> None:
    """'N rows 0/1/1a/...' — the stated count must equal the enumerated count."""
    for m in re.finditer(
        r"\*\*(one|two|three|four|five|six|seven|eight|nine|ten)\s+rows?\*\*",
        text,
        re.I,
    ):
        stated = NUMBER_WORDS[m.group(1).lower()]
        # the enumeration follows on the same line, e.g. "0/1/1a/1b/2/3/4"
        line_end = text.find("\n", m.end())
        tail = text[m.end(): line_end if line_end != -1 else m.end() + 120]
        enum = re.search(r"([0-9]+[a-z]?(?:/[0-9]+[a-z]?)+)", tail)
        if not enum:
            continue
        actual = len(enum.group(1).split("/"))
        if actual != stated:
            r.bad(
                f"'**{m.group(1)} rows**' but the enumeration "
                f"'{enum.group(1)}' has {actual} entries"
            )
    # Also catch a bare table whose row labels are numbered.
    labels = re.findall(r"^\|\s*([0-9]+[a-z]?)\s*\|", text, re.M)
    if labels:
        stated = re.findall(
            r"\*\*(one|two|three|four|five|six|seven|eight|nine|ten)\s+rows?\*\*",
            text,
            re.I,
        )
        if stated:
            want = NUMBER_WORDS[stated[0].lower()]
            if want != len(labels):
                r.bad(
                    f"resolution table has {len(labels)} labelled rows "
                    f"({','.join(labels)}) but the text says '{stated[0]} rows'"
                )
            else:
                r.ok(f"resolution table rows ({len(labels)}) match '{stated[0]} rows'")

    # Stated counts that are NOT bolded and NOT adjacent to an enumeration.
    # This is the gap that let a known-open blocker pass a green run: line 52
    # said "six resolution rows, not five" with no enumeration nearby.
    if labels:
        actual = len(labels)
        for m in re.finditer(
            r"\b(one|two|three|four|five|six|seven|eight|nine|ten)\s+"
            r"(?:resolution\s+)?rows?\b(?!\s*0/)",
            text,
            re.I,
        ):
            stated = NUMBER_WORDS[m.group(1).lower()]
            # skip "N rows" that is really "N rows of the table above" prose
            # only if it matches the real count
            if stated != actual:
                near = text[max(0, m.start() - 90): m.start()].replace("\n", " ")
                r.bad(
                    f"'{m.group(0)}' disagrees with the {actual} labelled "
                    f"resolution rows (context: ...{near[-70:]})"
                )


def check_word_counts(text: str, r: Report, phrase: str, pattern: str) -> None:
    """Every 'N <phrase>' claim must agree with the actual count of `pattern`."""
    claims = re.findall(
        r"\b(one|two|three|four|five|six|seven|eight|nine|ten)\s+" + phrase + r"\b",
        text,
        re.I,
    )
    if not claims:
        return
    actual = len(re.findall(pattern, text))
    for c in set(x.lower() for x in claims):
        if NUMBER_WORDS[c] != actual:
            r.bad(
                f"text says '{c} {phrase}' but {actual} were found"
            )
            return
    r.ok(f"'{claims[0]} {phrase}' matches the {actual} found")


def check_renderings(text: str, r: Report) -> None:
    ctors = re.findall(r"^\s*\|\s*`?(Target[A-Za-z]+)\b", text, re.M)
    ctors = sorted(set(ctors))
    claims = set(x.lower() for x in re.findall(
        r"\b(one|two|three|four|five|six)\s+renderings?\b", text, re.I))
    if not ctors or not claims:
        return
    for c in claims:
        if NUMBER_WORDS[c] != len(ctors):
            r.bad(
                f"text says '{c} renderings' but {len(ctors)} TargetError "
                f"constructors are documented: {ctors}"
            )
            return
    r.ok(f"'{list(claims)[0]} renderings' matches {len(ctors)} constructors")


def check_single_signature(text: str, r: Report, fn: str) -> None:
    sigs = set()
    for m in re.finditer(rf"^{re.escape(fn)}\s*::\s*(.+)$", text, re.M):
        sigs.add(" ".join(m.group(1).split()))
    if len(sigs) > 1:
        r.bad(f"{fn} has {len(sigs)} different signatures: {sorted(sigs)}")
    elif len(sigs) == 1:
        r.ok(f"{fn} has exactly one signature")


def check_constructor_shape(text: str, r: Report, name: str) -> None:
    """A constructor declared with a payload must not be called nullary, and v.v."""
    declared = set(re.findall(rf"\|\s*{re.escape(name)}(?:\s+([A-Z][A-Za-z]*))?", text))
    has_payload = any(d for d in declared if d)
    nullary_claim = re.search(
        rf"\*\*`{re.escape(name)}`\s+is\s+\*\*nullary\*\*", text
    ) or re.search(rf"{re.escape(name)}\s+is\s+\*\*nullary\*\*", text)
    if nullary_claim and has_payload:
        r.bad(f"{name} is declared with a payload but the prose calls it nullary")
    elif nullary_claim:
        r.ok(f"{name}: nullary in both the declaration and the prose")


def check_section_refs(text: str, r: Report) -> None:
    headings = set(re.findall(r"^##+\s*§?(\d+)[.\s]", text, re.M))
    headings |= set(re.findall(r"^##\s+(\d+)\.", text, re.M))
    refs = set(re.findall(r"§(\d+)(?![0-9])", text))
    dangling = sorted(refs - headings, key=lambda x: int(x))
    if dangling:
        r.bad(f"§ references to sections that do not exist: {dangling}")
    else:
        r.ok(f"all {len(refs)} § references resolve")


def check_stated_scripts_exist(text: str, r: Report, repo_root: str) -> None:
    import os
    cited = set(re.findall(r"scripts/([A-Za-z0-9_.-]+\.(?:py|sh|mjs))", text))
    for name in sorted(cited):
        if not os.path.exists(os.path.join(repo_root, "scripts", name)):
            r.bad(f"document cites scripts/{name}, which does not exist")
    if cited:
        r.ok(f"all {len(cited)} cited script(s) exist")


def check_double_owned(text: str, r: Report) -> None:
    """A phrase of >=60 chars appearing under two different WU headings is
    duplicated scope."""
    sections = re.split(r"^### (WU-[0-9]+[a-z]?)\b", text, flags=re.M)
    seen: dict[str, str] = {}
    for i in range(1, len(sections), 2):
        unit, body = sections[i], sections[i + 1]
        for sent in re.split(r"(?<=[.!?])\s+", body):
            clean = " ".join(sent.split())
            if len(clean) < 60:
                continue
            if clean in seen and seen[clean] != unit:
                r.bad(
                    f"identical sentence in two units ({seen[clean]} and {unit}): "
                    f"{clean[:70]}..."
                )
                return
            seen[clean] = unit
    r.ok("no identical long sentence is claimed by two units")


def check_cite_set_agreement(text: str, r: Report) -> None:
    """The same file cited twice with equal-size but different line sets."""
    from collections import defaultdict
    cites: dict[str, set[frozenset[str]]] = defaultdict(set)
    for m in re.finditer(
        r"([A-Za-z0-9_/]+\.(?:hs|ts|tsx))((?::\d+)(?:,\d+)*(?:\s+and\s+:?\d+)*)", text
    ):
        fname = m.group(1).rsplit("/", 1)[-1]
        nums = frozenset(re.findall(r"\d+", m.group(2)))
        if len(nums) >= 2:
            cites[fname].add(nums)
    bad = [f for f, sets in cites.items() if len(sets) > 1]
    if bad:
        for f in bad:
            sets = sorted((sorted(s) for s in cites[f]))
            r.bad(f"{f} is cited with different line sets: {sets}")
    else:
        r.ok(f"no file is cited with conflicting line sets ({len(cites)} files cited by line)")


def check_signature_types_owned(text: str, r: Report) -> None:
    """A type appearing in a §5 signature should be mentioned by some work unit."""
    sig_types = set(re.findall(r"::[^\n]*?->\s*([A-Z][A-Za-z]*)", text))
    sig_types |= set(re.findall(r"::\s*([A-Z][A-Za-z]*)\s*->", text))
    builtin = {
        "Maybe", "Either", "IO", "Text", "Int", "Bool", "Map", "Set", "Seq",
        "NonEmpty", "Value", "App", "IO", "FilePath", "String",
    }
    unit_section = text[text.find("## 7. Work units"):] if "## 7. Work units" in text else ""
    unowned = sorted(
        t for t in sig_types - builtin
        if t not in unit_section
    )
    if unowned:
        r.bad(f"types used in a signature but named by no work unit: {unowned}")
    else:
        r.ok(f"every signature type is named by a work unit ({len(sig_types - builtin)} checked)")


def check_file_line_double_ownership(text: str, r: Report) -> None:
    """An imperative file:line under two different units."""
    from collections import defaultdict
    sections = re.split(r"^### (WU-[0-9]+[a-z]?)\b", text, flags=re.M)
    owners: dict[str, set[str]] = defaultdict(set)
    for i in range(1, len(sections), 2):
        unit, body = sections[i], sections[i + 1]
        for m in re.finditer(r"([A-Za-z0-9_]+\.(?:hs|ts|tsx)):(\d+)", body):
            owners[f"{m.group(1)}:{m.group(2)}"].add(unit)
    shared = {k: v for k, v in owners.items() if len(v) > 1}
    if shared:
        for k, v in sorted(shared.items()):
            r.bad(f"{k} is owned by more than one unit: {sorted(v)}")
    else:
        r.ok(f"no file:line is owned by two units ({len(owners)} citations checked)")


def check_digit_counts(text: str, r: Report, repo_root: str = "") -> None:
    """Digit-form counts the word-form checks cannot see.

    Round 8 found that `check_word_counts` was defined and never called, so every
    word-form check ran zero times, and that no check looked at digit-form counts
    at all — which is how "75 sites" survived four revisions when the script said
    77. This closes both: it is called from main, and it handles digits.
    """
    checks_passed = 0

    # (a) the SessionMeta total, if the doc states one, must match the script.
    stated = re.search(r"\*\*(\d+)\s+sites?\s+across\s+(\d+)\s+files", text)
    if stated and repo_root:
        import subprocess
        script = os.path.join(repo_root, "scripts", "count-sessionmeta-sites.py")
        if os.path.exists(script):
            try:
                out = subprocess.run(
                    [sys.executable, script], capture_output=True, text=True,
                    cwd=repo_root, timeout=60,
                ).stdout
                m = re.search(r"construction sites: (\d+) in (\d+) files", out)
                if m:
                    if (int(m.group(1)), int(m.group(2))) != (
                        int(stated.group(1)), int(stated.group(2))
                    ):
                        r.bad(
                            f"doc says {stated.group(1)} sites across "
                            f"{stated.group(2)} files; the script says "
                            f"{m.group(1)} in {m.group(2)}"
                        )
                    else:
                        checks_passed += 1
            except (subprocess.SubprocessError, OSError):
                pass

    # (b) "N record / M positional" must sum to the stated total.
    shapes = re.search(r"(\d+)\s+record\s*/\s*(\d+)\s+positional", text)
    total = re.search(r"\*\*(\d+)\s+sites?", text)
    if shapes and total:
        if int(shapes.group(1)) + int(shapes.group(2)) != int(total.group(1)):
            r.bad(
                f"record({shapes.group(1)}) + positional({shapes.group(2)}) "
                f"!= the stated total of {total.group(1)}"
            )
        else:
            checks_passed += 1

    if checks_passed:
        r.ok(f"{checks_passed} digit-form count(s) cross-checked against a script")
    elif stated or shapes:
        r.ok("digit-form counts present but not cross-checkable")


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    import os
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    with open(path, encoding="utf-8") as fh:
        text = fh.read()

    r = Report()
    print(f"checking {path}\n")
    check_unit_counts(text, r)
    check_test_rows(text, r)
    check_numbered_rows(text, r)
    check_renderings(text, r)
    check_single_signature(text, r, "renderTargetError")
    check_constructor_shape(text, r, "TargetNoMachine")
    check_section_refs(text, r)
    check_stated_scripts_exist(text, r, repo_root)
    check_double_owned(text, r)
    check_cite_set_agreement(text, r)
    check_signature_types_owned(text, r)
    check_file_line_double_ownership(text, r)
    check_digit_counts(text, r, repo_root)
    return r.finish()


if __name__ == "__main__":
    sys.exit(main())
