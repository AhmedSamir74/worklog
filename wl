#!/usr/bin/env python3
"""wl - tiny daily worklog + Jira helper.

Records the Jira tickets you touch (from git branch names, commits, or by hand),
moves tickets to "In Progress" in Jira when you start a branch, and prints the
end-of-day status form.

Run `wl help` for commands. Python 3 stdlib only.
"""
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta

HOME = os.path.expanduser("~")
CONFIG_DIR = os.path.join(HOME, ".config", "worklog")
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.json")
DATA_DIR = os.path.join(HOME, ".local", "share", "worklog")
DAYS_DIR = os.path.join(DATA_DIR, "days")
CACHE_FILE = os.path.join(DATA_DIR, "issues.json")
LOG_FILE = os.path.join(DATA_DIR, "wl.log")
SEEN_FILE = os.path.join(DATA_DIR, "created_branches.json")
KEY_RE = re.compile(r"\b([A-Z][A-Z0-9]{1,9}-\d+)\b")
MARKER = "# >>> worklog hook (managed by wl) >>>"

DEFAULT_CONFIG = {
    "jira_base_url": "",
    "jira_token": "",            # Personal Access Token (Jira Server/DC) -> Bearer
    "jira_user": "",             # optional: basic auth user (if no PAT)
    "jira_password": "",         # optional: basic auth password (if no PAT)
    "in_progress_names": ["In Progress", "In Development", "Development", "Start Progress"],
    "auto_transition": True,     # move To Do -> In Progress from the post-checkout hook
    "jira_trigger": "new_branch",  # "new_branch": only `git checkout -b` / `git switch -c`;
                                   # "any_checkout": also when switching to an existing branch
    "assign_to_me": True,        # assign unassigned issues to me on transition
    "insecure_ssl": False,       # set true only if Jira uses a corporate cert python rejects
    "paused": "",                # "" | "jira" (log only) | "all" (hooks do nothing); see `wl pause`
    "repos": [],                 # repos registered by `wl install-hooks`
}


# ----------------------------------------------------------------- utilities
def log(msg):
    os.makedirs(DATA_DIR, exist_ok=True)
    with open(LOG_FILE, "a") as f:
        f.write("%s %s\n" % (datetime.now().strftime("%Y-%m-%d %H:%M:%S"), msg))


def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save_json(path, data, private=False):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)
    if private:
        os.chmod(path, 0o600)


def load_config():
    cfg = dict(DEFAULT_CONFIG)
    cfg.update(load_json(CONFIG_FILE, {}))
    return cfg


def save_config(cfg):
    save_json(CONFIG_FILE, cfg, private=True)


def parse_date(s):
    if not s or s == "today":
        return date.today()
    if s in ("yesterday", "yday"):
        return date.today() - timedelta(days=1)
    if s == "tomorrow":
        return date.today() + timedelta(days=1)
    return datetime.strptime(s, "%Y-%m-%d").date()


def day_path(d):
    return os.path.join(DAYS_DIR, d.isoformat() + ".json")


def load_day(d):
    data = load_json(day_path(d), None)
    if data is None:
        data = {"date": d.isoformat(), "entries": {}, "order": [], "blockers": []}
    return data


def save_day(data):
    save_json(day_path(date.fromisoformat(data["date"])), data)


def keys_in(text):
    return list(dict.fromkeys(KEY_RE.findall(text or "")))


def git(args, cwd=None):
    try:
        return subprocess.run(["git"] + args, cwd=cwd, capture_output=True,
                              text=True, check=False).stdout.strip()
    except OSError:
        return ""


