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
import json
import os
import re
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from .adapters import (ADAPTERS, rp, RouterAdapter, _sh, list_9router_combos,
                       set_env_model, unit_active)

APP_DIR = Path(__file__).resolve().parent
STATIC = APP_DIR.parent / "static"
VERSION = "1.0.0"

app = FastAPI(title="AI Hub", version=VERSION, docs_url="/api/docs")

# استخر نخ: آداپتورها I/O مسدودکننده دارند (subprocess, sqlite, http).
# بدون این، یک `hermes sessions list` کند کل event loop را قفل می‌کند.
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


@app.get("/api/sessions")
async def sessions(app_key: str | None = Query(None, alias="app")):
    """نشست‌های همهٔ برنامه‌ها، مرتب‌شده بر اساس آخرین فعالیت."""
    def build():
        out = []
        targets = ([ADAPTERS[app_key]] if app_key and app_key in ADAPTERS
                   else list(ADAPTERS.values()))
        for ad in targets:
            try:
                out.extend(asdict(s) for s in ad.sessions())
            except Exception:                                  # noqa: BLE001
                continue
        out.sort(key=lambda s: (s.get("last_active") or ""), reverse=True)
        return out
    return await cached(f"sessions:{app_key or 'all'}", build)


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


@app.post("/api/send")
async def send(body: SendBody):
    """ارسال پرامپت به یک برنامه. متن فارسی بدون تغییر عبور می‌کند."""
    ad = ADAPTERS.get(body.app)
    if ad is None:
        raise HTTPException(404, "unknown app")
    if "send" not in ad.capabilities:
        raise HTTPException(400, f"{ad.name} does not accept prompts yet")
    loop = asyncio.get_running_loop()
    ok, out = await loop.run_in_executor(
        POOL, lambda: ad.send(body.text, body.session_id))
    invalidate()
    return {"ok": ok, "output": out}


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
    """SSE: هر ۵ ثانیه وضعیت تازه — برای موبایل سبک‌تر از polling است."""
    async def gen():
        while True:
            try:
                data = await overview()
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
