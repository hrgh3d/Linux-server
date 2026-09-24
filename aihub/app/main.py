"""
AI Hub — مرکز فرماندهی همهٔ برنامه‌های هوش مصنوعی روی این سرور.

فلسفهٔ طراحی:
  * این سرویس **روی** پنل‌های موجود می‌نشیند و جایگزینشان نمی‌شود.
    اگر AI Hub بیفتد، هیچ‌کدام از Hermes/CloudCLI/PiWeb/OpenClaw آسیب نمی‌بینند.
  * هر آداپتور ایزوله است؛ خرابی یکی بقیه را زمین نمی‌زند.
  * کارهای خطرناک (restart/stop/kill) در سمت سرور هم علامت‌گذاری شده‌اند
    تا UI بتواند دیالوگ تأیید نشان دهد.
"""
from __future__ import annotations

import asyncio
import uuid
from datetime import datetime, timezone
import hashlib
import json
import os
import re
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict
from pathlib import Path
from typing import Any

from fastapi import Body, FastAPI, HTTPException, Query
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from .adapters import (ADAPTERS, rp, RouterAdapter, _sh, list_9router_combos,
                       set_env_model, unit_active)
from . import catalog, store, resolver, orchestra

APP_DIR = Path(__file__).resolve().parent
STATIC = APP_DIR.parent / "static"
VERSION = "2.0.0"

app = FastAPI(title="AI Hub", version=VERSION, docs_url="/api/docs")

# استخر نخ: آداپتورها I/O مسدودکننده دارند (subprocess, sqlite, http).
# بدون این، یک `hermes sessions list` کند کل event loop را قفل می‌کند.
JUNK_RE = re.compile(
    r"^(test|تست|ping|pong|hi|hello|سلام|reply with exactly|بگو فقط|say |echo |"
    r"OK_|COMBO_|PI_|CLAUDE_)", re.I)

POOL = ThreadPoolExecutor(max_workers=8, thread_name_prefix="adapter")

# کش کوتاه‌مدت تا polling موبایل سرور را خفه نکند
_CACHE: dict[str, tuple[float, Any]] = {}
CACHE_TTL = 4.0


async def cached(key: str, fn, ttl: float = CACHE_TTL):
    now = time.time()
    hit = _CACHE.get(key)
    if hit and now - hit[0] < ttl:
        return hit[1]
    loop = asyncio.get_running_loop()
    val = await loop.run_in_executor(POOL, fn)
    _CACHE[key] = (now, val)
    return val


def invalidate(prefix: str = "") -> None:
    for k in list(_CACHE):
        if not prefix or k.startswith(prefix):
            _CACHE.pop(k, None)


# --------------------------------------------------------------- models


class SendBody(BaseModel):
    app: str
    text: str
    session_id: str | None = None
    project_id: str | None = None   # نشست تازه را همان‌جا به پروژه ببند


class ModelBody(BaseModel):
    app: str            # یا "all" برای تعویض دسته‌جمعی
    model: str


class ServiceBody(BaseModel):
    unit: str
    action: str         # restart | stop | start


class CompareBody(BaseModel):
    text: str
    models: list[str]


class ScheduleBody(BaseModel):
    name: str
    app: str
    text: str
    cron: str


# --------------------------------------------------------------- overview


@app.get("/api/overview")
async def overview():
    """همهٔ برنامه‌ها + مصرف امروز در یک درخواست — قلب مرحلهٔ ۱."""
    def build():
        apps = []
        for key, ad in ADAPTERS.items():
            try:
                apps.append(asdict(ad.status()))
            except Exception as exc:                           # noqa: BLE001
                apps.append({"key": key, "name": ad.name, "icon": ad.icon,
                             "running": False, "error": str(exc)[:160],
                             "detail": "adapter failed", "capabilities": []})
        r = RouterAdapter()
        return {"apps": apps,
                "usage": r.usage_today(),
                "series": r.usage_series(7),
                "combos": r.combos(),
                "ts": time.time(), "version": VERSION}
    return await cached("overview", build)


def _iso(ts) -> str | None:
    """timestamp عددی را به همان قالب ISO نشست‌های واقعی تبدیل کن."""
    if ts is None:
        return None
    if isinstance(ts, str):
        return ts
    try:
        return datetime.fromtimestamp(float(ts), tz=timezone.utc)\
            .isoformat(timespec="seconds").replace("+00:00", "Z")
    except Exception:                                          # noqa: BLE001
        return None


