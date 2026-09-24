"""
jobs.py — ارسال‌های طولانی، بدون قفل کردن رابط.

چرا لازم شد: `POST /api/send` تا ۳۰۰ ثانیه بلوکه می‌ماند. تا وقتی جواب
نیامده بود کاربر نه می‌فهمید چه خبر است، نه می‌توانست لغو کند، و نه
می‌توانست در نشست دیگری کار کند. سه ایراد از یک ریشه.

مدل تازه:
    POST /api/send        → فوراً {job_id} برمی‌گرداند
    GET  /api/jobs        → وضعیت همهٔ کارهای در جریان (در استریم هم می‌آید)
    POST /api/job/{id}/cancel → فرایند واقعی را می‌کشد، نه فقط UI را رها می‌کند

هر کار به یک (app, session) گره خورده تا رابط بتواند دقیقاً کنار همان
نشست چرخ‌دنده نشان دهد و بقیهٔ نشست‌ها آزاد بمانند.
"""

from __future__ import annotations

import threading
import time
import uuid
from typing import Any

from .adapters import cancel_job as _cancel_proc

# state: queued → running → done | error | cancelled
JOBS: dict[str, dict[str, Any]] = {}
_LOCK = threading.Lock()
KEEP = 900.0                    # کارهای تمام‌شده ۱۵ دقیقه می‌مانند


def new(app: str, session_id: str | None, text: str,
        project_id: str | None = None) -> str:
    jid = uuid.uuid4().hex[:12]
    with _LOCK:
        JOBS[jid] = {"id": jid, "app": app, "session_id": session_id,
                     "project_id": project_id, "state": "queued",
                     "text": text[:200], "started": time.time(),
                     "ended": None, "output": None, "error": None,
                     "phase": "در صف"}
    return jid


def set_(jid: str, **kw) -> None:
    with _LOCK:
        j = JOBS.get(jid)
        if j:
            j.update(kw)


def get(jid: str) -> dict | None:
    return JOBS.get(jid)


def cancel(jid: str) -> bool:
    """
    لغو واقعی: فرایند CLI کشته می‌شود.

    فقط علامت‌گذاری کافی نیست — مدل همچنان توکن می‌سوزاند و جوابش
    بعداً می‌رسد و ممکن است روی نشست بنشیند.
    """
    j = JOBS.get(jid)
    if not j or j["state"] in ("done", "error", "cancelled"):
        return False
    killed = _cancel_proc(jid)
    set_(jid, state="cancelled", ended=time.time(),
         phase="لغو شد", error=None if killed else "process already finished")
    return True


def prune() -> None:
    now = time.time()
    with _LOCK:
        for k in [k for k, v in JOBS.items()
                  if v.get("ended") and now - v["ended"] > KEEP]:
            JOBS.pop(k, None)


def active() -> list[dict]:
    """کارهای در جریان — برای نشان دادن چرخ‌دنده کنار نشست."""
    prune()
    return [dict(j) for j in JOBS.values()
            if j["state"] in ("queued", "running")]


def snapshot(limit: int = 40) -> list[dict]:
    prune()
    out = sorted(JOBS.values(), key=lambda j: j["started"], reverse=True)
    return [dict(j) for j in out[:limit]]


def busy_sessions() -> dict[str, str]:
    """نگاشت 'app:sid' → job_id برای نشست‌هایی که الان مشغول‌اند."""
    return {f"{j['app']}:{j['session_id']}": j["id"]
            for j in active() if j.get("session_id")}
