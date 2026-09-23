"""
adapters.py — یک آداپتور برای هر برنامهٔ هوش مصنوعی.

قانون طلایی این فایل: **هیچ آداپتوری حق ندارد بقیه را زمین بزند.**
هر متد عمومی داخل try/except است و در بدترین حالت وضعیت "unknown" برمی‌گرداند.
دلیل: اگر Hermes موقتاً ۵۰۰ بدهد، کاربر باید همچنان Claude Code و Pi را ببیند.

هر آداپتور سه چیز می‌دهد:
  status()   -> سلامت سرویس + مدل فعلی
  sessions() -> فهرست نشست‌ها با آخرین فعالیت
  و در صورت پشتیبانی: send(), set_model()
"""
from __future__ import annotations

import glob
import json
import os
import re
import sqlite3
import subprocess
import time
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from typing import Any

import httpx

# ریشهٔ فایل‌سیستم. روی سرور خالی است (یعنی /root واقعی).
# فقط برای تست محلی با AIHUB_ROOT=/tmp/fake مقدار می‌گیرد.
R = os.environ.get("AIHUB_ROOT", "")


def rp(path: str) -> str:
    """مسیر واقعی با در نظر گرفتن ریشهٔ تست."""
    return R + path


# ---------------------------------------------------------------- data model


@dataclass
class Session:
    id: str
    title: str = ""
    preview: str = ""
    last_active: str | None = None      # ISO-8601 UTC
    model: str | None = None
    msg_count: int = 0
    cwd: str | None = None
    state: str = "idle"                 # idle | working | needs_input | done
    source: str = ""                    # which app it belongs to


@dataclass
class AppStatus:
    key: str
    name: str
    icon: str
    running: bool = False
    detail: str = ""
    model: str | None = None
    version: str | None = None
    session_count: int = 0
    url: str | None = None
    error: str | None = None
    capabilities: list[str] = field(default_factory=list)


# ---------------------------------------------------------------- helpers

RUN = "/usr/bin/systemctl"


def _sh(cmd: list[str], timeout: int = 10) -> tuple[int, str]:
    """اجرای امن یک دستور. هرگز استثنا پرتاب نمی‌کند."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout, stdin=subprocess.DEVNULL)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except Exception as exc:                                   # noqa: BLE001
        return 1, str(exc)


def unit_active(unit: str, user: bool = False) -> bool:
    cmd = [RUN] + (["--user"] if user else []) + ["is-active", "--quiet", unit]
    env_ok = True
    if user:
        os.environ.setdefault("XDG_RUNTIME_DIR", "/run/user/0")
    return env_ok and _sh(cmd, 6)[0] == 0


def http_code(url: str, timeout: float = 4.0, **kw) -> int:
    try:
        r = httpx.get(url, timeout=timeout, follow_redirects=False, **kw)
        return r.status_code
    except Exception:                                          # noqa: BLE001
        return 0


def iso(ts: float | int | None) -> str | None:
    if not ts:
        return None
    try:
        return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat()
    except Exception:                                          # noqa: BLE001
        return None


def _tail_json_lines(path: str, limit: int = 400) -> list[dict]:
    """
    خواندن آخرین خطوط یک فایل jsonl بدون بارکردن کل فایل.
    فایل‌های نشست تا صدها کیلوبایت می‌شوند و این تابع در حلقهٔ polling است.
    """
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            if size > 256_000:
                fh.seek(-256_000, os.SEEK_END)
                fh.readline()                 # خط ناقص اول را دور بینداز
            raw = fh.read().decode("utf-8", "replace")
    except Exception:                                          # noqa: BLE001
        return []
    out = []
    for line in raw.splitlines()[-limit:]:
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except Exception:                                      # noqa: BLE001
            continue
    return out


def _text_of(content: Any) -> str:
    """استخراج متن از شکل‌های مختلف content (رشته، لیست بلوک، دیکشنری)."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for b in content:
            if isinstance(b, dict):
                if b.get("type") == "text" or "text" in b:
                    parts.append(str(b.get("text", "")))
                elif b.get("type") == "tool_use":
                    parts.append(f"[tool: {b.get('name','?')}]")
            elif isinstance(b, str):
                parts.append(b)
        return " ".join(p for p in parts if p)
    if isinstance(content, dict):
        return _text_of(content.get("content") or content.get("text") or "")
    return ""