@app.get("/api/sessions")
async def sessions(app_key: str | None = Query(None, alias="app"),
                   include_archived: bool = False):
    """نشست‌های همهٔ برنامه‌ها، مرتب‌شده بر اساس آخرین فعالیت."""
    def build():
        """فقط خواندنِ گرانِ نشست‌ها از خود ایجنت‌ها کش می‌شود."""
        out = []
        targets = ([ADAPTERS[app_key]] if app_key and app_key in ADAPTERS
                   else list(ADAPTERS.values()))
        for ad in targets:
            try:
                out.extend(asdict(s) for s in ad.sessions())
            except Exception:                                  # noqa: BLE001
                continue
        return out

    raw = await cached(f"sessions:{app_key or 'all'}:raw", build)
    out = [dict(s) for s in raw]     # کپی، وگرنه merge کشِ خام را آلوده می‌کند

    def finish(out):
        # متادیتای دلخواه کاربر روی نشست واقعی سوار می‌شود. نام اصلی در
        # real_title نگه داشته می‌شود تا هیچ اطلاعاتی گم نشود.
        meta = store.meta_all()
        for s in out:
            m = meta.get(f"{s['source']}:{s['id']}")
            if not m:
                continue
            s["real_title"] = s.get("title")
            if m.get("title"):
                s["title"] = m["title"]
            for k in ("icon", "color", "note"):
                if m.get(k):
                    s[k] = m[k]
            s["pinned"] = bool(m.get("pinned"))
            s["archived"] = bool(m.get("archived"))
            s["tags"] = [t for t in (m.get("tags") or "").split(",") if t]
            s["project_id"] = m.get("project_id") or None
        # پیوند به پروژه‌ای که دیگر وجود ندارد را بی‌صدا رها کن، وگرنه
        # نشست نه در «کلی» دیده می‌شود نه زیر هیچ پروژه‌ای — گم می‌شود.
        alive = {p["id"] for p in store.proj_list()}
        for s in out:
            if s.get("project_id") and s["project_id"] not in alive:
                s["project_id"] = None

        # نشست‌های «پیش‌نویس»: با دکمهٔ ＋ ساخته شده‌اند ولی هنوز پیامی
        # نگرفته‌اند، پس روی دیسکِ خود ایجنت وجود ندارند و در خروجی
        # آداپتور نمی‌آیند. اگر اضافه‌شان نکنیم، ＋ انگار هیچ کاری نمی‌کند.
        have = {f"{s['source']}:{s['id']}" for s in out}
        # ردیف متادیتایی که نشست واقعی‌اش دیگر وجود ندارد و پیش‌نویس هم
        # نیست، یک «نشست روح» است: در پنل دیده می‌شود ولی هیچ‌جا نیست.
        # پاکش کن تا فهرست با واقعیتِ روی دیسک یکی بماند.
        for key, m in list(meta.items()):
            if key in have or m.get("draft"):
                continue
            akey, _, dead = key.partition(":")
            if akey in ADAPTERS:
                store.meta_del(akey, dead)
        for key, m in meta.items():
            if not m.get("draft") or key in have:
                continue
            akey, _, sid = key.partition(":")
            if akey not in ADAPTERS:
                continue
            if app_key and akey != app_key:
                continue
            pid = m.get("project_id") or None
            if pid and pid not in alive:
                pid = None
            out.append({
                "id": sid, "source": akey, "title": m.get("title") or "New chat",
                "real_title": None, "preview": "", "msg_count": 0,
                # هم‌قالب با نشست‌های واقعی (ISO). قبلاً float بود و
                # مرتب‌سازی با «'<' not supported between float and str»
                # کل /api/sessions را ۵۰۰ می‌کرد.
                "last_active": _iso(m.get("updated_at")), "state": "draft",
                "draft": True, "project_id": pid,
                "pinned": bool(m.get("pinned")), "archived": bool(m.get("archived")),
                "tags": [t for t in (m.get("tags") or "").split(",") if t],
            })
        if not include_archived:
            out = [s for s in out if not s.get("archived")]
        out.sort(key=lambda s: (not s.get("pinned"),
                                "" if s.get("pinned") else
                                (s.get("last_active") or "")), reverse=False)
        pinned = [s for s in out if s.get("pinned")]
        rest = sorted([s for s in out if not s.get("pinned")],
                      key=lambda s: (s.get("last_active") or ""), reverse=True)
        return pinned + rest

    # متادیتا هرگز کش نمی‌شود: تغییر نام یا انتقال به پروژه باید فوری
    # دیده شود، نه بعد از چهار ثانیه.
    return finish(out)


@app.get("/api/attention")
async def attention():
    """
    «چه کسی منتظر من است؟» — ارزشمندترین بخش مرحلهٔ ۱.
    نشستی که آخرین پیامش از کاربر بوده و مدتی است جوابی نیامده.
    """
    def build():
        items = []
        for ad in ADAPTERS.values():
            try:
                for s in ad.sessions():
                    if s.state in ("needs_input", "working"):
                        items.append({**asdict(s), "app": ad.name,
                                      "icon": ad.icon})
            except Exception:                                  # noqa: BLE001
                continue
        return items
    return await cached("attention", build)


# --------------------------------------------------------------- session detail