# --------------------------------------------------------------------- jira
class Jira:
    def __init__(self, cfg):
        self.base = (cfg.get("jira_base_url") or "").rstrip("/")
        self.cfg = cfg
        self.headers = {"Accept": "application/json", "Content-Type": "application/json"}
        if cfg.get("jira_token"):
            self.headers["Authorization"] = "Bearer " + cfg["jira_token"]
        elif cfg.get("jira_user") and cfg.get("jira_password"):
            import base64
            raw = ("%s:%s" % (cfg["jira_user"], cfg["jira_password"])).encode()
            self.headers["Authorization"] = "Basic " + base64.b64encode(raw).decode()

    @property
    def configured(self):
        return bool(self.base and "Authorization" in self.headers)

    def call(self, method, path, body=None, timeout=10):
        url = self.base + path
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method, headers=self.headers)
        import ssl
        ctx = ssl.create_default_context()
        if self.cfg.get("insecure_ssl"):
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        try:
            with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
                txt = r.read().decode() or "null"
                return json.loads(txt)
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")[:300]
            raise RuntimeError("Jira %s %s -> HTTP %s %s" % (method, path, e.code, detail))
        except (urllib.error.URLError, OSError) as e:
            raise RuntimeError("Jira %s %s -> %s" % (method, path, e))

    def issue(self, key):
        return self.call("GET", "/rest/api/2/issue/%s?fields=summary,status,assignee" % key)

    def myself(self):
        return self.call("GET", "/rest/api/2/myself")

    def transitions(self, key):
        return self.call("GET", "/rest/api/2/issue/%s/transitions" % key).get("transitions", [])

    def transition(self, key, transition_id):
        self.call("POST", "/rest/api/2/issue/%s/transitions" % key,
                  {"transition": {"id": transition_id}})

    def assign(self, key, username):
        self.call("PUT", "/rest/api/2/issue/%s/assignee" % key, {"name": username})

    def search(self, jql, max_results=50):
        q = urllib.parse.urlencode({"jql": jql, "maxResults": max_results,
                                    "fields": "summary,status"})
        return self.call("GET", "/rest/api/2/search?" + q).get("issues", [])


def issue_cache():
    return load_json(CACHE_FILE, {})


def remember_issue(key, fields):
    cache = issue_cache()
    cache[key] = {
        "summary": fields.get("summary", ""),
        "status": (fields.get("status") or {}).get("name", ""),
        "category": ((fields.get("status") or {}).get("statusCategory") or {}).get("key", ""),
        "fetched": datetime.now().isoformat(timespec="seconds"),
    }
    save_json(CACHE_FILE, cache)
    return cache[key]


def fetch_issue(jira, key, quiet=False):
    """Fetch summary/status from Jira into the cache. Returns cache entry or None."""
    if not jira.configured:
        return None
    try:
        data = jira.issue(key)
        return remember_issue(key, data.get("fields", {}))
    except RuntimeError as e:
        log(str(e))
        if not quiet:
            print("  (jira) " + str(e), file=sys.stderr)
        return None


def start_in_jira(jira, cfg, key, quiet=False):
    """Move key to In Progress if it is still in the To Do category; assign to me if unassigned."""
    if not jira.configured:
        if not quiet:
            print("  Jira not configured; run `wl setup`.", file=sys.stderr)
        return False
    try:
        data = jira.issue(key)
        fields = data.get("fields", {})
        remember_issue(key, fields)
        status = fields.get("status") or {}
        category = (status.get("statusCategory") or {}).get("key")
        changed = False
        if cfg.get("assign_to_me") and not fields.get("assignee"):
            me = jira.myself().get("name")
            if me:
                jira.assign(key, me)
                changed = True
                if not quiet:
                    print("  %s assigned to %s" % (key, me))
        if category == "new":
            wanted = [n.lower() for n in cfg.get("in_progress_names", [])]
            chosen = None
            for t in jira.transitions(key):
                name = (t.get("to") or {}).get("name", "")
                if name.lower() in wanted or t.get("name", "").lower() in wanted:
                    chosen = t
                    break
            if chosen is None:
                for t in jira.transitions(key):
                    if ((t.get("to") or {}).get("statusCategory") or {}).get("key") == "indeterminate":
                        chosen = t
                        break
            if chosen is None:
                msg = "%s: no transition to In Progress found (status %s)" % (key, status.get("name"))
                log(msg)
                if not quiet:
                    print("  " + msg, file=sys.stderr)
                return changed
            jira.transition(key, chosen["id"])
            fetch_issue(jira, key, quiet=True)
            log("%s -> %s" % (key, (chosen.get("to") or {}).get("name")))
            if not quiet:
                print("  %s: %s -> %s" % (key, status.get("name"), (chosen.get("to") or {}).get("name")))
            return True
        if not quiet:
            print("  %s already '%s'; nothing to do" % (key, status.get("name")))
        return changed
    except RuntimeError as e:
        log(str(e))
        if not quiet:
            print("  (jira) " + str(e), file=sys.stderr)
        return False