def _rec_ts(d: dict) -> float | None:
    """
    زمان واقعی یک رکورد jsonl. mtime فایل قابل اعتماد نیست چون یک
    کپی/بازیابی/rsync همهٔ نشست‌ها را «تازه» نشان می‌دهد.
    """
    v = d.get("timestamp") or d.get("time") or d.get("ts")
    if isinstance(v, (int, float)):
        return v / 1000.0 if v > 1e11 else float(v)
    if isinstance(v, str):
        try:
            return datetime.fromisoformat(v.replace("Z", "+00:00")).timestamp()
        except Exception:                                      # noqa: BLE001
            return None
    return None


def _clean(s: str, n: int = 110) -> str:
    s = re.sub(r"\s+", " ", (s or "")).strip()
    return s[:n]


# ================================================================ base


class Adapter:
    key = "base"
    name = "Base"
    icon = "●"
    url: str | None = None
    capabilities: list[str] = []

    def status(self) -> AppStatus:
        return AppStatus(self.key, self.name, self.icon)

    def sessions(self) -> list[Session]:
        return []

    def models(self) -> list[str]:
        return []

    def set_model(self, model: str) -> tuple[bool, str]:
        return False, "not supported"

    def send(self, text: str, session_id: str | None = None) -> tuple[bool, str]:
        return False, "not supported"

    # helper shared by all adapters
    def _safe(self, fn, default):
        try:
            return fn()
        except Exception as exc:                               # noqa: BLE001
            self._last_error = str(exc)[:200]
            return default


# ================================================================ Hermes


class HermesAdapter(Adapter):
    key, name, icon = "hermes", "Hermes", "🤖"
    BASE = "http://127.0.0.1:9120"
    url = "https://linux-server-vps.tail3641f4.ts.net:9443/"
    capabilities = ["status", "sessions", "restart"]

    def status(self) -> AppStatus:
        st = AppStatus(self.key, self.name, self.icon, url=self.url,
                       capabilities=self.capabilities)
        try:
            r = httpx.get(f"{self.BASE}/api/status", timeout=5)
            if r.status_code == 200:
                d = r.json()
                st.running = bool(d.get("gateway_running"))
                st.version = d.get("version")
                gs = d.get("gateway_state", "?")
                st.detail = f"gateway {gs}"
                if d.get("can_update_hermes"):
                    st.detail += " · update available"
            else:
                st.detail = f"api {r.status_code}"
                st.running = unit_active("hermes-dashboard.service")
        except Exception as exc:                               # noqa: BLE001
            st.error = str(exc)[:160]
            st.running = unit_active("hermes-dashboard.service")
            st.detail = "api unreachable"
        st.model = self._config_model()
        st.session_count = len(self.sessions())
        return st

    @staticmethod
    def _config_model() -> str | None:
        """
        /root/.hermes/config.yaml با «model:» در ستون صفر شروع می‌شود و
        زیرکلید model دارد. بدون PyYAML همان بلوک اول را دستی می‌خوانیم تا
        وابستگی اضافه‌ای به سرویس تحمیل نشود. حلقه به محض رسیدن به کلید
        بعدیِ ستون صفر می‌شکند تا مقدار بلوک‌های دیگر برداشته نشود.
        """
        try:
            lines = open(rp("/root/.hermes/config.yaml"),
                         encoding="utf-8", errors="replace").read().splitlines()
        except Exception:                                      # noqa: BLE001
            return None
        inside = False
        for ln in lines[:80]:
            if re.match(r"^model:\s*$", ln):
                inside = True
                continue
            if inside:
                if ln.strip() and not ln.startswith((" ", "\t")):
                    break
                m = re.match(r"""\s+(?:model|name|id):\s*['"]?([^'"#\s]+)""", ln)
                if m:
                    return m.group(1)
        return None

    def sessions(self) -> list[Session]:
        """
        Hermes برای /api/sessions توکن می‌خواهد، ولی CLI محلی آزاد است.
        خروجی جدولی است و باید پارس شود.
        """
        rc, out = _sh(["hermes", "sessions", "list"], timeout=25)
        if rc != 0:
            return []
        rows: list[Session] = []
        for line in out.splitlines():
            # قالب: Title  Preview  LastActive  ID(20260921_174324_330f4b5d)
            m = re.search(r"(\d{8}_\d{6}_[0-9a-f]+)\s*$", line.strip())
            if not m:
                continue
            sid = m.group(1)
            rest = line[: m.start()].rstrip()
            # ستون آخر قبل از ID زمان است
            tm = re.search(r"\s{2,}([a-zA-Z0-9: ]+)$", rest)
            last = tm.group(1).strip() if tm else ""
            head = rest[: tm.start()].strip() if tm else rest
            cols = re.split(r"\s{2,}", head)
            title = cols[0].strip() if cols else ""
            preview = cols[1].strip() if len(cols) > 1 else ""
            if title in ("Title", "—") and not preview:
                title = "(untitled)"
            # تاریخ نسبی را به ISO تبدیل نمی‌کنیم؛ همان متن را می‌دهیم
            rows.append(Session(id=sid, title=_clean(title, 60),
                                preview=_clean(preview), last_active=None,
                                source=self.key))
            # زمان متنی را در preview نگه می‌داریم اگر خالی بود
            if last and not rows[-1].preview:
                rows[-1].preview = last
        return rows