@app.get("/api/session/{app_key}/{sid:path}")
async def session_detail(app_key: str, sid: str, limit: int = 60):
    """متن کامل یک نشست برای نمایش در پنل جزئیات."""
    if app_key not in ADAPTERS:
        raise HTTPException(404, "unknown app")

    # نشست «پیش‌نویس» هنوز روی دیسکِ ایجنت نیست. خطا دادن برایش غلط است:
    # کاربر تازه با ＋ ساختش و انتظار دارد یک گفت‌وگوی خالی ببیند، نه
    # «Loading…» که هرگز تمام نمی‌شود.
    if store.meta_get(app_key, sid).get("draft"):
        return {"app": app_key, "id": sid, "messages": [], "draft": True}

    def build():
        from .adapters import _tail_json_lines, _text_of, _clean
        import glob
        msgs: list[dict] = []
        roots = {"claude": rp("/root/.claude/projects/*/*.jsonl"),
                 "pi": rp("/root/.pi/agent/sessions/*/*.jsonl")}
        if app_key in roots:
            for f in glob.glob(roots[app_key]):
                if sid in f:
                    for d in _tail_json_lines(f, 800):
                        t = (d.get("type") or "").lower()
                        if app_key == "claude" and t in ("user", "assistant"):
                            m = d.get("message") or {}
                            msgs.append({"role": t,
                                         "text": _text_of(m.get("content"))[:4000],
                                         "ts": d.get("timestamp")})
                        elif app_key == "pi" and t == "message":
                            m = d.get("message") or {}
                            if m.get("role") in ("user", "assistant"):
                                msgs.append({"role": m["role"],
                                             "text": _text_of(m.get("content"))[:4000],
                                             "ts": d.get("timestamp")})
                    break
        elif app_key == "hermes":
            rc, out = _sh(["hermes", "sessions", "export", sid], timeout=25)
            if rc == 0:
                for line in out.splitlines():
                    line = line.strip()
                    if line:
                        msgs.append({"role": "log", "text": line[:2000], "ts": None})
        return {"app": app_key, "id": sid, "messages": msgs[-limit:]}
    return await cached(f"detail:{app_key}:{sid}", build, ttl=3)


@app.get("/api/search")
async def search(q: str = Query(..., min_length=2), limit: int = 40):
    """جست‌وجوی سراسری در نشست‌های همهٔ برنامه‌ها — مرحلهٔ ۳."""
    def build():
        from .adapters import _tail_json_lines, _text_of, _clean
        import glob
        needle = q.lower()
        hits = []
        sources = [("claude", rp("/root/.claude/projects/*/*.jsonl")),
                   ("pi", rp("/root/.pi/agent/sessions/*/*.jsonl"))]
        for appk, pattern in sources:
            for f in glob.glob(pattern):
                try:
                    for d in _tail_json_lines(f, 900):
                        t = (d.get("type") or "").lower()
                        m = d.get("message") if isinstance(d.get("message"), dict) else None
                        if appk == "claude" and t in ("user", "assistant"):
                            txt = _text_of((m or {}).get("content"))
                            role = t
                        elif appk == "pi" and t == "message" and m:
                            txt = _text_of(m.get("content"))
                            role = m.get("role", "?")
                        else:
                            continue
                        if needle in txt.lower():
                            i = txt.lower().index(needle)
                            hits.append({
                                "app": appk, "role": role,
                                "session": os.path.basename(f)[:-6],
                                "snippet": _clean(txt[max(0, i - 60): i + 140], 200),
                                "ts": d.get("timestamp")})
                            if len(hits) >= limit:
                                return hits
                except Exception:                              # noqa: BLE001
                    continue
        return hits
    return await cached(f"search:{q}", build, ttl=10)


# --------------------------------------------------------------- control


@app.get("/api/models")
async def models():
    def build():
        out = {"combos": list_9router_combos(), "per_app": {}}
        for k, ad in ADAPTERS.items():
            try:
                out["per_app"][k] = {"current": ad.status().model,
                                     "available": ad.models()}
            except Exception:                                  # noqa: BLE001
                out["per_app"][k] = {"current": None, "available": []}
        return out
    return await cached("models", build)


@app.post("/api/model")
async def set_model(body: ModelBody):
    """تعویض مدل یک برنامه یا همه (dispatch دسته‌جمعی) — مرحلهٔ ۲."""
    def run():
        results = {}
        targets = (list(ADAPTERS.items()) if body.app == "all"
                   else [(body.app, ADAPTERS.get(body.app))])
        for k, ad in targets:
            if ad is None:
                results[k] = {"ok": False, "msg": "unknown app"}
                continue
            if "set_model" not in ad.capabilities:
                results[k] = {"ok": False, "msg": "not supported"}
                continue
            ok, msg = ad.set_model(body.model)
            results[k] = {"ok": ok, "msg": msg}
        return results
    loop = asyncio.get_running_loop()
    res = await loop.run_in_executor(POOL, run)
    invalidate()
    return {"results": res}


@app.get("/api/catalog/{agent}")
async def catalog_agent(agent: str):
    """
    چه مدل‌هایی را می‌شود به این ایجنت داد:
      combos — ۶ کامبوی 9router (مسیریابی خودکار)
      native — مدل‌هایی که خود این برنامه می‌شناسد
    """
    if agent not in ADAPTERS:
        raise HTTPException(404, "unknown agent")
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(POOL, lambda: catalog.for_agent(agent))


@app.get("/api/catalog")
async def catalog_all():
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(POOL, catalog.all_agents)


class DefaultBody(BaseModel):
    model: str
    only_supported: bool = True