# ------------------------------------------------------------------ entries
def add_entry(day, key, note=None, source="manual", summary=None, plan_only=False):
    now = datetime.now().strftime("%H:%M")
    e = day["entries"].get(key)
    if e is None:
        e = {"note": "", "summary": "", "first": now, "last": now, "sources": [],
             "status": None, "plan": None, "commits": 0}
        day["entries"][key] = e
        day["order"].append(key)
    e["last"] = now
    if source not in e["sources"]:
        e["sources"].append(source)
    if note:
        e["note"] = note
    if summary and not e.get("summary"):
        e["summary"] = summary
    if plan_only and len(e["sources"]) == 1 and source == "plan":
        e["plan"] = True
    return e


def label(key, e, cache):
    text = e.get("note") or e.get("summary") or cache.get(key, {}).get("summary") or ""
    return text


def is_wip(key, e, cache):
    if e.get("status") == "done":
        return False
    if e.get("status") == "wip":
        return True
    cat = cache.get(key, {}).get("category")
    if cat == "done":
        return False
    return True


def worked_keys(day):
    return [k for k in day["order"] if day["entries"][k]["sources"] != ["plan"]]


# ----------------------------------------------------------------- commands
def cmd_add(args, cfg, start=False):
    if not args:
        die("usage: wl %s KEY [note...]" % ("start" if start else "add"))
    key = args[0].upper()
    if not KEY_RE.fullmatch(key):
        die("'%s' does not look like a Jira key (e.g. MAR-12345)" % key)
    note = " ".join(args[1:]).strip() or None
    day = load_day(date.today())
    jira = Jira(cfg)
    cached = issue_cache().get(key) or fetch_issue(jira, key)
    e = add_entry(day, key, note=note, source="manual", summary=(cached or {}).get("summary"))
    if start:
        e["status"] = "wip"
        start_in_jira(jira, cfg, key)
    save_day(day)
    print("%s  %s" % (key, label(key, e, issue_cache())))


def cmd_mark(args, status):
    if not args:
        die("usage: wl %s KEY" % status)
    day = load_day(date.today())
    for key in [a.upper() for a in args]:
        e = day["entries"].get(key) or add_entry(day, key, source="plan" if status == "plan" else "manual",
                                                 plan_only=(status == "plan"))
        if status == "plan":
            e["plan"] = True
        elif status == "unplan":
            e["plan"] = False
        else:
            e["status"] = status
        print("%s marked %s" % (key, status))
    save_day(day)


def cmd_note(args):
    if len(args) < 2:
        die("usage: wl note KEY text...")
    day = load_day(date.today())
    key = args[0].upper()
    e = day["entries"].get(key) or add_entry(day, key)
    e["note"] = " ".join(args[1:])
    save_day(day)
    print("%s  %s" % (key, e["note"]))


def cmd_rm(args):
    day = load_day(date.today())
    for key in [a.upper() for a in args]:
        day["entries"].pop(key, None)
        day["order"] = [k for k in day["order"] if k != key]
    save_day(day)


def cmd_block(args):
    day = load_day(date.today())
    text = " ".join(args).strip()
    if text in ("", "-", "clear", "none"):
        day["blockers"] = []
        print("blockers cleared")
    else:
        day["blockers"].append(text)
        print("blocker added")
    save_day(day)


def cmd_log(args, cfg):
    d = parse_date(args[0] if args else None)
    day = load_day(d)
    cache = issue_cache()
    if not day["order"]:
        print("no entries for %s" % d)
        return
    for key in day["order"]:
        e = day["entries"][key]
        flags = []
        if e["sources"] == ["plan"]:
            flags.append("plan-only")
        elif e.get("status") == "done":
            flags.append("done")
        elif is_wip(key, e, cache):
            flags.append("wip")
        if e.get("plan"):
            flags.append("tomorrow")
        print("%s-%s  %-11s %-50s [%s] %s" % (
            e["first"], e["last"], key, label(key, e, cache)[:50],
            ",".join(e["sources"]), " ".join(flags)))
    if day["blockers"]:
        print("blockers: " + "; ".join(day["blockers"]))