# ================================================================ Claude Code


class ClaudeAdapter(Adapter):
    key, name, icon = "claude", "Claude Code", "💻"
    ROOT = rp("/root/.claude/projects")
    url = "https://linux-server-vps.tail3641f4.ts.net:8443/"
    capabilities = ["status", "sessions", "send", "set_model"]

    def status(self) -> AppStatus:
        st = AppStatus(self.key, self.name, self.icon, url=self.url,
                       capabilities=self.capabilities)
        rc, out = _sh(["claude", "--version"], timeout=10)
        st.running = rc == 0
        st.version = (out.split()[0] if rc == 0 and out.strip() else None)
        st.model = os.environ.get("ANTHROPIC_MODEL") or self._env_model()
        se = self.sessions()
        st.session_count = len(se)
        working = [s for s in se if s.state == "working"]
        st.detail = f"{len(working)} active" if working else "idle"
        return st

    @staticmethod
    def _env_model() -> str | None:
        try:
            txt = open("/etc/profile.d/ai-clients.sh").read()
            m = re.search(r"ANTHROPIC_MODEL=([^\s\"']+)", txt)
            return m.group(1) if m else None
        except Exception:                                      # noqa: BLE001
            return None

    def sessions(self) -> list[Session]:
        out: list[Session] = []
        for f in sorted(glob.glob(f"{self.ROOT}/*/*.jsonl"),
                        key=lambda p: os.path.getmtime(p), reverse=True)[:25]:
            recs = _tail_json_lines(f)
            if not recs:
                continue
            model, last_role, last_text, n = None, None, "", 0
            last_ts: float | None = None
            for d in recs:
                t = d.get("type")
                # cost-state آخرین رکورد هر نشست است و مدل‌های مصرف‌شده را دارد
                if t == "cost-state":
                    mu = d.get("modelUsage") or {}
                    if isinstance(mu, dict) and mu:
                        model = model or next(iter(mu.keys()), None)
                if t in ("user", "assistant"):
                    n += 1
                    last_role = t
                    last_ts = _rec_ts(d) or last_ts
                    msg = d.get("message") or {}
                    if isinstance(msg, dict):
                        if msg.get("model"):
                            model = msg["model"]
                        last_text = _text_of(msg.get("content")) or last_text
            mtime = last_ts or os.path.getmtime(f)
            age = time.time() - mtime
            # اگر آخرین پیام از کاربر باشد یعنی مدل دارد کار می‌کند
            state = "idle"
            if last_role == "user" and age < 300:
                state = "needs_input"
            elif age < 90:
                state = "working"
            out.append(Session(
                id=os.path.basename(f)[:-6],
                title=_clean(os.path.basename(os.path.dirname(f)).strip("-") or "root", 40),
                preview=_clean(last_text),
                last_active=iso(mtime), model=model, msg_count=n,
                cwd=os.path.dirname(f), state=state, source=self.key))
        return out

    def models(self) -> list[str]:
        return list_9router_combos()

    def set_model(self, model: str) -> tuple[bool, str]:
        """مدل پیش‌فرض در فایل محیط مشترک نوشته می‌شود."""
        return set_env_model("ANTHROPIC_MODEL", model)

    def send(self, text: str, session_id: str | None = None) -> tuple[bool, str]:
        model = self._env_model() or "Agentic"
        cmd = ["claude", "-p", text, "--model", model]
        rc, out = _sh(cmd, timeout=180)
        return rc == 0, out[-4000:]