@app.post("/api/model/default")
async def set_default_everywhere(b: DefaultBody):
    """
    یک کامبو (یا مدل) را روی **همهٔ** ایجنت‌ها به‌عنوان پیش‌فرض بنشان.

    گزارش صادقانه می‌دهد: برای هر ایجنت جداگانه ok/خطا، و اگر ایجنتی
    آن مدل را نمی‌شناسد صریح می‌گوید به‌جای اینکه وانمود کند موفق شد.
    """
    known = {c["id"] for c in catalog.combos()}

    def run():
        results = {}
        for k, ad in ADAPTERS.items():
            if k == "router" or "set_model" not in ad.capabilities:
                results[k] = {"ok": False, "msg": "does not support switching",
                              "skipped": True}
                continue
            # مدل بومی این ایجنت یا کامبو؟
            if b.model not in known:
                nat = {m["id"] for m in catalog.native(k)}
                if b.only_supported and nat and b.model not in nat:
                    results[k] = {"ok": False, "skipped": True,
                                  "msg": f"{k} does not list this model"}
                    continue
            ok, msg = ad.set_model(b.model)
            results[k] = {"ok": ok, "msg": msg}
        return results

    loop = asyncio.get_running_loop()
    res = await loop.run_in_executor(POOL, run)
    invalidate()
    catalog.invalidate()
    applied = [k for k, v in res.items() if v.get("ok")]
    store.tl(None, None, "model",
             f"default model -> {b.model} on {', '.join(applied) or 'nothing'}")
    return {"model": b.model, "results": res, "applied": applied,
            "count": len(applied)}


@app.post("/api/send")
async def send(body: SendBody):
    """
    ارسال پرامپت به یک برنامه. متن فارسی بدون تغییر عبور می‌کند.

    اگر این نشست عضو یک پروژهٔ مشترک باشد دو کار اضافه انجام می‌شود:
      ۱) متنِ زمینهٔ پروژه (هدف، نقش، حافظهٔ تیم) جلوی پرامپت می‌چسبد
      ۲) از جواب، نکته‌های ارزشمند خودکار برداشته و در حافظهٔ تیم ثبت می‌شود
    هیچ‌کدام برای گفت‌وگوی کلی اتفاق نمی‌افتد.
    """
    ad = ADAPTERS.get(body.app)
    if ad is None:
        raise HTTPException(404, "unknown app")
    if "send" not in ad.capabilities:
        raise HTTPException(400, f"{ad.name} does not accept prompts yet")

    pid = store.session_project(body.app, body.session_id) \
        if body.session_id else None
    prompt = body.text
    ctx = ""
    if pid:
        ctx = store.build_context(pid, body.app)
        if ctx:
            prompt = f"{ctx}\n{body.text}"

    loop = asyncio.get_running_loop()
    # شناسهٔ placeholder هرمس نباید به CLI برود — هرمس آن را نمی‌شناسد و
    # `--resume pending-…` شکست می‌خورد. فقط نشانهٔ «نشست تازه» است.
    prev = body.session_id
    if prev and prev.startswith("pending-"):
        prev = None

    ok, out, sid = await loop.run_in_executor(
        POOL, lambda: ad.send(prompt, prev))
    invalidate()

    # شناسهٔ واقعی برمی‌گردد تا رابط آن را نگه دارد. بدون این، هر پیام یک
    # نشست تازه می‌ساخت و ایجنت چیزی از پیام قبلی یادش نمی‌ماند.
    # آداپتور ممکن است شناسه را «تزیین» کند: Pi فایل را
    # `<timestamp>_<uuid>` می‌نامد، پس شناسهٔ واقعی با آنچه دادیم یکی
    # نیست ولی همان نشست است. اگر این را تطبیق ندهیم، ردیفِ پیش‌نویس
    # برای همیشه به‌عنوان یک نشست خالیِ جدا باقی می‌ماند.
    if sid and body.session_id and sid != body.session_id:
        bare = body.session_id.replace("pending-", "")
        if bare and bare in sid:
            store.meta_del(body.app, body.session_id)

    if sid and sid != body.session_id:
        carry: dict = {}
        if body.session_id:
            # ابرداده‌ای که روی placeholder نشسته بود (نام، پروژه) را
            # به شناسهٔ واقعی منتقل کن، بعد placeholder را دور بینداز.
            old = store.meta_get(body.app, body.session_id) or {}
            carry = {k: v for k, v in old.items()
                     if k in ("title", "project_id", "pinned") and v}
            if body.session_id.startswith("pending-"):
                store.meta_del(body.app, body.session_id)
        if body.project_id:
            carry["project_id"] = body.project_id
        carry["draft"] = 0
        store.meta_set(body.app, sid, carry)

    learned: list[str] = []
    if ok and pid:
        learned = store.auto_harvest(pid, body.app, out)
        store.tl(pid, body.app, "turn",
                 f"{body.text.strip()[:60]} → {len(out or '')} chars")
    return {"ok": ok, "output": out, "project": pid, "session_id": sid,
            "learned": learned, "context_used": bool(ctx)}