def build_report(day, cache):
    lines = ["Tickets / tasks worked on:"]
    worked = worked_keys(day)
    for key in worked:
        lines.append("%-13s %s" % (key, label(key, day["entries"][key], cache)))
    if not worked:
        lines.append("-")
    lines += ["", "Still in progress:"]
    wip = [k for k in worked if is_wip(k, day["entries"][k], cache)]
    for key in wip:
        lines.append("%-13s %s" % (key, label(key, day["entries"][key], cache)))
    if not wip:
        lines.append("-")
    lines += ["", "Plan for tomorrow:"]
    explicit = [k for k in day["order"] if day["entries"][k].get("plan")]
    plan = explicit + [k for k in wip if k not in explicit and day["entries"][k].get("plan") is None]
    for key in plan:
        lines.append("%-13s %s" % (key, label(key, day["entries"][key], cache)))
    if not plan:
        lines.append("-")
    lines += ["", "Blockers:"]
    lines += day["blockers"] or ["-"]
    return "\n".join(lines) + "\n"


def cmd_report(args, cfg):
    copy = "--copy" in args or "-c" in args
    refresh = "--refresh" in args
    rest = [a for a in args if not a.startswith("-")]
    d = parse_date(rest[0] if rest else None)
    day = load_day(d)
    jira = Jira(cfg)
    if jira.configured:
        cache = issue_cache()
        for key in day["order"]:
            c = cache.get(key)
            if refresh or not c or c.get("fetched", "")[:10] != date.today().isoformat():
                fetch_issue(jira, key, quiet=True)
    text = build_report(day, issue_cache())
    sys.stdout.write(text)
    if copy:
        try:
            subprocess.run(["pbcopy"], input=text, text=True, check=True)
            print("(copied to clipboard)", file=sys.stderr)
        except (OSError, subprocess.CalledProcessError):
            pass


def cmd_scan(args, cfg):
    """Derive today's tickets from the git reflogs/commits of registered repos."""
    d = parse_date(args[0] if args and not args[0].startswith("-") else None)
    day = load_day(d)
    jira = Jira(cfg)
    cache = issue_cache()
    found = {}
    me = git(["config", "user.email"])
    for repo in cfg.get("repos", []):
        if not os.path.isdir(repo):
            continue
        # branch checkouts that day
        out = git(["log", "-g", "--date=short", "--format=%gd%x09%gs", "HEAD"], cwd=repo)
        for line in out.splitlines():
            if ("{%s" % d.isoformat()) not in line:
                continue
            for key in keys_in(line):
                found.setdefault(key, set()).add("branch")
        # commits that day on local branches
        since = d.isoformat() + " 00:00"
        until = (d + timedelta(days=1)).isoformat() + " 00:00"
        extra = ["--author=" + me] if me else []
        out = git(["log", "--branches", "--since=" + since, "--until=" + until,
                   "--format=%H%x09%s%x09%D"] + extra, cwd=repo)
        for line in out.splitlines():
            parts = line.split("\t")
            for key in keys_in(" ".join(parts[1:])):
                found.setdefault(key, set()).add("commit")
        # branches whose tip commit is from that day (commit messages without a key)
        out = git(["for-each-ref", "--format=%(refname:short)%x09%(committerdate:short)",
                   "refs/heads"], cwd=repo)
        for line in out.splitlines():
            name, _, cdate = line.partition("\t")
            if cdate == d.isoformat():
                for key in keys_in(name):
                    found.setdefault(key, set()).add("commit")
    for key, sources in found.items():
        cached = cache.get(key) or fetch_issue(jira, key, quiet=True)
        for s in sorted(sources):
            add_entry(day, key, source=s, summary=(cached or {}).get("summary"))
    save_day(day)
    if found:
        print("found %d ticket(s) for %s: %s" % (len(found), d, ", ".join(sorted(found))))
    else:
        print("no ticket keys found in git activity for %s" % d)


def cmd_sync(args, cfg):
    """Pull issues assigned to me that were updated today from Jira."""
    jira = Jira(cfg)
    if not jira.configured:
        die("Jira not configured; run `wl setup`")
    day = load_day(date.today())
    jql = cfg.get("sync_jql") or "assignee = currentUser() AND updated >= startOfDay() ORDER BY updated DESC"
    try:
        issues = jira.search(jql)
    except RuntimeError as e:
        die(str(e))
    for it in issues:
        c = remember_issue(it["key"], it.get("fields", {}))
        add_entry(day, it["key"], source="jira", summary=c["summary"])
    save_day(day)
    print("synced %d issue(s): %s" % (len(issues), ", ".join(i["key"] for i in issues)))


