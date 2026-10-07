"""Condense Claude Code / Codex session logs (jsonl) into readable, de-identified Markdown.

    python export_transcripts.py claude <session.jsonl> <out.md>
    python export_transcripts.py codex  <rollout.jsonl> <out.md>
    python export_transcripts.py claude-batch <out_dir> <session.jsonl>...   (resumed sessions: history kept once)
    python export_transcripts.py codex-batch <out_dir> <~/.codex/sessions> <tag>=<cwd> ...   (sessions whose cwd matches)

Kept: the user's messages, the assistant's text replies, and one line per tool call (tool name + short description).
Dropped: tool outputs, system / developer prompts, hidden reasoning, images, account ids.
De-identified: e-mail addresses, IPv4 addresses, local user / drive paths (see SCRUB); rude words in the user's
messages are masked (PROFANITY) and unrelated requests dropped with their replies (OFF_TOPIC).
"""
import glob
import json
import os
import re
import sys

MAX_USER = 6000            # long pasted text is cut
MAX_TOOL = 160

SCRUB = [
    (re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+"), "<email>"),
    (re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b"), "<ip>"),
    (re.compile(r"(?i)[cC]:[\\/]+Users[\\/]+[^\\/\s\"'`]+"), "~"),
    (re.compile(r"(?i)/c/Users/[^/\s\"'`]+"), "~"),
    (re.compile(r"(?i)[dD]:[\\/]+ClaudePrj"), "<work>"),
    (re.compile(r"(?i)/d/ClaudePrj"), "<work>"),
    (re.compile(r"(?i)[dD]:[\\/]+CodexPrj"), "<codex-work>"),
    (re.compile(r"(?i)/d/CodexPrj"), "<codex-work>"),
    (re.compile(r"(?i)[dD]:[\\/]+VivadoPrj"), "<vivado-work>"),
    (re.compile(r"(?i)[A-Z]:[\\/]+(?:Program Files|ProgramData|Users|Windows)[^\s\"'`]*"), "<sys-path>"),
    (re.compile(r"(?i)\b(user|account)-[A-Za-z0-9]{16,}\b"), "<id>"),
]
DROP_USER = ("<system-reminder>", "<command-name>", "<local-command", "<environment_context>",
             "This session is being continued from a previous conversation", "<task-notification>",
             "Caveat: The messages below", "<user_instructions>", "<app-context>", "<turn_aborted>",
             "<recommended_plugins>", "<external_codex_apps", "<heartbeat>", "<skills_instructions>", "<permissions instructions>")
GUARDIAN = "The following is the Codex agent history whose request action you are assessing"
OFF_TOPIC = ("生成一组不承载语义的整数选择", "这是一次独立的数值选择记录")   # unrelated requests: whole turn dropped
PROFANITY = re.compile("傻逼|他妈的|神经病|有病")                            # user's words, masked as ***
SEEN = set()               # Claude message uuids already exported (resumed / forked sessions repeat history)


def scrub(t):
    for rx, rep in SCRUB:
        t = rx.sub(rep, t)
    return t


def strip_reminders(t):
    return re.sub(r"<system-reminder>.*?</system-reminder>", "", t, flags=re.S).strip()


def clip(t, n):
    t = t.strip()
    return t if len(t) <= n else t[:n] + f" …[{len(t) - n} 字已省略]"


class Out:
    def __init__(self):
        self.lines, self.tools, self.n_user, self.n_asst, self.t0, self.t1 = [], [], 0, 0, None, None
        self.skip = False                        # inside an off-topic turn

    def ts(self, t):
        if t:
            self.t0 = self.t0 or t
            self.t1 = t

    def flush_tools(self):
        if self.tools:
            self.lines.append("<details><summary>工具调用 × %d</summary>\n" % len(self.tools))
            self.lines += ["- " + scrub(x) for x in self.tools]
            self.lines.append("\n</details>\n")
            self.tools = []

    def user(self, text, t):
        text = strip_reminders(text)
        if not text or any(text.lstrip().startswith(d) for d in DROP_USER):
            return
        self.flush_tools()
        self.skip = any(text.lstrip().startswith(d) for d in OFF_TOPIC)
        if self.skip:
            return
        self.ts(t)
        self.n_user += 1
        self.lines.append(f"### 用户 · {(t or '')[:16].replace('T', ' ')}\n")
        self.lines.append("> " + PROFANITY.sub("***", scrub(clip(text, MAX_USER))).replace("\n", "\n> ") + "\n")

    def asst(self, text, t):
        text = text.strip()
        if not text or self.skip:
            return
        self.flush_tools()
        self.ts(t)
        self.n_asst += 1
        self.lines.append("**助手：**\n\n" + scrub(text) + "\n")

    def tool(self, name, desc):
        if self.skip:
            return
        self.tools.append(f"`{name}` " + clip(" ".join(str(desc).split()), MAX_TOOL))


def claude(fn, o):
    for line in open(fn, encoding="utf-8"):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("isMeta") or e.get("isCompactSummary") or e.get("type") not in ("user", "assistant"):
            continue
        if e.get("uuid") in SEEN:
            continue
        SEEN.add(e.get("uuid"))
        t, c = e.get("timestamp"), e.get("message", {}).get("content")
        if e["type"] == "user":
            if isinstance(c, str):
                o.user(c, t)
            elif isinstance(c, list):
                txt = "\n".join(x.get("text", "") for x in c if x.get("type") == "text")
                if txt:
                    o.user(txt, t)
        elif isinstance(c, list):
            for x in c:
                if x.get("type") == "text":
                    o.asst(x["text"], t)
                elif x.get("type") == "tool_use":
                    i = x.get("input", {})
                    d = i.get("description") or i.get("file_path") or i.get("pattern") or i.get("url") or i.get("command", "")
                    o.tool(x.get("name", "?"), d)


def codex(fn, o):
    for line in open(fn, encoding="utf-8"):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("type") != "response_item":
            continue
        p, t = e.get("payload", {}), e.get("timestamp")
        k = p.get("type")
        if k == "message" and p.get("role") in ("user", "assistant"):
            txt = "\n".join(x.get("text", "") for x in p.get("content", []) if isinstance(x, dict))
            if txt.lstrip().startswith(GUARDIAN):          # auto-approval reviewer session, not a conversation
                o.lines, o.tools, o.n_user, o.n_asst = [], [], 0, 0
                return
            (o.user if p["role"] == "user" else o.asst)(txt, t)
        elif k == "custom_tool_call":
            o.tool(p.get("name", "?"), p.get("input", "")[:MAX_TOOL])
        elif k == "function_call":
            o.tool(p.get("name", "?"), p.get("arguments", "")[:MAX_TOOL])
        elif k == "agent_message":
            o.tool("agent_message", f"{p.get('author', '')} → {p.get('recipient', '')}")


def main():
    """claude|codex <in.jsonl> <out.md>, or claude-batch <out_dir> <in.jsonl>... (oldest first, history de-duplicated)"""
    if sys.argv[1] == "claude-batch":
        files = sorted(sys.argv[3:], key=first_ts)
        for fn in files:
            export("claude", fn, os.path.join(sys.argv[2], prefix(fn) + os.path.basename(fn)[:8] + ".md"))
        return
    if sys.argv[1] == "codex-batch":                       # codex-batch <out_dir> <sessions_root> <tag>=<cwd> ...
        tags = dict(a.split("=", 1)[::-1] for a in sys.argv[4:])
        for fn in sorted(glob.glob(os.path.join(sys.argv[3], "**", "*.jsonl"), recursive=True)):
            cwd = json.loads(open(fn, encoding="utf-8").readline()).get("payload", {}).get("cwd", "")
            tag = next((t for c, t in tags.items() if cwd.lower() == c.lower()), None)
            if tag:
                b = os.path.basename(fn)[:-6]
                stamp = b[8:27].replace(":", "").replace("T", "_") + "_" + b[-36:-28]
                export("codex", fn, os.path.join(sys.argv[2], f"{tag}_{stamp}.md"))
        return
    export(*sys.argv[1:4])


def first_ts(fn):
    for line in open(fn, encoding="utf-8"):
        t = json.loads(line).get("timestamp")
        if t:
            return t
    return ""


def prefix(fn):
    d = os.path.basename(os.path.dirname(os.path.abspath(fn)))
    return d.replace("D--ClaudePrj-", "") + "_"


def export(kind, fn, out):
    o = Out()
    (claude if kind == "claude" else codex)(fn, o)
    o.flush_tools()
    if o.n_user == 0:
        print("skip (empty)", fn)
        return
    head = (f"# {'Claude Code' if kind == 'claude' else 'Codex'} 会话 · {(o.t0 or '')[:10]} – {(o.t1 or '')[:10]}\n\n"
            f"用户消息 {o.n_user} 条，助手回复 {o.n_asst} 段。由 `report/llm_collab/tools/export_transcripts.py` 从原始记录压缩、脱敏生成。\n\n---\n")
    open(out, "w", encoding="utf-8", newline="\n").write(head + "\n".join(o.lines) + "\n")
    print(out, o.n_user, o.n_asst, o.t0, o.t1)


if __name__ == "__main__":
    main()
