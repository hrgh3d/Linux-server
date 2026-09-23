"""
catalog.py — «چه مدل‌هایی را می‌شود به این ایجنت داد؟»

تصحیح مهم نسبت به برداشت اولیه: کاربر **همهٔ ۱۵۲۷ مدل 9router را نمی‌خواهد**.
از 9router فقط **کامبوها** لازم است؛ بقیهٔ گزینه‌ها باید مدل‌های بومیِ خود
هر برنامه باشند — چیزی که خود Pi / OpenClaw / Hermes / Claude می‌شناسند.

آنچه روی سرور واقعاً پیدا شد (منبع این ماژول):

  Hermes   `custom_providers:` در config.yaml یک provider به نام «Railway»
           دارد با ~۵۰ مدلِ صریح (کامبوها + gemini/* + cf/* + cl/*).
           این فهرست بومیِ خود هرمس است.
  OpenClaw `openclaw models list` کاتالوگ خودش را می‌دهد؛ ورودی‌های
           configured با تگ مشخص‌اند. حالت کاتالوگ merge است یعنی
           built-inها + providerهای سفارشی.
  Pi       `models.json > providers` و `settings.json > enabledModels`.
           پرچم `--provider` پیش‌فرضش google است، ولی auth.json خالی است
           پس عملاً فقط ninerouter اعتبار دارد — و همین را صادقانه
           می‌گوییم به‌جای اینکه فهرستی بدهیم که کار نمی‌کند.
  Claude   نام‌های مستعار بومی (`opus`, `sonnet`, `fable`, …) به‌علاوهٔ
           هر چیزی که از راه ANTHROPIC_MODEL ست شده.
"""

from __future__ import annotations

import json
import re
import sqlite3
import time
from typing import Any

from .adapters import ADAPTERS, _sh, rp

_CACHE: dict[str, tuple[float, Any]] = {}
TTL = 120.0


def _cached(k: str, fn, ttl: float = TTL):
    hit = _CACHE.get(k)
    if hit and time.time() - hit[0] < ttl:
        return hit[1]
    v = fn()
    _CACHE[k] = (time.time(), v)
    return v


def invalidate() -> None:
    _CACHE.clear()


# ───────────────────────────────────────────── 9router: فقط کامبوها


def combos() -> list[dict]:
    """
    فقط ۶ کامبو — نه ۱۵۲۷ مدل خام. کامبو یعنی «روتر خودش بین چند مدل
    انتخاب کند»، و این تنها چیزی است که کاربر از 9router می‌خواهد.
    """
    def build() -> list[dict]:
        out: list[dict] = []
        try:
            con = sqlite3.connect(
                f"file:{rp('/root/.9router/db/data.sqlite')}?mode=ro",
                uri=True, timeout=5)
            con.row_factory = sqlite3.Row
            for r in con.execute("select name, models from combos order by name"):
                try:
                    n = len(json.loads(r["models"] or "[]"))
                except Exception:                              # noqa: BLE001
                    n = 0
                out.append({"id": r["name"], "members": n, "kind": "combo"})
            con.close()
        except Exception:                                      # noqa: BLE001
            pass
        return out
    return _cached("combos", build)


# ───────────────────────────────────────────── کاتالوگ بومی هر ایجنت


def _hermes_native() -> list[dict]:
    """
    بلوک `custom_providers:` در config.yaml. YAML را دستی می‌خوانیم چون
    فایل ۱۸۰۰ خط است و آوردن یک وابستگی فقط برای همین بلوک منطقی نیست.
    ساختار:
        custom_providers:
          - name: Railway
            models:
              Agentic: {}
              gemini/gemini-3.8-flash: {}
    """
    out: list[dict] = []
    try:
        lines = open(rp("/root/.hermes/config.yaml"), encoding="utf-8").read().splitlines()
    except Exception:                                          # noqa: BLE001
        return out
    inside = provider = None
    in_models = False
    for ln in lines:
        if re.match(r"^custom_providers:\s*$", ln):
            inside = True
            continue
        if inside is None:
            continue
        if ln.strip() and not ln[0].isspace():
            break                                   # بلوک تمام شد
        m = re.match(r"^\s+-\s+name:\s*(\S+)", ln)
        if m:
            provider = m.group(1)
            in_models = False
            continue
        if re.match(r"^\s+models:\s*$", ln):
            in_models = True
            continue
        if in_models:
            m = re.match(r"^\s{6,}([^\s:]+):\s*\{?\}?\s*$", ln)
            if m:
                out.append({"id": m.group(1), "provider": provider or "custom"})
            elif ln.strip() and not re.match(r"^\s{6,}", ln):
                in_models = False
    return out


