"""
Model Resolver — «پشت این کامبو الان واقعاً کدام مدل کار می‌کند؟»

پس‌زمینهٔ واقعی (تأییدشده با پروب زنده روی سرور):
  * `usageHistory.model` نام **مدل واقعی** را دارد، نه نام کامبو:
        gemini-3.6-flash · deepseek-v4.1-flash:free · qwen/qwen3.8-max:free
  * `combos.models` فهرست اعضای هر کامبو را دارد، با پیشوند ارائه‌دهنده:
        Agentic -> ["gemini/gemini-3.6-flash", "openrouter/deepseek/…", …]
  * جدول `requestDetails` **صفر ردیف** دارد ⇒ هیچ لینک قطعی
    درخواست↔نشست وجود ندارد.

پس انتساب **استنتاجی** است: از روی عضویت مدل در کامبو. وقتی یک مدل فقط
عضو یک کامبو باشد، انتساب قطعی است؛ وقتی در چند کامبو مشترک باشد،
مبهم است و همین را هم صادقانه به UI گزارش می‌کنیم (`exact=False`).
هرگز حدس را به‌جای واقعیت جا نمی‌زنیم.
"""
from __future__ import annotations

import json
import sqlite3
import time
from datetime import datetime, timezone
from typing import Any

from .adapters import rp

DB = rp("/root/.9router/db/data.sqlite")


def _con() -> sqlite3.Connection:
    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=5)
    con.row_factory = sqlite3.Row
    return con


def _bare(m: str) -> str:
    """
    'openrouter/deepseek/deepseek-v4-flash-0731' -> 'deepseek-v4-flash-0731'
    'gemini/gemini-3.6-flash'                    -> 'gemini-3.6-flash'
    'cf/@cf/qwen/qwen2.5-coder-32b-instruct'     -> 'qwen2.5-coder-32b-instruct'
    پسوند ':free' حذف می‌شود تا 'x:free' و 'x' یکی شمرده شوند.
    """
    s = (m or "").strip()
    if ":" in s:
        s = s.split(":", 1)[0]
    return s.rsplit("/", 1)[-1].lower()


def combo_members() -> dict[str, list[str]]:
    """نام کامبو -> فهرست مدل‌های عضو (همان‌طور که 9router ذخیره کرده)."""
    out: dict[str, list[str]] = {}
    try:
        con = _con()
        cols = [r[1] for r in con.execute("pragma table_info(combos)")]
        if "name" not in cols:
            return {}
        for row in con.execute(f"select {','.join(cols)} from combos"):
            d = dict(zip(cols, row))
            ms: list = []
            for c in ("models", "data", "config"):
                raw = d.get(c)
                if not isinstance(raw, str):
                    continue
                try:
                    j = json.loads(raw)
                except Exception:                              # noqa: BLE001
                    continue
                if isinstance(j, list):
                    ms = j
                elif isinstance(j, dict):
                    ms = j.get("models") or j.get("targets") or []
                if ms:
                    break
            out[d["name"]] = [str(m) for m in ms]
    except Exception:                                          # noqa: BLE001
        return out
    return out


def _index() -> dict[str, list[str]]:
    """
    مدل ساده‌شده -> کامبوهایی که عضوش هستند.

    نکتهٔ مهم: یک کامبو می‌تواند یک مدل را از دو ارائه‌دهنده داشته باشد؛
    مثلاً Brain هم 'cl/deepseek/deepseek-v4.1-flash' دارد و هم
    'tkbr/deepseek-v4.1-flash:free' که هر دو به یک نام ساده می‌رسند.
    بدون یکتاسازی، کامبو دوبار شمرده می‌شد و انتساب قطعی را به‌غلط
    «مبهم» نشان می‌داد. پس هر کامبو فقط یک‌بار ثبت می‌شود.
    """
    idx: dict[str, list[str]] = {}
    for combo, ms in combo_members().items():
        for m in ms:
            owners = idx.setdefault(_bare(m), [])
            if combo not in owners:
                owners.append(combo)
    return idx


def recent(limit: int = 60) -> list[dict]:
    out = []
    try:
        con = _con()
        for r in con.execute(
                "select id,timestamp,provider,model,promptTokens,"
                "completionTokens,cost,status from usageHistory"
                " order by id desc limit ?", (limit,)):
            out.append(dict(r))
    except Exception:                                          # noqa: BLE001
        pass
    return out


