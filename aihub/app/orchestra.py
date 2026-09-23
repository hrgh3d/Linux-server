"""
موتور پروژهٔ مشترک — جایی که ایجنت‌ها با هم کار می‌کنند.

سه ایدهٔ اصلی:

1. **حافظهٔ مشترک با تزریق متن.** هیچ‌کدام از Hermes/Claude/Pi/OpenClaw
   حافظهٔ مشترک بومی ندارند. Hub خلاصهٔ پروژه + حافظه را جلوی پرامپت
   می‌چسباند. ایجنت هر یافتهٔ مهم را با `MEMORY:` برمی‌گرداند و Hub
   برداشتش می‌کند. ساده، شفاف، و روی هر چهار برنامه کار می‌کند.

2. **سقف هزینه.** حالت خودکار می‌تواند توکن بسوزاند. هر اجرا پیش از
   شروع بودجه را چک می‌کند و رد شدن از سقف یعنی توقف، نه ادامه.

3. **Aegis — دروازهٔ کیفیت.** کار یک ایجنت تا وقتی ایجنت دیگری
   بازبینی‌اش نکرده «تمام» نیست. نتیجه یک رسید با شواهد است.
"""
from __future__ import annotations

import asyncio
import re
import time
from typing import Any, Callable

from . import store
from .adapters import ADAPTERS, RouterAdapter

# اجراهای در حال انجام: pid -> وضعیت. برای نمایش «در حال اجرا» و لغو.
RUNS: dict[str, dict] = {}


def _spend_today() -> float:
    try:
        return float(RouterAdapter().usage_today().get("cost") or 0)
    except Exception:                                          # noqa: BLE001
        return 0.0


def budget_check(pid: str) -> tuple[bool, str]:
    p = store.proj_get(pid)
    if not p:
        return False, "project not found"
    if (p.get("spent_usd") or 0) >= (p.get("budget_usd") or 0):
        return False, (f"budget exhausted "
                       f"(${p['spent_usd']:.3f} / ${p['budget_usd']:.2f})")
    return True, ""


async def run_role(pid: str, app: str, extra: str = "",
                   on_event: Callable | None = None) -> dict:
    """
    یک ایجنت را با context پروژه اجرا می‌کند.

    تفاوتش با ارسال معمولی: متن حافظهٔ مشترک و نقش جلوی پرامپت می‌آید و
    خروجی برای خطوط `MEMORY:` اسکن می‌شود.
    """
    ok, why = budget_check(pid)
    if not ok:
        store.tl(pid, app, "blocked", f"run blocked — {why}")
        return {"ok": False, "error": why}

    ad = ADAPTERS.get(app)
    if ad is None or "send" not in ad.capabilities:
        return {"ok": False, "error": f"{app} cannot accept prompts"}

    p = store.proj_get(pid)
    role = next((r for r in p["roles"] if r["app"] == app), None)
    task = extra.strip() or (role or {}).get("role") or p.get("goal") or ""
    prompt = store.build_context(pid, app) + "\n" + task

    store.role_set(pid, app, (role or {}).get("role", ""),
                   (role or {}).get("ord", 0), status="running")
    store.tl(pid, app, "run", f"{app} started")
    if on_event:
        on_event({"type": "role", "app": app, "status": "running"})

    t0 = time.time()
    before = _spend_today()
    loop = asyncio.get_running_loop()
    try:
        okk, out = await loop.run_in_executor(
            None, lambda: ad.send(prompt, None))
    except Exception as exc:                                   # noqa: BLE001
        store.role_set(pid, app, (role or {}).get("role", ""),
                       (role or {}).get("ord", 0), status="blocked")
        store.tl(pid, app, "error", f"{app} failed: {str(exc)[:160]}")
        return {"ok": False, "error": str(exc)[:300]}

    dur = round(time.time() - t0, 1)
    spent = max(0.0, _spend_today() - before)
    store.proj_update(pid, spent_usd=round((p.get("spent_usd") or 0) + spent, 6))

    facts = store.harvest(pid, app, out or "")
    store.role_set(pid, app, (role or {}).get("role", ""),
                   (role or {}).get("ord", 0),
                   status="done" if okk else "blocked")
    store.tl(pid, app, "done",
             f"{app} finished in {dur}s · {len(facts)} memory entries",
             {"cost": spent})

    rec = store.receipt_add(pid, app, task[:200], {
        "duration_s": dur, "memory_added": facts,
        "output_tail": (out or "")[-600:]}, cost=spent)

    if on_event:
        on_event({"type": "role", "app": app, "status": "done",
                  "facts": facts, "cost": spent})
    return {"ok": okk, "output": out, "facts": facts, "seconds": dur,
            "cost": spent, "receipt": rec["id"]}


async def run_project(pid: str, mode: str | None = None,
                      on_event: Callable | None = None) -> dict:
    """
    اجرای کل پروژه.

    sequential: به ترتیب `ord`، هر ایجنت حافظهٔ به‌روزشده را می‌بیند.
    parallel:   همه با هم؛ سریع‌تر ولی هیچ‌کدام یافتهٔ دیگری را نمی‌بیند.
    """
    p = store.proj_get(pid)
    if not p:
        return {"ok": False, "error": "not found"}
    mode = mode or p.get("mode") or "manual"
    roles = [r for r in p["roles"] if r["app"] in ADAPTERS
             and "send" in ADAPTERS[r["app"]].capabilities]
    if not roles:
        return {"ok": False, "error": "no runnable roles"}

    RUNS[pid] = {"started": time.time(), "mode": mode, "cancel": False}
    store.tl(pid, None, "project", f"run started ({mode})")
    results = []
    try:
        if mode == "parallel":
            res = await asyncio.gather(
                *(run_role(pid, r["app"], on_event=on_event) for r in roles),
                return_exceptions=True)
            results = [r if isinstance(r, dict) else {"ok": False,
                                                      "error": str(r)[:200]}
                       for r in res]
        else:
            for r in sorted(roles, key=lambda x: x.get("ord") or 0):
                if RUNS.get(pid, {}).get("cancel"):
                    store.tl(pid, None, "project", "run cancelled")
                    break
                ok, why = budget_check(pid)
                if not ok:
                    store.tl(pid, None, "blocked", why)
                    results.append({"ok": False, "error": why})
                    break
                results.append(await run_role(pid, r["app"], on_event=on_event))
    finally:
        RUNS.pop(pid, None)

    store.tl(pid, None, "project", "run finished")
    return {"ok": True, "results": results}