def _openclaw_native() -> list[dict]:
    """`openclaw models list` — کاتالوگ خود اوپن‌کلاو."""
    rc, out = _sh(["openclaw", "models", "list"], timeout=45)
    if rc != 0:
        return []
    res: list[dict] = []
    for ln in out.splitlines():
        ln = ln.rstrip()
        if not ln or ln.lstrip().startswith(("Model", "-", "=")):
            continue
        mid = ln.split()[0] if ln.split() else ""
        if "/" not in mid and mid not in {c["id"] for c in combos()}:
            continue
        prov = mid.split("/", 1)[0] if "/" in mid else "builtin"
        res.append({"id": mid, "provider": prov,
                    "configured": "configured" in ln})
    return res


def _pi_auth() -> set[str]:
    """کدام providerهای Pi اعتبارنامه دارند. auth.json خالی = هیچ‌کدام."""
    try:
        d = json.load(open(rp("/root/.pi/agent/auth.json")))
        return {k for k in d} if isinstance(d, dict) else set()
    except Exception:                                          # noqa: BLE001
        return set()


def _pi_native() -> list[dict]:
    """
    دو منبع برای Pi:

      models.json        providerهای *پیکربندی‌شده* (اینجا فقط ninerouter
                         با همان ۶ کامبو — که چون کامبواند جدا نشان داده
                         می‌شوند و اینجا تکرار نمی‌شوند)
      models-store.json  کاتالوگ بومیِ خود Pi که با `pi update --models`
                         تازه می‌شود: anthropic (۱۵) و openai (۴۱).

    نکتهٔ صادقانه: `auth.json` روی این سرور **خالی** است، یعنی برای
    anthropic/openai هیچ کلیدی ثبت نشده. مدل‌ها را نشان می‌دهیم چون خود Pi
    می‌شناسدشان، ولی با پرچم needs_key تا کاربر انتظار نداشته باشد بدون
    کلید کار کنند.
    """
    out: list[dict] = []
    have = _pi_auth()

    try:
        d = json.load(open(rp("/root/.pi/agent/models.json")))
        for prov, v in (d.get("providers") or {}).items():
            for m in (v.get("models") or []):
                if isinstance(m, dict) and m.get("id"):
                    out.append({"id": m["id"], "provider": prov})
    except Exception:                                          # noqa: BLE001
        pass

    try:
        store_ = json.load(open(rp("/root/.pi/agent/models-store.json")))
        for prov, v in (store_ or {}).items():
            if not isinstance(v, dict):
                continue
            for m in (v.get("models") or []):
                mid = m.get("id") if isinstance(m, dict) else m
                if not mid:
                    continue
                out.append({"id": f"{prov}/{mid}", "provider": prov,
                            "needs_key": prov not in have})
    except Exception:                                          # noqa: BLE001
        pass

    seen, uniq = set(), []
    for m in out:
        if m["id"] in seen:
            continue
        seen.add(m["id"])
        uniq.append(m)
    return uniq


# نام‌های مستعار بومی Claude Code (از `claude --help`).
# مدل واقعی پشت اینها را Anthropic تعیین می‌کند، نه ما.
CLAUDE_ALIASES = ["opus", "sonnet", "haiku", "fable"]


def _claude_native() -> list[dict]:
    return [{"id": a, "provider": "anthropic", "alias": True}
            for a in CLAUDE_ALIASES]


NATIVE = {
    "hermes": _hermes_native,
    "openclaw": _openclaw_native,
    "pi": _pi_native,
    "claude": _claude_native,
}


def native(agent: str) -> list[dict]:
    fn = NATIVE.get(agent)
    if not fn:
        return []
    return _cached(f"native:{agent}", fn)


def for_agent(agent: str) -> dict:
    """
    کاتالوگ کامل یک ایجنت، در دو گروه:
      combos — مسیریابی خودکار 9router (۶ تا)
      native — مدل‌هایی که خود این برنامه می‌شناسد
    """
    ad = ADAPTERS.get(agent)
    cur = None
    if ad:
        try:
            cur = ad.status().model
        except Exception:                                      # noqa: BLE001
            cur = None

    nat = native(agent)
    combo_ids = {c["id"] for c in combos()}
    # کامبوها را از فهرست بومی جدا کن تا دوبار نیایند
    nat = [m for m in nat if m["id"] not in combo_ids]

    groups: dict[str, list[dict]] = {}
    for m in nat:
        groups.setdefault(m.get("provider") or "other", []).append(m)

    return {
        "agent": agent,
        "current": cur,
        "combos": combos(),
        "native_groups": [
            {"provider": p, "count": len(ms),
             "models": sorted(ms, key=lambda x: x["id"])}
            for p, ms in sorted(groups.items(), key=lambda kv: -len(kv[1]))],
        "native_total": len(nat),
        "supports_switch": bool(ad and "set_model" in ad.capabilities),
    }


def all_agents() -> dict:
    return {k: for_agent(k) for k in NATIVE}