@app.post("/api/compare")
async def compare(body: CompareBody):
    """یک سؤال به چند کامبو هم‌زمان — مرحلهٔ ۳."""
    async def one(model: str):
        loop = asyncio.get_running_loop()
        t0 = time.time()

        def run():
            return _sh(["claude", "-p", body.text, "--model", model], timeout=180)
        rc, out = await loop.run_in_executor(POOL, run)
        return {"model": model, "ok": rc == 0,
                "seconds": round(time.time() - t0, 1),
                "output": out[-3000:]}
    res = await asyncio.gather(*(one(m) for m in body.models[:4]))
    return {"results": list(res)}


SAFE_UNITS = {"hermes-dashboard", "hermes-tunnel", "9router", "9router-tunnel",
              "cloudcli", "openclaw-gateway", "pi-web", "headroom", "nginx",
              "tunnel-watch", "aihub"}


@app.post("/api/service")
async def service(body: ServiceBody):
    """
    کنترل سرویس — «کار خطرناک». UI برای این‌ها دیالوگ تأیید نشان می‌دهد.
    فهرست سفید تا یک درخواست دستکاری‌شده نتواند هر یونیتی را بخواباند.
    """
    unit = body.unit.replace(".service", "")
    if unit not in SAFE_UNITS:
        raise HTTPException(400, "unit not allowed")
    if body.action not in ("restart", "stop", "start"):
        raise HTTPException(400, "bad action")
    user_unit = unit == "hermes-gateway"
    cmd = ["systemctl"] + (["--user"] if user_unit else []) + \
          [body.action, f"{unit}.service"]
    loop = asyncio.get_running_loop()
    rc, out = await loop.run_in_executor(POOL, lambda: _sh(cmd, timeout=45))
    invalidate()
    return {"ok": rc == 0, "output": out[-1500:]}


@app.get("/api/usage")
async def usage(days: int = 7):
    def build():
        r = RouterAdapter()
        return {"today": r.usage_today(), "series": r.usage_series(days),
                "recent": r.recent_requests(30)}
    return await cached(f"usage:{days}", build, ttl=8)


@app.get("/api/health")
async def health():
    return {"ok": True, "version": VERSION, "ts": time.time()}


# --------------------------------------------------------------- live stream


@app.get("/api/stream")
async def stream():
    """
    SSE: هر ۵ ثانیه وضعیت تازه — برای موبایل سبک‌تر از polling است.

    **نشست‌ها هم داخل همین پیام می‌آیند.** قبلاً فقط `overview` فرستاده
    می‌شد که نشست ندارد، پس سایدبار تا وقتی کاربر دستی صفحه را تازه
    نمی‌کرد کهنه می‌ماند — دقیقاً همان «سشن جدید می‌سازم ولی باید رفرش کنم».

    `fp` یک اثر انگشت سبک است تا سمتِ مرورگر بداند چیزی عوض شده یا نه و
    بی‌دلیل کل درخت را دوباره نسازد (که منوی باز را می‌بندد و اسکرول را
    می‌پراند).
    """
    async def gen():
        while True:
            try:
                data = await overview()
                try:
                    ss = await sessions(None, False)
                except Exception:                              # noqa: BLE001
                    ss = []
                data["sessions"] = ss
                data["fp"] = hashlib.md5(json.dumps(
                    [[x.get("source"), x.get("id"), x.get("title"),
                      x.get("last_active"), x.get("msg_count"),
                      x.get("project_id"), x.get("state")] for x in ss] +
                    [[p.get("id"), p.get("name")] for p in data.get("projects", [])],
                    ensure_ascii=False, sort_keys=True).encode()).hexdigest()
                yield f"data: {json.dumps(data, ensure_ascii=False)}\n\n"
            except Exception as exc:                           # noqa: BLE001
                yield f"data: {json.dumps({'error': str(exc)[:200]})}\n\n"
            await asyncio.sleep(5)
    return StreamingResponse(gen(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache",
                                      "X-Accel-Buffering": "no"})


# --------------------------------------------------------------- static

@app.get("/")
async def index():
    return FileResponse(STATIC / "index.html")


app.mount("/static", StaticFiles(directory=str(STATIC)), name="static")


# ═══════════════════════════════════════════════════════════════════
#  v2 — session metadata, live models, projects, skills, governance
# ═══════════════════════════════════════════════════════════════════


class MetaBody(BaseModel):
    title: str | None = None
    icon: str | None = None
    color: str | None = None
    pinned: int | None = None
    archived: int | None = None
    tags: str | None = None
    note: str | None = None


class ProjBody(BaseModel):
    name: str
    goal: str = ""
    icon: str = "📁"
    mode: str = "manual"
    budget: float = 1.0


class ProjPatch(BaseModel):
    name: str | None = None
    goal: str | None = None
    icon: str | None = None
    status: str | None = None
    mode: str | None = None
    budget_usd: float | None = None


class RoleBody(BaseModel):
    app: str
    role: str = ""
    ord: int = 0


class MemBody(BaseModel):
    text: str
    app: str | None = None
    kind: str = "fact"
    pinned: int = 0


class RunBody(BaseModel):
    app: str | None = None
    extra: str = ""
    mode: str | None = None