def cancel(pid: str) -> bool:
    if pid in RUNS:
        RUNS[pid]["cancel"] = True
        return True
    return False


# ───────────────────────────────────────────── Aegis: quality gate


async def review(pid: str | None, receipt_id: str, reviewer: str) -> dict:
    """
    یک ایجنت دیگر کار انجام‌شده را بازبینی می‌کند.
    خروجی APPROVE/REJECT است و در رسید ثبت می‌شود.
    """
    recs = store.receipt_list(pid)
    rec = next((r for r in recs if r["id"] == receipt_id), None)
    if not rec:
        return {"ok": False, "error": "receipt not found"}
    ad = ADAPTERS.get(reviewer)
    if ad is None or "send" not in ad.capabilities:
        return {"ok": False, "error": f"{reviewer} cannot review"}

    ev = rec.get("evidence") or {}
    prompt = (
        "You are the quality reviewer. Judge whether the work below is "
        "actually complete and correct.\n\n"
        f"TASK: {rec.get('task')}\n"
        f"PERFORMED BY: {rec.get('app')}\n"
        f"FINDINGS: {', '.join(ev.get('memory_added') or []) or 'none'}\n"
        f"OUTPUT:\n{(ev.get('output_tail') or '')[:1500]}\n\n"
        "Reply with APPROVE or REJECT on the first line, then one short "
        "sentence of reasoning.")
    loop = asyncio.get_running_loop()
    ok, out = await loop.run_in_executor(None, lambda: ad.send(prompt, None))
    verdict = "approved" if re.search(r"\bAPPROVE\b", out or "", re.I) else "rejected"
    store.receipt_verdict(receipt_id, verdict, reviewer)
    store.tl(pid, reviewer, "review",
             f"{reviewer} {verdict} the work of {rec.get('app')}")
    return {"ok": True, "verdict": verdict, "reasoning": (out or "")[:600]}


# ───────────────────────────────────────────── Race: first good answer wins


async def race(text: str, combos: list[str], app: str = "claude") -> dict:
    """
    یک سؤال به چند کامبو هم‌زمان. اولین جواب موفق برنده است؛ بقیه لغو
    می‌شوند تا توکن هدر نرود. ایدهٔ «throwaway» از Gentity.
    """
    ad = ADAPTERS.get(app)
    if ad is None:
        return {"ok": False, "error": "unknown app"}
    loop = asyncio.get_running_loop()

    async def one(combo: str):
        t0 = time.time()
        from .adapters import _sh
        rc, out = await loop.run_in_executor(
            None, lambda: _sh(["claude", "-p", text, "--model", combo],
                              timeout=150))
        return {"combo": combo, "ok": rc == 0, "seconds": round(time.time() - t0, 1),
                "output": (out or "")[-2500:]}

    tasks = [asyncio.create_task(one(c)) for c in combos[:4]]
    winner, others = None, []
    try:
        for fut in asyncio.as_completed(tasks):
            r = await fut
            if r["ok"] and winner is None:
                winner = r
                break
            others.append(r)
    finally:
        for t in tasks:
            if not t.done():
                t.cancel()
    return {"ok": winner is not None, "winner": winner, "losers": others}


# ───────────────────────────────────────────── combo regression watch


async def health_scan(combos: list[str]) -> list[dict]:
    """
    هر کامبو با یک پرسش بسیار کوتاه تست می‌شود.
    درس قبلی: **هرگز با streaming تست نکن** و مهلت سخاوتمندانه بده.
    """
    from .adapters import _sh
    loop = asyncio.get_running_loop()
    out = []

    async def probe(c: str):
        t0 = time.time()
        rc, o = await loop.run_in_executor(
            None, lambda: _sh(["claude", "-p", "reply with OK only",
                               "--model", c], timeout=120))
        ms = int((time.time() - t0) * 1000)
        ok = rc == 0 and bool((o or "").strip())
        store.health_put(c, ok, ms, "" if ok else (o or "")[-160:])
        return {"combo": c, "ok": ok, "ms": ms}

    res = await asyncio.gather(*(probe(c) for c in combos),
                               return_exceptions=True)
    for r in res:
        out.append(r if isinstance(r, dict) else {"ok": False, "combo": "?",
                                                  "err": str(r)[:120]})
    return out


# ───────────────────────────────────────────── handoff


def handoff_summary(messages: list[dict], limit: int = 12) -> str:
    """خلاصهٔ متنی یک گفتگو برای انتقال به ایجنت دیگر."""
    L = ["[HANDOFF — continuing a conversation started with another agent]"]
    for m in messages[-limit:]:
        role = "User" if m.get("role") == "user" else "Assistant"
        txt = (m.get("text") or "").strip().replace("\n", " ")[:300]
        if txt:
            L.append(f"{role}: {txt}")
    L.append("")
    L.append("Continue from here.")
    return "\n".join(L)
