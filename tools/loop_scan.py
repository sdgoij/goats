"""Report blocks that hold two or more sibling loop regions.

The engine compiles a body with one loop region and interprets one with two
(PERF.md, jitprobe `s two loops`: 9.2 vs 538.4 ns/iter). A loop nested inside
another is still one region; two loops whose headers sit in the *same block* --
including a block that is itself inside a loop, as `collideLeaf`'s pass body is
-- are two.

This is a scanner, not a parser: it skips comments and strings, tracks brace and
paren depth, gives every `{` block an id, and counts the loop headers per block.
"""
import re
from collections import defaultdict
from pathlib import Path

FUNC_RE = re.compile(r"\bfunction\s+([A-Za-z_$][\w$]*)\s*\(")
IDENT_RE = re.compile(r"[A-Za-z_$][\w$]*")


def scan(path):
    text = path.read_text(encoding="utf-8", errors="replace")
    n = len(text)
    i = 0
    line = 1
    depth = 0
    paren = 0
    block_id = {0: 0}
    next_block = 1
    block_info = {}          # id -> (function name, line)
    func_stack = []
    pending_func = None
    loop_header_depth = None
    await_body = False
    loops_by_block = defaultdict(list)   # block id -> [(line, word)]

    def current_func():
        return func_stack[-1][2] if func_stack else "<top>"

    def note_loop(word):
        bid = block_id[depth]
        loops_by_block[bid].append((line, word))

    while i < n:
        ch = text[i]
        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            line += text.count("\n", i, n if j < 0 else j)
            i = n if j < 0 else j + 2
            continue
        if ch in "\"'`":
            quote = ch
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == quote:
                    i += 1
                    break
                if text[i] == "\n":
                    line += 1
                i += 1
            continue
        if ch == "\n":
            line += 1
            i += 1
            continue
        if ch.isalpha() or ch in "_$":
            m = IDENT_RE.match(text, i)
            word = m.group(0)
            if word == "function":
                fm = FUNC_RE.match(text, i)
                if fm:
                    pending_func = fm.group(1)
                    i = fm.end()
                    continue
            if word in ("for", "while"):
                note_loop(word)
                loop_header_depth = paren
                await_body = False
                i = m.end()
                continue
            if word == "do":
                note_loop(word)
                await_body = True
                i = m.end()
                continue
            i = m.end()
            continue
        if ch == "(":
            paren += 1
            i += 1
            continue
        if ch == ")":
            paren -= 1
            if loop_header_depth is not None and paren == loop_header_depth:
                loop_header_depth = None
                await_body = True
            i += 1
            continue
        if ch == "{":
            depth += 1
            block_id[depth] = next_block
            if pending_func is not None:
                block_info[next_block] = (pending_func, line)
                func_stack.append((pending_func, depth, pending_func))
                pending_func = None
            elif await_body:
                block_info[next_block] = (current_func(), line)
            else:
                block_info[next_block] = (current_func(), line)
            next_block += 1
            await_body = False
            i += 1
            continue
        if ch == "}":
            if func_stack and func_stack[-1][1] == depth:
                func_stack.pop()
            block_id.pop(depth, None)
            depth = max(0, depth - 1)
            i += 1
            continue
        if ch == ";":
            if loop_header_depth is None:
                await_body = False
        i += 1

    hits = []
    for bid, loops in loops_by_block.items():
        if len(loops) >= 2:
            name, bline = block_info.get(bid, ("<top>", 0))
            hits.append((bline, name, len(loops), loops))
    return hits


def main():
    roots = [Path("crates/goats/src/game"), Path("mods")]
    total = 0
    for root in roots:
        for path in sorted(root.rglob("*.js")):
            if "wasm" in path.parts:
                continue
            for bline, name, count, loops in scan(path):
                total += 1
                where = ", ".join("%s@%d" % (w, ln) for ln, w in loops)
                print("%s:%-5d %-30s %d in one block: %s" % (path, bline, name, count, where))
    print("\n%d blocks with two or more sibling loops" % total)


if __name__ == "__main__":
    main()