class SkillBody(BaseModel):
    name: str
    body: str
    icon: str = "⚡"
    apps: str = ""


class SkillRun(BaseModel):
    skill_id: str
    app: str
    extra: str = ""


class RaceBody(BaseModel):
    text: str
    combos: list[str]


class HandoffBody(BaseModel):
    from_app: str
    from_sid: str
    to_app: str
    note: str = ""


class PermBody(BaseModel):
    app: str
    mode: str


class ReviewBody(BaseModel):
    receipt_id: str
    reviewer: str
    project_id: str | None = None


# ───────────────────────────────────────── live model resolution


@app.get("/api/models/live")
async def models_live():
    """
    کدام مدل واقعی پشت هر کامبو کار می‌کند.
    `exact=false` یعنی آن مدل عضو چند کامبوست و انتساب قطعی نیست.
    """
    def build():
        per = resolver.live()
        agents = {}
        for k, ad in ADAPTERS.items():
            try:
                combo = ad.status().model
            except Exception:                                  # noqa: BLE001
                combo = None
            agents[k] = resolver.agent_live_model(combo)
        return {"combos": per, "agents": agents, "ts": time.time()}
    return await cached("models_live", build, ttl=5)


@app.get("/api/models/members/{combo}")
async def combo_members(combo: str):
    def build():
        return {"combo": combo, "members": resolver.member_detail(combo),
                "live": resolver.for_combo(combo)}
    return await cached(f"members:{combo}", build, ttl=10)


@app.get("/api/health/combos")
async def combo_health():
    return {"latest": store.health_latest()}


@app.post("/api/health/scan")
async def combo_health_scan():
    combos = list_9router_combos()
    res = await orchestra.health_scan(combos)
    invalidate()
    return {"results": res}


# ───────────────────────────────────────── session metadata


@app.patch("/api/session/{app_key}/{sid:path}/meta")
async def session_meta(app_key: str, sid: str, body: MetaBody):
    if app_key not in ADAPTERS:
        raise HTTPException(404, "unknown app")
    m = store.meta_set(app_key, sid,
                       **{k: v for k, v in body.model_dump().items()
                          if v is not None})
    invalidate("sessions")
    return {"ok": True, "meta": m}


@app.delete("/api/session/{app_key}/{sid:path}")
async def session_delete(app_key: str, sid: str, hard: int = 0):
    """
    hard=0 → فقط آرشیو (برگشت‌پذیر).
    hard=1 → حذف فایل واقعی، ولی همیشه یک کپی در سطل زباله می‌ماند.
    """
    if app_key not in ADAPTERS:
        raise HTTPException(404, "unknown app")
    if not hard:
        store.meta_set(app_key, sid, archived=1)
        invalidate("sessions")
        return {"ok": True, "mode": "archived"}

    # نشستِ «پیش‌نویس» فقط در دیتابیس هاب است و روی دیسکِ ایجنت وجود
    # ندارد؛ حذفش یعنی برداشتن همان ردیف.
    meta = store.meta_get(app_key, sid)
    if meta.get("draft"):
        store.meta_del(app_key, sid)
        invalidate()
        return {"ok": True, "mode": "draft removed"}

    # هر آداپتور خودش می‌داند نشستش کجاست. قبلاً اینجا فقط دو الگوی
    # claude و pi بود، پس حذفِ hermes و openclaw بی‌صدا هیچ کاری نمی‌کرد
    # و endpoint با HTTP 200 وانمود می‌کرد موفق شده.
    ok, detail = await asyncio.get_running_loop().run_in_executor(
        POOL, lambda: ADAPTERS[app_key].delete_session(sid))
    store.meta_del(app_key, sid)
    store.tl(None, app_key, "delete", f"session {sid[:24]} deleted")
    invalidate()
    if not ok:
        raise HTTPException(502, f"delete failed: {detail}")
    return {"ok": True, "detail": detail, "backup": detail}


@app.post("/api/session/new/{app_key}")
async def session_new(app_key: str, body: dict | None = Body(None)):
    """
    نشست تازه برای این ایجنت — دکمهٔ ＋ هر گروه.

    قبلاً این endpoint **هیچ چیزی نمی‌ساخت**؛ فقط یک «hint» برمی‌گرداند.
    نتیجه این بود که رابط شناسه‌ای نداشت، با هر پیام `session_id=null`
    می‌فرستاد و هر پیام یک گفت‌وگوی تازه می‌شد.

    حالا یک شناسهٔ واقعی ساخته و ثبت می‌شود. Pi و OpenClaw و Claude همین
    شناسه را می‌پذیرند (`--session-id`). هرمس شناسهٔ خودش را می‌سازد، پس
    برایش placeholder می‌گذاریم و بعد از اولین جواب با شناسهٔ واقعی
    جایگزین می‌شود.
    """
    ad = ADAPTERS.get(app_key)
    if ad is None:
        raise HTTPException(404, "unknown app")
    if "send" not in ad.capabilities:
        raise HTTPException(400, f"{ad.name} cannot start sessions")

    pid = (body or {}).get("project_id") or None
    sid = f"pending-{uuid.uuid4()}" if app_key == "hermes" else str(uuid.uuid4())
    meta = {"draft": 1}
    if pid:
        meta["project_id"] = pid
    store.meta_set(app_key, sid, meta)
    store.tl(pid, app_key, "session", f"new {app_key} session")
    invalidate()
    return {"ok": True, "app": app_key, "session_id": sid,
            "pending": app_key == "hermes", "project_id": pid}