# ================================================================ Pi


class PiAdapter(Adapter):
    key, name, icon = "pi", "Pi", "🥧"
    ROOT = rp("/root/.pi/agent/sessions")
    url = "https://linux-server-vps.tail3641f4.ts.net:9445/"
    capabilities = ["status", "sessions", "send", "set_model"]

    def status(self) -> AppStatus:
        st = AppStatus(self.key, self.name, self.icon, url=self.url,
                       capabilities=self.capabilities)
        rc, out = _sh(["pi", "--version"], timeout=10)
        st.running = rc == 0
        st.version = out.strip().split("\n")[0][:20] if rc == 0 else None
        st.model = self._settings().get("defaultModel")
        st.session_count = len(self.sessions())
        st.detail = "web ui " + ("up" if http_code("http://127.0.0.1:30141/") else "down")
        return st

    @staticmethod
    def _settings() -> dict:
        try:
            return json.load(open(rp("/root/.pi/agent/settings.json")))
        except Exception:                                      # noqa: BLE001
            return {}

    def sessions(self) -> list[Session]:
        out: list[Session] = []
        for f in sorted(glob.glob(f"{self.ROOT}/*/*.jsonl"),
                        key=lambda p: os.path.getmtime(p), reverse=True)[:25]:
            recs = _tail_json_lines(f)
            if not recs:
                continue
            cwd = None
            last_text, n, model = "", 0, None
            last_ts: float | None = None
            last_role: str | None = None
            for d in recs:
                if d.get("cwd"):
                    cwd = d["cwd"]
                t = (d.get("type") or "").lower()
                # ساختار واقعی Pi (تأییدشده روی سرور): خطوط type=message با
                # message.role و message.content، به‌علاوهٔ type=model_change.
                if t == "message":
                    msg = d.get("message") or {}
                    if isinstance(msg, dict) and msg.get("role") in ("user", "assistant"):
                        n += 1
                        last_role = msg["role"]
                        last_ts = _rec_ts(d) or last_ts
                        last_text = _text_of(msg.get("content")) or last_text
                elif t == "model_change":
                    model = d.get("model") or d.get("to") or model
                elif t == "session":
                    cwd = d.get("cwd") or cwd
                if d.get("model") and not model:
                    model = d["model"]
            mtime = last_ts or os.path.getmtime(f)
            age = time.time() - mtime
            # «منتظر پاسخ» یعنی آخرین حرف را کاربر زده و هنوز جوابی نیامده
            if last_role == "user" and age < 300:
                state = "needs_input"
            elif age < 90:
                state = "working"
            else:
                state = "idle"
            out.append(Session(
                id=os.path.basename(f)[:-6],
                title=_clean((cwd or os.path.basename(os.path.dirname(f))).split("/")[-1] or "pi", 40),
                preview=_clean(last_text), last_active=iso(mtime),
                model=model, msg_count=n, cwd=cwd,
                state=state, source=self.key))
        return out

    def models(self) -> list[str]:
        try:
            d = json.load(open(rp("/root/.pi/agent/models.json")))
            provs = d.get("providers") or {}
            ms = (provs.get("ninerouter") or {}).get("models") or []
            out = [m.get("id") for m in ms if isinstance(m, dict) and m.get("id")]
            if out:
                return out
        except Exception:                                      # noqa: BLE001
            pass
        return list_9router_combos()

    def set_model(self, model: str) -> tuple[bool, str]:
        """کلیدهای واقعی settings.json: defaultProvider / defaultModel."""
        path = rp("/root/.pi/agent/settings.json")
        try:
            d = json.load(open(path))
            d["defaultProvider"] = "ninerouter"
            d["defaultModel"] = model
            json.dump(d, open(path, "w"), indent=2)
            return True, f"pi defaultModel = {model}"
        except Exception as exc:                               # noqa: BLE001
            return False, str(exc)

    def send(self, text: str, session_id: str | None = None) -> tuple[bool, str]:
        s = self._settings()
        cmd = ["pi", "-p", text,
               "--provider", s.get("defaultProvider", "ninerouter"),
               "--model", s.get("defaultModel", "Agentic"),
               "--thinking", "off"]
        rc, out = _sh(cmd, timeout=180)
        return rc == 0, out[-4000:]


