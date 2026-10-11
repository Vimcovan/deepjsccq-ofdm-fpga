"""Rewrite pandoc-style math for GitHub's renderer (the docx keeps using the original file).

GitHub parses Markdown before handing math to MathJax: backslash + ASCII punctuation inside $...$ / $$...$$
(\\! \\; \\, \\{ \\|) is eaten as a Markdown escape, and an inline $ glued to CJK text is not recognised as math.
Its own syntaxes avoid both: ```math fenced blocks for display math and $`...`$ for inline math.

    python md_github.py <in.md> <out.md>
"""
import re
import sys

src, dst = sys.argv[1], sys.argv[2]
lines = open(src, encoding="utf-8").read().split("\n")
out = []
fence = None                                  # inside a ``` / ~~~ code block: copy verbatim
inline = re.compile(r"(?<![$\\])\$(?![$\s])([^$\n]+?)(?<![\\\s])\$(?!\$)")
code_span = re.compile(r"(`+)(.+?)\1")
i = 0
while i < len(lines):
    line = lines[i]
    m = re.match(r"^(\s*)(```|~~~)", line)
    if fence:
        out.append(line)
        if m and m.group(2) == fence:
            fence = None
        i += 1
        continue
    if m:
        fence = m.group(2)
        out.append(line)
        i += 1
        continue
    # display math: $$...$$ on one line, or $$ ... $$ over several lines
    m = re.match(r"^(\s*(?:[-*+] |\d+\. )?)\s*\$\$(.*)$", line)
    if m:
        ind = " " * len(m.group(1))
        rest = m.group(2)
        body = []
        if rest.rstrip().endswith("$$") and rest.strip() != "$$":
            body = [rest.rstrip()[:-2]]
        else:
            if rest.strip():
                body.append(rest)
            i += 1
            while i < len(lines) and not lines[i].rstrip().endswith("$$"):
                body.append(lines[i].strip())
                i += 1
            last = lines[i].rstrip()[:-2].strip() if i < len(lines) else ""
            if last:
                body.append(last)
        if m.group(1).strip():                 # "- $$...$$" list item: keep the marker on its own line
            out.append(m.group(1).rstrip())
        out += [ind + "```math"] + [ind + b.strip() for b in body if b.strip()] + [ind + "```"]
        i += 1
        continue
    # inline math outside code spans
    parts, pos = [], 0
    for cm in code_span.finditer(line):
        parts.append(inline.sub(r"$`\1`$", line[pos:cm.start()]))
        parts.append(cm.group(0))
        pos = cm.end()
    parts.append(inline.sub(r"$`\1`$", line[pos:]))
    out.append("".join(parts))
    i += 1
open(dst, "w", encoding="utf-8", newline="\n").write("\n".join(out))