@app.get("/api/sessions/junk")
async def sessions_junk():
    """
    نشست‌های بی‌ارزش را *پیشنهاد* می‌کند — خودش چیزی پاک نمی‌کند.

    محافظه‌کارانه: فقط چیزی که هم بی‌محتواست و هم نشانهٔ تست دارد.
    نشستی که msg_count نامعلوم است (hermes) هرگز نامزد حذف نمی‌شود،
    چون «نمی‌دانم» با «خالی» یکی نیست.
    """
    rows = await sessions(None, True)
    out = []
    for s in rows:
        n = s.get("msg_count")
        title = (s.get("title") or "").strip()
        prev = (s.get("preview") or "").strip()
        if s.get("pinned") or s.get("project_id"):
            continue                      # دست‌نخورده بماند
        why = []
        if n == 0:
            why.append("no messages")
        if n is not None and n <= 2 and JUNK_RE.match(prev or title):
            why.append("test chatter")
        if n == 0 and not prev and not title:
            why.append("empty")
        if why:
            out.append({**s, "why": why})
    return {"candidates": out, "count": len(out),
            "note": "nothing was deleted; call DELETE per session to remove"}


@app.post("/api/session/{app_key}/{sid}/bind")
async def session_bind(app_key: str, sid: str, body: dict = Body(...)):
    """
    نشست را عضو یک پروژهٔ مشترک می‌کند (project_id=null یعنی آزاد کردن).
    از این لحظه هر پیام آن نشست زمینهٔ پروژه را می‌گیرد و جوابش
    خودکار وارد حافظهٔ تیم می‌شود — بدون پین دستی.
    """
    pid = body.get("project_id") or None
    if pid and not store.proj_get(pid):
        raise HTTPException(404, "project not found")
    meta = store.bind_session(app_key, sid, pid)
    return {"ok": True, "meta": meta, "project_id": pid}


@app.get("/api/projects/{pid}/sessions")
async def project_session_list(pid: str):
    if not store.proj_get(pid):
        raise HTTPException(404, "not found")
    return {"sessions": store.project_sessions(pid)}


# ───────────────────────────────────────── projects


@app.get("/api/projects")
async def projects():
    return {"projects": store.proj_list()}


@app.post("/api/projects")
async def project_create(b: ProjBody):
    p = store.proj_create(b.name, b.goal, b.icon, b.mode, b.budget)
    return {"ok": True, "project": p}


@app.get("/api/projects/{pid}")
async def project_get(pid: str):
    p = store.proj_get(pid)
    if not p:
        raise HTTPException(404, "not found")
    return p


@app.patch("/api/projects/{pid}")
async def project_patch(pid: str, b: ProjPatch):
    p = store.proj_update(pid, **{k: v for k, v in b.model_dump().items()
                                  if v is not None})
    if not p:
        raise HTTPException(404, "not found")
    return {"ok": True, "project": p}


@app.delete("/api/projects/{pid}")
async def project_delete(pid: str):
    gone = store.proj_delete(pid)
    if not gone:
        raise HTTPException(404, "project not found")
    invalidate()          # نشست‌های آزادشده باید فوری در «کلی» دیده شوند
    return {"ok": True, "deleted": pid}


@app.post("/api/projects/{pid}/role")
async def project_role(pid: str, b: RoleBody):
    store.role_set(pid, b.app, b.role, b.ord)
    return {"ok": True, "project": store.proj_get(pid)}


@app.delete("/api/projects/{pid}/role/{app_key}")
async def project_role_del(pid: str, app_key: str):
    store.role_del(pid, app_key)
    return {"ok": True, "project": store.proj_get(pid)}


@app.post("/api/projects/{pid}/memory")
async def memory_add(pid: str, b: MemBody):
    m = store.mem_add(pid, b.text, b.app, b.kind, b.pinned)
    return {"ok": True, "entry": m}


@app.delete("/api/memory/{mid}")
async def memory_del(mid: str):
    store.mem_del(mid)
    return {"ok": True}


@app.post("/api/memory/{mid}/pin")
async def memory_pin(mid: str, on: int = 1):
    store.mem_pin(mid, on)
    return {"ok": True}