# ================================================================ OpenClaw


class OpenClawAdapter(Adapter):
    key, name, icon = "openclaw", "OpenClaw", "🐾"
    DB = rp("/root/.openclaw/agents/main/agent/openclaw-agent.sqlite")
    CFG = rp("/root/.openclaw/openclaw.json")
    url = "https://linux-server-vps.tail3641f4.ts.net/"
    # REST ندارد ⇒ خواندن از دیتابیس، نوشتن از CLI (تصمیم ۵-ج)
    capabilities = ["status", "sessions", "set_model", "restart"]

    def status(self) -> AppStatus:
        st = AppStatus(self.key, self.name, self.icon, url=self.url,
                       capabilities=self.capabilities)
        code = http_code("http://127.0.0.1:18789/health")
        st.running = code == 200
        st.detail = "healthy" if st.running else f"health {code}"
        st.model = self.current_model()
        rc, out = _sh(["openclaw", "--version"], timeout=10)
        if rc == 0:
            st.version = out.strip().split("\n")[0][:24]
        st.session_count = len(self.sessions())
        return st

    def _cfg(self) -> dict:
        try:
            return json.load(open(self.CFG))
        except Exception:                                      # noqa: BLE001
            return {}

    def sessions(self) -> list[Session]:
        """
        نکتهٔ مهم (تأییدشده روی سرور): جدول session_conversations صفر ردیف
        دارد. نشست‌های واقعی در session_nodes هستند و محتوای مفید داخل
        entry_json است. عنوان را از session_key می‌سازیم:
            agent:main:dashboard:<uuid>  ->  dashboard
        """
        out: list[Session] = []
        try:
            con = sqlite3.connect(f"file:{self.DB}?mode=ro", uri=True, timeout=5)
            con.row_factory = sqlite3.Row
            tables = {r[0] for r in con.execute(
                "select name from sqlite_master where type='table'")}
            if "session_nodes" not in tables:
                return []
            rows = con.execute(
                "select session_key, current_session_id, entry_json, status,"
                " updated_at, created_via from session_nodes"
                " order by updated_at desc limit 20")
            for r in rows:
                d = dict(r)
                key = str(d.get("session_key") or "")
                parts = key.split(":")
                kind = parts[2] if len(parts) > 2 else "session"
                entry = {}
                try:
                    entry = json.loads(d.get("entry_json") or "{}")
                except Exception:                              # noqa: BLE001
                    pass
                ts = d.get("updated_at")
                if isinstance(ts, (int, float)) and ts > 1e11:
                    ts = ts / 1000.0
                elif isinstance(ts, str):
                    try:
                        ts = datetime.fromisoformat(
                            ts.replace("Z", "+00:00")).timestamp()
                    except Exception:                          # noqa: BLE001
                        ts = None
                status = (d.get("status") or "").lower()
                out.append(Session(
                    id=str(d.get("current_session_id") or key)[:36],
                    title=_clean(kind, 40),
                    preview=_clean(str(entry.get("title")
                                       or d.get("created_via") or ""), 90),
                    last_active=iso(ts) if isinstance(ts, (int, float)) else None,
                    state="working" if status in ("active", "running") else "idle",
                    source=self.key))
        except Exception:                                      # noqa: BLE001
            return out
        return out

    def models(self) -> list[str]:
        """مسیر واقعی: models.providers.ninerouter.models[].id"""
        cfg = self._cfg()
        try:
            ms = (((cfg.get("models") or {}).get("providers") or {})
                  .get("ninerouter") or {}).get("models") or []
            out = [m.get("id") for m in ms if isinstance(m, dict) and m.get("id")]
            if out:
                return out
        except Exception:                                      # noqa: BLE001
            pass
        return list_9router_combos()

    def current_model(self) -> str | None:
        """مسیر واقعی: agents.defaults.model = 'ninerouter/Agentic'"""
        try:
            m = ((self._cfg().get("agents") or {})
                 .get("defaults") or {}).get("model")
            return str(m).split("/")[-1] if m else None
        except Exception:                                      # noqa: BLE001
            return None

    def set_model(self, model: str) -> tuple[bool, str]:
        """
        در agents.defaults.model می‌نویسیم (مسیر تأییدشده روی سرور).
        فایل کامل خوانده و بازنویسی می‌شود تا هیچ کلید دیگری گم نشود.
        """
        try:
            cfg = json.load(open(self.CFG))
            cfg.setdefault("agents", {}).setdefault("defaults", {})["model"] = \
                f"ninerouter/{model}"
            tmp = self.CFG + ".tmp"
            with open(tmp, "w") as fh:
                json.dump(cfg, fh, indent=2, ensure_ascii=False)
            os.replace(tmp, self.CFG)
            return True, f"openclaw model = ninerouter/{model} (restart to apply)"
        except Exception as exc:                               # noqa: BLE001
            return False, str(exc)