def _ts(v: Any) -> float | None:
    """
    ستون timestamp در usageHistory همیشه عدد نیست؛ رشتهٔ ISO هم دیده می‌شود.
    هر سه حالت را می‌پذیریم وگرنه «چند ثانیه پیش» همیشه خالی می‌ماند.
    """
    if isinstance(v, bool) or v is None:
        return None
    if isinstance(v, (int, float)):
        return v / 1000.0 if v > 1e11 else float(v)
    s = str(v).strip()
    if not s:
        return None
    if s.replace(".", "", 1).isdigit():                  # عدد در قالب رشته
        f = float(s)
        return f / 1000.0 if f > 1e11 else f
    try:                                                 # ISO-8601
        t = s.replace("Z", "+00:00")
        d = datetime.fromisoformat(t)
        if d.tzinfo is None:
            d = d.replace(tzinfo=timezone.utc)
        return d.timestamp()
    except Exception:                                    # noqa: BLE001
        return None


def live() -> dict[str, Any]:
    """
    برای هر کامبو: آخرین مدل واقعی که از طریقش صدا زده شده + آمار امروز.

    خروجی هر کامبو:
      current   نام مدل واقعیِ آخرین درخواست (یا None)
      exact     True اگر آن مدل فقط عضو همین کامبو باشد
      age_s     چند ثانیه از آن درخواست گذشته
      members   شمار اعضا
      breakdown سهم هر مدل از درخواست‌های اخیر همین کامبو
    """
    idx = _index()
    members = combo_members()
    rows = recent(140)
    nowt = time.time()

    per: dict[str, dict] = {
        c: {"combo": c, "members": len(ms), "current": None, "exact": None,
            "age_s": None, "provider": None, "breakdown": {}, "requests": 0,
            "cost": 0.0}
        for c, ms in members.items()}

    for r in rows:
        bare = _bare(r.get("model") or "")
        owners = idx.get(bare, [])
        if not owners:
            continue
        exact = len(owners) == 1
        for c in owners:
            p = per.get(c)
            if p is None:
                continue
            p["breakdown"][r["model"]] = p["breakdown"].get(r["model"], 0) + 1
            p["requests"] += 1
            p["cost"] = round(p["cost"] + (r.get("cost") or 0), 6)
            if p["current"] is None:                 # اولین = جدیدترین
                p["current"] = r.get("model")
                p["provider"] = r.get("provider")
                p["exact"] = exact
                t = _ts(r.get("timestamp"))
                p["age_s"] = int(nowt - t) if t else None

    for p in per.values():
        p["breakdown"] = sorted(
            ({"model": k, "n": v} for k, v in p["breakdown"].items()),
            key=lambda x: -x["n"])[:8]
    return per


def for_combo(name: str) -> dict:
    return live().get(name, {"combo": name, "current": None, "members": 0,
                             "exact": False, "breakdown": []})


def member_detail(name: str) -> list[dict]:
    """
    فهرست کامل اعضای یک کامبو + اینکه هر عضو اخیراً چند بار و با چه
    نرخ موفقیتی استفاده شده. این همان چیزی است که با کلیک روی pill مدل
    باز می‌شود.
    """
    ms = combo_members().get(name, [])
    rows = recent(300)
    stat: dict[str, dict] = {}
    for r in rows:
        b = _bare(r.get("model") or "")
        s = stat.setdefault(b, {"n": 0, "ok": 0, "cost": 0.0, "last": None})
        s["n"] += 1
        if str(r.get("status") or "").lower() in ("ok", "success", "200"):
            s["ok"] += 1
        s["cost"] = round(s["cost"] + (r.get("cost") or 0), 6)
        if s["last"] is None:
            s["last"] = _ts(r.get("timestamp"))
    out = []
    nowt = time.time()
    for m in ms:
        b = _bare(m)
        s = stat.get(b)
        out.append({
            "model": m,
            "short": b,
            "used": s["n"] if s else 0,
            "ok_rate": round(100 * s["ok"] / s["n"]) if s and s["n"] else None,
            "cost": s["cost"] if s else 0.0,
            "age_s": int(nowt - s["last"]) if s and s["last"] else None,
        })
    out.sort(key=lambda x: (-(x["used"] or 0), x["short"]))
    return out


def agent_live_model(combo: str | None) -> dict:
    """آنچه کنار نام ایجنت نشان داده می‌شود: کامبو + مدل واقعی پشتش."""
    if not combo:
        return {"combo": None, "real": None, "exact": False}
    p = for_combo(combo)
    return {"combo": combo, "real": p.get("current"), "exact": p.get("exact"),
            "age_s": p.get("age_s"), "members": p.get("members"),
            "provider": p.get("provider")}