@app.get("/api/projects/{pid}/context/{app_key}")
async def project_context(pid: str, app_key: str):
    """پیش‌نمایش دقیق متنی که به ایجنت تزریق می‌شود — شفافیت کامل."""
    txt = store.build_context(pid, app_key)
    return {"context": txt, "chars": len(txt),
            "approx_tokens": len(txt) // 4}


@app.post("/api/projects/{pid}/run")
async def project_run(pid: str, b: RunBody):
    if b.app:
        r = await orchestra.run_role(pid, b.app, b.extra)
    else:
        r = await orchestra.run_project(pid, b.mode)
    invalidate()
    return r


@app.post("/api/projects/{pid}/cancel")
async def project_cancel(pid: str):
    return {"ok": orchestra.cancel(pid)}


# ───────────────────────────────────────── receipts / Aegis


@app.get("/api/receipts")
async def receipts(project_id: str | None = None):
    return {"receipts": store.receipt_list(project_id)}


@app.post("/api/receipts/review")
async def receipts_review(b: ReviewBody):
    return await orchestra.review(b.project_id, b.receipt_id, b.reviewer)


# ───────────────────────────────────────── skills


@app.get("/api/skills")
async def skills():
    store.seed_skills()
    return {"skills": store.skill_list()}


@app.post("/api/skills")
async def skill_create(b: SkillBody):
    return {"ok": True, "skill": store.skill_add(b.name, b.body, b.icon, b.apps)}


@app.delete("/api/skills/{sid}")
async def skill_delete(sid: str):
    store.skill_del(sid)
    return {"ok": True}


@app.post("/api/skills/run")
async def skill_run(b: SkillRun):
    sk = next((s for s in store.skill_list() if s["id"] == b.skill_id), None)
    if not sk:
        raise HTTPException(404, "skill not found")
    ad = ADAPTERS.get(b.app)
    if ad is None or "send" not in ad.capabilities:
        raise HTTPException(400, "app cannot run skills")
    store.skill_bump(b.skill_id)
    text = sk["body"] + ("\n\n" + b.extra if b.extra else "")
    loop = asyncio.get_running_loop()
    ok, out, _sid = await loop.run_in_executor(POOL, lambda: ad.send(text, None))
    store.tl(None, b.app, "skill", f"ran skill '{sk['name']}'")
    return {"ok": ok, "output": out}


# ───────────────────────────────────────── handoff


@app.post("/api/handoff")
async def handoff(b: HandoffBody):
    """یک گفتگو را به ایجنت دیگری منتقل می‌کند — هستهٔ «تعامل بین برنامه‌ها»."""
    src = ADAPTERS.get(b.from_app)
    dst = ADAPTERS.get(b.to_app)
    if src is None or dst is None:
        raise HTTPException(404, "unknown app")
    if "send" not in dst.capabilities:
        raise HTTPException(400, f"{dst.name} cannot receive a handoff")
    d = await session_detail(b.from_app, b.from_sid)
    summary = orchestra.handoff_summary(d.get("messages") or [])
    if b.note:
        summary += f"\n\nOperator note: {b.note}"
    loop = asyncio.get_running_loop()
    ok, out, _sid = await loop.run_in_executor(POOL, lambda: dst.send(summary, None))
    store.tl(None, b.to_app, "handoff",
             f"{b.from_app} → {b.to_app}")
    invalidate()
    return {"ok": ok, "output": out, "summary_chars": len(summary)}


# ───────────────────────────────────────── race / permissions / timeline


@app.post("/api/race")
async def race(b: RaceBody):
    r = await orchestra.race(b.text, b.combos)
    invalidate()
    return r


@app.get("/api/perms")
async def perms():
    return {"perms": store.perm_all()}


@app.post("/api/perms")
async def perms_set(b: PermBody):
    store.perm_set(b.app, b.mode)
    return {"ok": True, "perms": store.perm_all()}


@app.get("/api/timeline")
async def timeline(project_id: str | None = None, limit: int = 40):
    return {"events": store.tl_recent(limit, project_id)}


@app.get("/api/graph")
async def graph():
    """گراف رابطه: ایجنت‌ها، پروژه‌ها و پیوندهایشان برای نمایش بصری."""
    def build():
        nodes, edges = [], []
        for k, ad in ADAPTERS.items():
            try:
                st = ad.status()
                nodes.append({"id": f"app:{k}", "label": ad.name, "type": "agent",
                              "icon": ad.icon, "up": st.running,
                              "model": st.model, "n": st.session_count})
            except Exception:                                  # noqa: BLE001
                nodes.append({"id": f"app:{k}", "label": ad.name,
                              "type": "agent", "icon": ad.icon, "up": False})
        for p in store.proj_list():
            nodes.append({"id": f"proj:{p['id']}", "label": p["name"],
                          "type": "project", "icon": p.get("icon") or "📁",
                          "status": p.get("status")})
            for r in p.get("roles") or []:
                edges.append({"from": f"proj:{p['id']}", "to": f"app:{r['app']}",
                              "label": (r.get("role") or "")[:40],
                              "status": r.get("status")})
        return {"nodes": nodes, "edges": edges}
    return await cached("graph", build, ttl=8)


@app.get("/api/overview2")
async def overview2():
    """نمای کامل v2: وضعیت + مدل زنده + پروژه‌ها + رویدادها در یک درخواست."""
    base = await overview()
    def extra():
        return {"projects": store.proj_list(),
                "timeline": store.tl_recent(25),
                "meta": store.meta_all(),
                "perms": store.perm_all(),
                "health": store.health_latest()}
    ex = await cached("overview2x", extra, ttl=4)
    live = await models_live()
    return {**base, **ex, "live": live}