# ================================================================ 9Router


class RouterAdapter(Adapter):
    key, name, icon = "router", "9Router", "🔀"
    DB = rp("/root/.9router/db/data.sqlite")
    url = "https://linux-server-vps.tail3641f4.ts.net:9444/"
    capabilities = ["status", "usage", "combos"]

    def status(self) -> AppStatus:
        st = AppStatus(self.key, self.name, self.icon, url=self.url,
                       capabilities=self.capabilities)
        code = http_code("http://127.0.0.1:20128/")
        st.running = code in (200, 301, 302, 307, 401, 403)
        st.detail = f"http {code}"
        rc, out = _sh(["9router", "--version"], timeout=8)
        if rc == 0:
            st.version = out.strip()[:16]
        u = self.usage_today()
        st.session_count = u.get("requests", 0)
        return st

    def _con(self):
        return sqlite3.connect(f"file:{self.DB}?mode=ro", uri=True, timeout=5)

    def usage_today(self) -> dict:
        try:
            con = self._con()
            key = datetime.now(timezone.utc).strftime("%Y-%m-%d")
            row = list(con.execute(
                "select data from usageDaily where dateKey=?", (key,)))
            if row:
                d = json.loads(row[0][0])
                return {"requests": d.get("requests", 0),
                        "prompt": d.get("promptTokens", 0),
                        "completion": d.get("completionTokens", 0),
                        "cost": round(d.get("cost", 0.0), 4),
                        "byProvider": d.get("byProvider", {})}
        except Exception:                                      # noqa: BLE001
            pass
        return {"requests": 0, "prompt": 0, "completion": 0, "cost": 0.0}

    def usage_series(self, days: int = 7) -> list[dict]:
        out = []
        try:
            con = self._con()
            for k, data in con.execute(
                    "select dateKey,data from usageDaily order by dateKey desc limit ?",
                    (days,)):
                try:
                    d = json.loads(data)
                except Exception:                              # noqa: BLE001
                    continue
                out.append({"date": k, "requests": d.get("requests", 0),
                            "tokens": d.get("promptTokens", 0) + d.get("completionTokens", 0),
                            "cost": round(d.get("cost", 0.0), 4)})
        except Exception:                                      # noqa: BLE001
            pass
        return list(reversed(out))

    def recent_requests(self, limit: int = 25) -> list[dict]:
        out = []
        try:
            con = self._con()
            con.row_factory = sqlite3.Row
            for r in con.execute(
                    "select timestamp,model,endpoint,promptTokens,completionTokens,"
                    "cost,status from usageHistory order by id desc limit ?", (limit,)):
                d = dict(r)
                d["cost"] = round(d.get("cost") or 0, 6)
                out.append(d)
        except Exception:                                      # noqa: BLE001
            pass
        return out

    def combos(self) -> list[dict]:
        """
        جدول combos در نسخه‌های مختلف 9router ستون‌های متفاوتی دارد
        (models / data / config). به‌جای حدس‌زدن، schema را می‌خوانیم و
        هر ستون متنی‌ای که JSON باشد را برای شمردن مدل‌ها امتحان می‌کنیم.
        این‌طور ارتقای 9router پنل را نمی‌شکند.
        """
        out = []
        try:
            con = self._con()
            cols = [r[1] for r in con.execute("pragma table_info(combos)")]
            if "name" not in cols:
                return []
            for row in con.execute(
                    f"select {','.join(cols)} from combos order by name"):
                d = dict(zip(cols, row))
                models: list = []
                for c in ("models", "data", "config", "payload"):
                    raw = d.get(c)
                    if not isinstance(raw, str):
                        continue
                    try:
                        j = json.loads(raw)
                    except Exception:                          # noqa: BLE001
                        continue
                    if isinstance(j, list):
                        models = j
                    elif isinstance(j, dict):
                        models = (j.get("models") or j.get("targets")
                                  or j.get("providers") or [])
                    if models:
                        break
                out.append({"name": d["name"], "count": len(models),
                            "models": [str(m)[:60] for m in models[:12]]})
        except Exception:                                      # noqa: BLE001
            pass
        return out