def cmd_jira(args, cfg):
    """wl jira KEY  -> show status; wl jira start KEY -> transition only."""
    jira = Jira(cfg)
    if not jira.configured:
        die("Jira not configured; run `wl setup`")
    if args and args[0] == "start":
        for key in args[1:]:
            start_in_jira(jira, cfg, key.upper())
        return
    if args and args[0] == "me":
        print(json.dumps(jira.myself(), indent=2)[:800])
        return
    if args and args[0] == "transitions" and len(args) > 1:
        key = args[1].upper()
        c = fetch_issue(jira, key)
        if c:
            print("%s is '%s'. Available moves:" % (key, c["status"]))
        for t in jira.transitions(key):
            print("  %-28s -> %s" % (t.get("name"), (t.get("to") or {}).get("name")))
        return
    if args and args[0] == "move" and len(args) > 2:
        key, target = args[1].upper(), " ".join(args[2:]).lower()
        for t in jira.transitions(key):
            if target in (t.get("name", "").lower(), (t.get("to") or {}).get("name", "").lower()):
                jira.transition(key, t["id"])
                c = fetch_issue(jira, key, quiet=True) or {}
                print("%s -> %s" % (key, c.get("status") or (t.get("to") or {}).get("name")))
                return
        die("%s: no transition named '%s'. See `wl jira transitions %s`." % (key, target, key))
    for key in args:
        c = fetch_issue(jira, key.upper())
        if c:
            print("%-11s %-14s %s" % (key.upper(), c["status"], c["summary"]))


# -------------------------------------------------------------------- hooks
def cmd_hook(args, cfg):
    """Called by git hooks. Must be fast and must never fail the git command."""
    try:
        kind = args[0]
        repo = os.getcwd()
        if hook_disabled(cfg, repo, "all"):
            return
        jira_ok = cfg.get("auto_transition") and not hook_disabled(cfg, repo, "jira")
        branch = git(["symbolic-ref", "--short", "-q", "HEAD"], cwd=repo)
        keys = keys_in(branch)
        if kind == "post-checkout":
            # args: prev new flag ; flag==1 means a branch checkout (not a file checkout)
            if len(args) < 4 or args[3] != "1" or not keys:
                return
            is_new = branch_just_created(repo, branch)
            touch_jira = bool(jira_ok and (is_new or cfg.get("jira_trigger") == "any_checkout"))
            day = load_day(date.today())
            cache = issue_cache()
            for key in keys:
                add_entry(day, key, source="branch", summary=cache.get(key, {}).get("summary"))
            save_day(day)
            log("post-checkout %s branch=%s new=%s jira=%s" % (",".join(keys), branch, is_new, touch_jira))
            if touch_jira and Jira(cfg).configured:
                spawn_background(["jira-bg"] + keys)
            if touch_jira:
                what = " (new branch, Jira -> In Progress)" if is_new else " (Jira -> In Progress)"
            elif is_new:
                what = " (new branch, jira untouched)"
            else:
                what = ""
            print("worklog: noted %s%s" % (", ".join(keys), what), file=sys.stderr)
        elif kind == "post-commit":
            msg = git(["log", "-1", "--format=%s"], cwd=repo)
            for k in keys_in(msg):
                if k not in keys:
                    keys.append(k)
            if not keys:
                return
            day = load_day(date.today())
            cache = issue_cache()
            for key in keys:
                e = add_entry(day, key, source="commit", summary=cache.get(key, {}).get("summary"))
                e["commits"] = e.get("commits", 0) + 1
            save_day(day)
            log("post-commit %s" % ",".join(keys))
            missing = [k for k in keys if k not in cache]
            if missing and Jira(cfg).configured:
                spawn_background(["fetch-bg"] + missing)
    except Exception as e:  # never break git
        log("hook error: %r" % (e,))