# ================================================================ shared utils


def list_9router_combos() -> list[str]:
    try:
        con = sqlite3.connect(f"file:{rp('/root/.9router/db/data.sqlite')}?mode=ro",
                              uri=True, timeout=5)
        return [r[0] for r in con.execute("select name from combos order by name") if r[0]]
    except Exception:                                          # noqa: BLE001
        return []


def set_env_model(var: str, model: str) -> tuple[bool, str]:
    """
    به‌روزرسانی یک متغیر در /etc/profile.d/ai-clients.sh.
    این فایل منبع مشترک همهٔ CLIهاست، پس تغییرش روی همه اثر می‌گذارد.
    """
    path = "/etc/profile.d/ai-clients.sh"
    try:
        txt = open(path).read()
        if re.search(rf"^export {var}=.*$", txt, re.M):
            txt = re.sub(rf"^export {var}=.*$", f"export {var}={model}", txt, flags=re.M)
        elif re.search(rf"^{var}=.*$", txt, re.M):
            txt = re.sub(rf"^{var}=.*$", f"{var}={model}", txt, flags=re.M)
        else:
            txt += f"\nexport {var}={model}\n"
        open(path, "w").write(txt)
        return True, f"{var}={model}"
    except Exception as exc:                                   # noqa: BLE001
        return False, str(exc)


ADAPTERS: dict[str, Adapter] = {
    a.key: a for a in (HermesAdapter(), ClaudeAdapter(), PiAdapter(),
                       OpenClawAdapter(), RouterAdapter())
}

__all__ = ["ADAPTERS", "Session", "AppStatus", "asdict", "list_9router_combos",
           "unit_active", "http_code", "_sh"]