def branch_just_created(repo, branch):
    """True only for a branch that this checkout created (`git checkout -b`, `git switch -c`).

    False when switching to a branch that already existed locally, and false when the
    checkout only made a local copy of a branch that already exists on a remote
    (someone else's branch, or your own from another machine).
    """
    ref = "refs/heads/" + branch
    # the branch's own reflog has exactly one entry: its creation
    entries = git(["reflog", "show", "--date=unix", "--format=%gd", ref], cwd=repo).splitlines()
    if len(entries) != 1:
        return False
    # ...and that creation happened just now, not earlier via `git branch NAME`
    m = re.search(r"@\{(\d+)\}", entries[0])
    try:
        window = int(os.environ.get("WL_NEW_WINDOW", "30"))
    except ValueError:
        window = 30
    if not m or abs(datetime.now().timestamp() - int(m.group(1))) > window:
        return False
    # ...and no remote already has a branch with this name
    for remote in git(["remote"], cwd=repo).split():
        if git(["rev-parse", "--verify", "--quiet", "refs/remotes/%s/%s" % (remote, branch)], cwd=repo):
            return False
    # ...and this creation was not already handled (switching away and straight back)
    seen = load_json(SEEN_FILE, {})
    key = "%s\t%s" % (git(["rev-parse", "--show-toplevel"], cwd=repo) or repo, branch)
    if seen.get(key) == m.group(1):
        return False
    cutoff = datetime.now().timestamp() - 30 * 86400
    seen = {k: v for k, v in seen.items() if int(v) > cutoff}
    seen[key] = m.group(1)
    save_json(SEEN_FILE, seen)
    return True


def hook_disabled(cfg, repo, what):
    """what: "all" -> hook does nothing; "jira" -> log but never change Jira.

    Checked in order: WL_SKIP / WL_NO_JIRA env vars (one command),
    `wl pause` (until `wl resume`), `git config worklog.enabled|worklog.jira false` (per repo).
    """
    if what == "all":
        if os.environ.get("WL_SKIP"):
            return True
        if cfg.get("paused") == "all":
            return True
        return git(["config", "--bool", "worklog.enabled"], cwd=repo) == "false"
    if os.environ.get("WL_NO_JIRA") or os.environ.get("WL_SKIP"):
        return True
    if cfg.get("paused") in ("jira", "all"):
        return True
    return git(["config", "--bool", "worklog.jira"], cwd=repo) == "false"


def spawn_background(argv):
    try:
        subprocess.Popen([sys.executable, os.path.abspath(__file__)] + argv,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError as e:
        log("spawn failed: %r" % (e,))


def cmd_background(kind, keys, cfg):
    jira = Jira(cfg)
    for key in keys:
        if kind == "jira-bg":
            start_in_jira(jira, cfg, key, quiet=True)
        else:
            fetch_issue(jira, key, quiet=True)
        # refresh the label in today's entry
        day = load_day(date.today())
        c = issue_cache().get(key)
        if c and key in day["entries"] and not day["entries"][key].get("summary"):
            day["entries"][key]["summary"] = c["summary"]
            save_day(day)


HOOK_TEMPLATE = """#!/bin/sh
%s
# Records the Jira key from the branch name in your daily worklog and, for
# post-checkout, moves the ticket to In Progress in Jira (in the background).
# It never fails the git command.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
if [ -x "$HOME/.local/bin/wl" ]; then
  "$HOME/.local/bin/wl" hook %s "$@" || true
elif command -v wl >/dev/null 2>&1; then
  wl hook %s "$@" || true
fi
# <<< worklog hook <<<
"""


def cmd_install_hooks(args, cfg):
    repos = args or [os.getcwd()]
    for repo in repos:
        repo = os.path.abspath(os.path.expanduser(repo))
        top = git(["rev-parse", "--show-toplevel"], cwd=repo)
        if not top:
            print("skip %s: not a git repository" % repo)
            continue
        def git_abs(*rev_parse_args):
            p = git(["rev-parse"] + list(rev_parse_args), cwd=top)
            return os.path.realpath(p if os.path.isabs(p) else os.path.join(top, p))

        hooks_dir = git_abs("--git-path", "hooks")
        os.makedirs(hooks_dir, exist_ok=True)
        # husky & co. point core.hooksPath at a tracked folder inside the worktree
        inside_worktree = not (hooks_dir + os.sep).startswith(git_abs("--git-common-dir") + os.sep) \
            and not (hooks_dir + os.sep).startswith(git_abs("--git-dir") + os.sep)
        for hook in ("post-checkout", "post-commit"):
            path = os.path.join(hooks_dir, hook)
            body = HOOK_TEMPLATE % (MARKER, hook, hook)
            if os.path.exists(path):
                existing = open(path).read()
                if MARKER in existing:
                    print("ok   %s already has worklog hook" % path)
                    continue
                # keep the existing hook, append ours
                with open(path, "a") as f:
                    f.write("\n" + body.split("\n", 1)[1])
                print("append %s" % path)
            else:
                with open(path, "w") as f:
                    f.write(body)
                print("write %s" % path)
            os.chmod(path, 0o755)
            if inside_worktree:
                # hooks dir is a tracked folder (e.g. husky): keep our files out of git status
                exclude = os.path.join(git_abs("--git-path", "info"), "exclude")
                rel = os.path.relpath(path, os.path.realpath(top))
                os.makedirs(os.path.dirname(exclude), exist_ok=True)
                current = open(exclude).read() if os.path.exists(exclude) else ""
                if rel not in current.splitlines():
                    with open(exclude, "a") as f:
                        if current and not current.endswith("\n"):
                            f.write("\n")
                        f.write(rel + "\n")
        if top not in cfg["repos"]:
            cfg["repos"].append(top)
    save_config(cfg)
    print("registered repos: %s" % ", ".join(cfg["repos"]))


# ------------------------------------------------------------------- config
def cmd_config(args, cfg):
    if not args or args[0] == "show":
        shown = dict(cfg)
        for k in ("jira_token", "jira_password"):
            if shown.get(k):
                shown[k] = "***"
        print(json.dumps(shown, indent=2, sort_keys=True))
        print("file: " + CONFIG_FILE)
        return
    if args[0] == "set" and len(args) >= 3:
        key, value = args[1], " ".join(args[2:])
        if value.lower() in ("true", "false"):
            value = value.lower() == "true"
        elif value.startswith("["):
            value = json.loads(value)
        cfg[key] = value
        save_config(cfg)
        print("%s set" % key)
        return
    if args[0] == "test":
        jira = Jira(cfg)
        if not jira.configured:
            die("Jira not configured; run `wl setup`")
        try:
            me = jira.myself()
            print("ok: logged in to %s as %s (%s)" % (jira.base, me.get("displayName"), me.get("name")))
        except RuntimeError as e:
            die(str(e))
        return
    die("usage: wl config [show | set KEY VALUE | test]")


def cmd_setup(cfg):
    print("Jira setup (stored in %s, mode 600)" % CONFIG_FILE)
    base = input("Jira base URL [%s]: " % (cfg.get("jira_base_url") or "https://jira.alinma.com")).strip()
    cfg["jira_base_url"] = base or cfg.get("jira_base_url") or "https://jira.alinma.com"
    print("Create a Personal Access Token in Jira: avatar (top right) > Profile > Personal Access Tokens > Create.")
    import getpass
    tok = getpass.getpass("Personal Access Token (leave empty to keep current): ").strip()
    if tok:
        cfg["jira_token"] = tok
    save_config(cfg)
    cmd_config(["test"], cfg)


def cmd_pause(args, cfg):
    what = (args[0] if args else "jira").lower()
    if what not in ("jira", "all"):
        die("usage: wl pause [jira|all]   (jira = keep logging, stop touching Jira; all = hooks off)")
    cfg["paused"] = what
    save_config(cfg)
    print("paused: %s. Resume with `wl resume`." % (
        "Jira updates (branches are still logged)" if what == "jira" else "all hooks"))


def cmd_resume(cfg):
    cfg["paused"] = ""
    save_config(cfg)
    print("resumed: hooks log branches and update Jira again")


# ---------------------------------------------------------------- reminder
PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.worklog.remind</string>
  <key>ProgramArguments</key><array>
    <string>/bin/sh</string><string>-c</string>
    <string>"$HOME/.local/bin/wl" report --copy >/dev/null 2>&amp;1; /usr/bin/osascript -e 'display notification "Daily status copied to clipboard. Run: wl report" with title "Worklog"'</string>
  </array>
  <key>StartCalendarInterval</key><array>%s</array>
  <key>RunAtLoad</key><false/>
</dict></plist>
"""


def cmd_remind(args):
    plist = os.path.join(HOME, "Library", "LaunchAgents", "com.worklog.remind.plist")
    if args and args[0] == "off":
        subprocess.run(["launchctl", "unload", plist], capture_output=True)
        if os.path.exists(plist):
            os.remove(plist)
        print("reminder removed")
        return
    hhmm = args[0] if args else "17:30"
    h, m = [int(x) for x in hhmm.split(":")]
    # Sunday..Thursday work week
    items = "".join("<dict><key>Weekday</key><integer>%d</integer><key>Hour</key><integer>%d</integer>"
                    "<key>Minute</key><integer>%d</integer></dict>" % (wd, h, m) for wd in (0, 1, 2, 3, 4))
    os.makedirs(os.path.dirname(plist), exist_ok=True)
    with open(plist, "w") as f:
        f.write(PLIST % items)
    subprocess.run(["launchctl", "unload", plist], capture_output=True)
    subprocess.run(["launchctl", "load", plist], capture_output=True)
    print("reminder set for %s Sun-Thu (notification + report copied to clipboard)" % hhmm)


# --------------------------------------------------------------------- main
HELP = """wl - daily worklog + Jira helper

Recording (today):
  wl add KEY [note]        note a ticket you worked on (note replaces the Jira summary in the report)
  wl start KEY [note]      add + move the ticket to In Progress in Jira (and assign to you)
  wl done KEY...           finished today: drop it from "Still in progress" / "Plan for tomorrow"
  wl wip KEY...            force "still in progress"
  wl plan KEY...           put a ticket in "Plan for tomorrow" (even if not worked on today)
  wl unplan KEY...         remove from tomorrow's plan
  wl note KEY text         change the text shown for a ticket
  wl rm KEY...             remove a ticket from today
  wl block text | wl block -   add a blocker / clear blockers

Reading:
  wl log [DATE]            what was recorded (DATE: today, yesterday, 2026-11-05)
  wl report [DATE] [--copy] [--refresh]   print the end-of-day form (--copy -> clipboard)
  wl scan [DATE]           find tickets from git activity in registered repos
  wl sync                  add tickets assigned to you that Jira says were updated today
  wl jira KEY...           show Jira status;  wl jira start KEY  -> transition only
  wl jira transitions KEY  list the moves Jira allows;  wl jira move KEY "To Do"  -> move it back

Jira is only updated when the hook sees a branch being created (git checkout -b / git switch -c).
Switching to an existing branch only logs the ticket. `wl config set jira_trigger any_checkout`
restores updating on every switch.

Stopping the automation:
  WL_NO_JIRA=1 git checkout -b feature/MAR-1-x   log the branch but leave Jira alone (this command only)
  WL_SKIP=1 git checkout -b ...                  hooks do nothing for this command
  wl pause [jira|all] / wl resume                until you resume (jira = default)
  git config worklog.jira false                  never touch Jira from this repo (worklog.enabled false = hooks off)
  wl config set auto_transition false            never touch Jira from anywhere

Setup:
  wl setup                 enter Jira URL + Personal Access Token
  wl config [show|set K V|test]
  wl install-hooks [REPO...]   install post-checkout/post-commit hooks (default: current repo)
  wl remind [HH:MM|off]    daily macOS reminder (Sun-Thu, default 17:30) that copies the report
"""


def die(msg, code=1):
    print(msg, file=sys.stderr)
    sys.exit(code)


def main(argv):
    if not argv or argv[0] in ("help", "-h", "--help"):
        print(HELP)
        return
    cmd, args = argv[0], argv[1:]
    cfg = load_config()
    if cmd == "add":
        cmd_add(args, cfg)
    elif cmd == "start":
        cmd_add(args, cfg, start=True)
    elif cmd in ("done", "wip", "plan", "unplan"):
        cmd_mark(args, cmd)
    elif cmd == "note":
        cmd_note(args)
    elif cmd == "rm":
        cmd_rm(args)
    elif cmd == "block":
        cmd_block(args)
    elif cmd == "log":
        cmd_log(args, cfg)
    elif cmd == "report":
        cmd_report(args, cfg)
    elif cmd == "scan":
        cmd_scan(args, cfg)
    elif cmd == "sync":
        cmd_sync(args, cfg)
    elif cmd == "jira":
        cmd_jira(args, cfg)
    elif cmd == "hook":
        cmd_hook(args, cfg)
    elif cmd in ("jira-bg", "fetch-bg"):
        cmd_background(cmd, args, cfg)
    elif cmd == "install-hooks":
        cmd_install_hooks(args, cfg)
    elif cmd == "config":
        cmd_config(args, cfg)
    elif cmd == "setup":
        cmd_setup(cfg)
    elif cmd == "remind":
        cmd_remind(args)
    elif cmd == "pause":
        cmd_pause(args, cfg)
    elif cmd == "resume":
        cmd_resume(cfg)
    else:
        die("unknown command '%s'\n%s" % (cmd, HELP))


if __name__ == "__main__":
    main(sys.argv[1:])
