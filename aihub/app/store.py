"""
لایهٔ دادهٔ خودِ Hub.

اصل طراحی: **هرگز فایل‌های اصلی برنامه‌ها را دست نمی‌زنیم.**
نام دلخواه، آیکون، تگ، پین و آرشیو در دیتابیس جداگانهٔ Hub می‌نشیند و
هنگام نمایش روی نشست واقعی «سوار» می‌شود. اگر این دیتابیس پاک شود،
هیچ نشستی از بین نمی‌رود — فقط اسم‌های دلخواه می‌روند.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import sqlite3
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any

DATA = Path(os.environ.get("AIHUB_DATA", "/opt/aihub/data"))
DB = DATA / "hub.sqlite"
PROJECTS = DATA / "projects"
TRASH = DATA / "trash"

SCHEMA = """
-- متادیتای دلخواه روی نشست‌های واقعی
create table if not exists session_meta(
  app         text not null,
  sid         text not null,
  title       text,
  icon        text,
  color       text,
  pinned      integer default 0,
  archived    integer default 0,
  tags        text default '',
  note        text,
  project_id  text,              -- نشست عضو کدام پروژهٔ مشترک است
  updated_at  real,
  primary key(app, sid)
);

-- پروژه‌های مشترک
create table if not exists projects(
  id         text primary key,
  name       text not null,
  goal       text,
  icon       text default '📁',
  status     text default 'active',   -- active | paused | done
  mode       text default 'manual',   -- manual | sequential | parallel
  budget_usd real default 1.0,
  spent_usd  real default 0.0,
  created_at real,
  updated_at real
);

-- نقش هر ایجنت در پروژه
create table if not exists project_roles(
  project_id text not null,
  app        text not null,
  role       text,                    -- شرح وظیفه
  ord        integer default 0,       -- ترتیب در حالت sequential
  status     text default 'waiting',  -- waiting | running | done | blocked
  session_id text,
  updated_at real,
  primary key(project_id, app)
);

-- حافظهٔ مشترک پروژه
create table if not exists memory(
  id         text primary key,
  project_id text not null,
  app        text,                    -- چه کسی ثبتش کرد
  kind       text default 'fact',     -- fact | decision | artifact | question
  text       text not null,
  pinned     integer default 0,
  created_at real
);

-- خط زمانی رویدادها
create table if not exists timeline(
  id         integer primary key autoincrement,
  project_id text,
  app        text,
  kind       text,
  text       text,
  meta       text,
  created_at real
);

-- مهارت‌ها: پرامپت‌های ذخیره‌شدهٔ قابل اجرا روی هر ایجنت
create table if not exists skills(
  id         text primary key,
  name       text not null,
  icon       text default '⚡',
  body       text not null,
  apps       text default '',         -- خالی = همه
  runs       integer default 0,
  created_at real
);

-- رسید تکمیل کار
create table if not exists receipts(
  id         text primary key,
  project_id text,
  app        text,
  task       text,
  evidence   text,                    -- JSON
  cost_usd   real default 0,
  verified_by text,
  status     text default 'pending',  -- pending | approved | rejected
  created_at real
);

-- پروفایل مجوز هر ایجنت
create table if not exists perms(
  app  text primary key,
  mode text default 'ask'             -- ask | acceptEdits | bypass
);

-- سلامت کامبوها (آشکارساز رگرسیون)
create table if not exists combo_health(
  combo      text not null,
  checked_at real not null,
  ok         integer,
  ms         integer,
  err        text,
  primary key(combo, checked_at)
);

create index if not exists ix_mem_proj  on memory(project_id, created_at desc);
create index if not exists ix_tl_proj   on timeline(project_id, id desc);
create index if not exists ix_health    on combo_health(combo, checked_at desc);
"""

_inited = False


def _ensure() -> None:
    global _inited
    if _inited:
        return
    for d in (DATA, PROJECTS, TRASH):
        d.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(DB, timeout=10)
    try:
        con.executescript(SCHEMA)
        # WAL: خواندن هم‌زمان با نوشتن قفل نمی‌کند — پنل زیر polling است
        con.execute("pragma journal_mode=WAL")
        _migrate(con)
        con.commit()
    finally:
        con.close()
    _inited = True


# ستون‌هایی که بعد از نسخهٔ اول اضافه شده‌اند. «create table if not exists»
# روی دیتابیسِ از قبل ساخته‌شده هیچ کاری نمی‌کند، پس ستون تازه بی‌سروصدا
# غایب می‌ماند و کوئری با «no such column» می‌شکند. صریح اضافه می‌کنیم.
_ADDED = [
    ("session_meta", "project_id", "text"),
    # نشستی که ساخته شده ولی هنوز پیامی نگرفته. باید در سایدبار دیده شود
    # (وگرنه دکمهٔ ＋ انگار هیچ کاری نمی‌کند) ولی جزو نشست‌های واقعی
    # ایجنت نیست، چون هنوز روی دیسکِ خود ایجنت وجود ندارد.
    ("session_meta", "draft", "integer default 0"),
]


def _migrate(con: sqlite3.Connection) -> None:
    for table, col, typ in _ADDED:
        try:
            have = {r[1] for r in con.execute(f"pragma table_info({table})")}
        except sqlite3.Error:
            continue
        if have and col not in have:
            try:
                con.execute(f"alter table {table} add column {col} {typ}")
            except sqlite3.OperationalError:
                pass


@contextmanager
def db():
    _ensure()
    con = sqlite3.connect(DB, timeout=10)
    con.row_factory = sqlite3.Row
    try:
        yield con
        con.commit()
    finally:
        con.close()


def now() -> float:
    return time.time()


def nid(p: str = "") -> str:
    return (p + uuid.uuid4().hex[:12]) if p else uuid.uuid4().hex[:12]


def slug(s: str) -> str:
    s = re.sub(r"[^\w\u0600-\u06FF-]+", "-", (s or "").strip())[:48]
    return s.strip("-").lower() or nid()


# ─────────────────────────────────────────────────────── session meta


def meta_all() -> dict[str, dict]:
    """همهٔ متادیتاها با کلید 'app:sid' تا یک‌بار خوانده و در حافظه join شود."""
    with db() as c:
        return {f"{r['app']}:{r['sid']}": dict(r)
                for r in c.execute("select * from session_meta")}


def meta_get(app: str, sid: str) -> dict:
    with db() as c:
        r = c.execute("select * from session_meta where app=? and sid=?",
                      (app, sid)).fetchone()
        return dict(r) if r else {}


def meta_set(app: str, sid: str, _fields: dict | None = None, **kw) -> dict:
    """
    ابرداده را ست می‌کند. هم dict می‌پذیرد هم kwargs.

    نکته: اگر هیچ فیلد مجازی نیامده باشد باز هم **ردیف ساخته می‌شود** —
    قبلاً زودهنگام return می‌کرد و نشستِ تازه هرگز ثبت نمی‌شد.
    """
    kw = {**(_fields or {}), **kw}
    allowed = {"title", "icon", "color", "pinned", "archived", "tags", "note",
               "project_id", "draft"}
    fields = {k: v for k, v in kw.items() if k in allowed}
    with db() as c:
        c.execute("insert or ignore into session_meta(app,sid,updated_at)"
                  " values(?,?,?)", (app, sid, now()))
        if not fields:
            r = c.execute("select * from session_meta where app=? and sid=?",
                          (app, sid)).fetchone()
            return dict(r) if r else {}
        sets = ",".join(f"{k}=?" for k in fields)
        c.execute(f"update session_meta set {sets},updated_at=?"
                  " where app=? and sid=?",
                  (*fields.values(), now(), app, sid))
        r = c.execute("select * from session_meta where app=? and sid=?",
                      (app, sid)).fetchone()
        return dict(r) if r else {}


def meta_del(app: str, sid: str) -> None:
    with db() as c:
        c.execute("delete from session_meta where app=? and sid=?", (app, sid))


def trash_put(path: str) -> str | None:
    """
    پیش از حذف واقعی، کپی می‌گیریم. حذف نشست یعنی پاک کردن فایل jsonl
    برنامهٔ اصلی — بدون سطل زباله یک اشتباه لمسی روی موبایل جبران‌ناپذیر است.
    """
    src = Path(path)
    if not src.exists():
        return None
    _ensure()
    dst = TRASH / f"{int(now())}_{src.name}"
    try:
        shutil.copy2(src, dst)
        return str(dst)
    except Exception:                                          # noqa: BLE001
        return None


def trash_prune(days: int = 30) -> int:
    _ensure()
    cut = now() - days * 86400
    n = 0
    for f in TRASH.glob("*"):
        try:
            if f.stat().st_mtime < cut:
                f.unlink()
                n += 1
        except Exception:                                      # noqa: BLE001
            pass
    return n


# ─────────────────────────────────────────────────────── projects


def proj_create(name: str, goal: str = "", icon: str = "📁",
                mode: str = "manual", budget: float = 1.0) -> dict:
    pid = slug(name)
    with db() as c:
        if c.execute("select 1 from projects where id=?", (pid,)).fetchone():
            pid = f"{pid}-{nid()[:4]}"
        c.execute("insert into projects(id,name,goal,icon,mode,budget_usd,"
                  "created_at,updated_at) values(?,?,?,?,?,?,?,?)",
                  (pid, name, goal, icon, mode, budget, now(), now()))
    d = PROJECTS / pid
    d.mkdir(parents=True, exist_ok=True)
    (d / "artifacts").mkdir(exist_ok=True)
    (d / "GOAL.md").write_text(f"# {name}\n\n{goal}\n", encoding="utf-8")
    (d / "MEMORY.md").write_text("# Shared memory\n\n", encoding="utf-8")
    tl(pid, None, "project", f"Project created: {name}")
    return proj_get(pid)


def proj_get(pid: str) -> dict | None:
    with db() as c:
        r = c.execute("select * from projects where id=?", (pid,)).fetchone()
        if not r:
            return None
        p = dict(r)
        p["roles"] = [dict(x) for x in c.execute(
            "select * from project_roles where project_id=? order by ord", (pid,))]
        p["memory"] = [dict(x) for x in c.execute(
            "select * from memory where project_id=? order by pinned desc,"
            " created_at desc limit 60", (pid,))]
        p["timeline"] = [dict(x) for x in c.execute(
            "select * from timeline where project_id=? order by id desc limit 40",
            (pid,))]
        return p


def proj_list() -> list[dict]:
    with db() as c:
        out = []
        for r in c.execute("select * from projects order by updated_at desc"):
            p = dict(r)
            p["roles"] = [dict(x) for x in c.execute(
                "select app,role,status from project_roles where project_id=?"
                " order by ord", (p["id"],))]
            p["mem_count"] = c.execute(
                "select count(*) from memory where project_id=?",
                (p["id"],)).fetchone()[0]
            out.append(p)
        return out


def proj_update(pid: str, **kw) -> dict | None:
    allowed = {"name", "goal", "icon", "status", "mode", "budget_usd", "spent_usd"}
    f = {k: v for k, v in kw.items() if k in allowed}
    if f:
        with db() as c:
            sets = ",".join(f"{k}=?" for k in f)
            c.execute(f"update projects set {sets},updated_at=? where id=?",
                      (*f.values(), now(), pid))
        if "goal" in f:
            g = PROJECTS / pid / "GOAL.md"
            if g.parent.exists():
                g.write_text(f"# {pid}\n\n{f['goal']}\n", encoding="utf-8")
    return proj_get(pid)


def proj_delete(pid: str) -> bool:
    """
    پروژه و همهٔ وابسته‌هایش را حذف می‌کند.

    برمی‌گرداند که واقعاً چیزی حذف شد یا نه — قبلاً همیشه «ok» می‌گفت،
    حتی وقتی شناسه اصلاً وجود نداشت، و کاربر فکر می‌کرد حذف شده.

    نشست‌ها **پاک نمی‌شوند**، فقط از پروژه آزاد می‌شوند و به «کلی»
    برمی‌گردند؛ وگرنه حذف یک پروژه گفت‌وگوهای واقعی را با خود می‌برد.
    """
    with db() as c:
        row = c.execute("select 1 from projects where id=?", (pid,)).fetchone()
        if not row:
            return False
        for t in ("project_roles", "memory", "timeline"):
            c.execute(f"delete from {t} where project_id=?", (pid,))
        c.execute("update session_meta set project_id=null where project_id=?",
                  (pid,))
        c.execute("delete from projects where id=?", (pid,))
    d = PROJECTS / pid
    if d.exists():
        shutil.move(str(d), str(TRASH / f"{int(now())}_proj_{pid}"))
    return True


def role_set(pid: str, app: str, role: str = "", ord_: int = 0,
             status: str | None = None, session_id: str | None = None) -> None:
    with db() as c:
        c.execute("insert or ignore into project_roles(project_id,app,updated_at)"
                  " values(?,?,?)", (pid, app, now()))
        sets, vals = ["role=?", "ord=?", "updated_at=?"], [role, ord_, now()]
        if status:
            sets.append("status=?")
            vals.append(status)
        if session_id:
            sets.append("session_id=?")
            vals.append(session_id)
        c.execute(f"update project_roles set {','.join(sets)}"
                  " where project_id=? and app=?", (*vals, pid, app))


def role_del(pid: str, app: str) -> None:
    with db() as c:
        c.execute("delete from project_roles where project_id=? and app=?",
                  (pid, app))


# ─────────────────────────────────────────────────────── shared memory


def mem_add(pid: str, text: str, app: str | None = None,
            kind: str = "fact", pinned: int = 0) -> dict:
    mid = nid()
    with db() as c:
        c.execute("insert into memory(id,project_id,app,kind,text,pinned,"
                  "created_at) values(?,?,?,?,?,?,?)",
                  (mid, pid, app, kind, text.strip(), pinned, now()))
    _sync_memory_md(pid)
    tl(pid, app, "memory", f"memory += {text.strip()[:70]}")
    with db() as c:
        return dict(c.execute("select * from memory where id=?", (mid,)).fetchone())


def mem_del(mid: str) -> None:
    with db() as c:
        r = c.execute("select project_id from memory where id=?", (mid,)).fetchone()
        c.execute("delete from memory where id=?", (mid,))
    if r:
        _sync_memory_md(r["project_id"])


def mem_pin(mid: str, on: int) -> None:
    with db() as c:
        c.execute("update memory set pinned=? where id=?", (on, mid))


def _sync_memory_md(pid: str) -> None:
    """
    آینهٔ markdown از حافظه. دو دلیل: خوانا برای آدم، و قابل خواندن
    مستقیم توسط ایجنت‌هایی که به فایل دسترسی دارند.
    """
    d = PROJECTS / pid
    if not d.exists():
        return
    with db() as c:
        rows = [dict(r) for r in c.execute(
            "select * from memory where project_id=?"
            " order by pinned desc, created_at asc", (pid,))]
    lines = ["# Shared memory", ""]
    for r in rows:
        who = f" — {r['app']}" if r["app"] else ""
        pin = "📌 " if r["pinned"] else ""
        lines.append(f"- {pin}{r['text']}{who}")
    try:
        (d / "MEMORY.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    except Exception:                                          # noqa: BLE001
        pass


def build_context(pid: str, app: str) -> str:
    """
    متنی که جلوی پرامپت ایجنت چسبانده می‌شود.

    این قلب «حافظهٔ مشترک» است: هیچ‌کدام از چهار برنامه حافظهٔ مشترک
    بومی ندارند، پس Hub آن را به‌شکل متن تزریق می‌کند. عمداً فشرده است
    چون هر کاراکتر اینجا در هر درخواست تکرار و هزینه می‌شود.
    """
    p = proj_get(pid)
    if not p:
        return ""
    L = [f"[PROJECT: {p['name']}]"]
    if p.get("goal"):
        L.append(f"[GOAL: {p['goal']}]")
    mine = next((r for r in p["roles"] if r["app"] == app), None)
    if mine and mine.get("role"):
        L.append(f"[YOUR ROLE: {mine['role']}]")
    mem = p["memory"][:18]
    if mem:
        L.append("[SHARED MEMORY]")
        for m in reversed(mem):
            who = f" ({m['app']})" if m["app"] else ""
            L.append(f"  - {m['text']}{who}")
    others = [r for r in p["roles"] if r["app"] != app]
    if others:
        L.append("[TEAM] " + " · ".join(
            f"{r['app']}:{r['status']}" for r in others))
    L.append("[HOW TO SHARE] Start any finding the team must know with "
             "'MEMORY:' on its own line.")
    L.append("")
    L.append("--- YOUR TASK ---")
    return "\n".join(L)


MEM_RE = re.compile(r"^\s*MEMORY:\s*(.+?)\s*$", re.M | re.I)


def harvest(pid: str, app: str, text: str) -> list[str]:
    """خطوط 'MEMORY: …' را از جواب ایجنت برمی‌دارد و ثبت می‌کند."""
    found = [m.group(1).strip() for m in MEM_RE.finditer(text or "")]
    for f in found[:10]:
        if f:
            mem_add(pid, f, app=app, kind="fact")
    return found


# ─────────────────────────────────────────────────────── timeline


def tl(pid: str | None, app: str | None, kind: str, text: str,
       meta: dict | None = None) -> None:
    with db() as c:
        c.execute("insert into timeline(project_id,app,kind,text,meta,created_at)"
                  " values(?,?,?,?,?,?)",
                  (pid, app, kind, text[:400],
                   json.dumps(meta, ensure_ascii=False) if meta else None, now()))


def tl_recent(limit: int = 40, pid: str | None = None) -> list[dict]:
    with db() as c:
        if pid:
            q = ("select * from timeline where project_id=?"
                 " order by id desc limit ?")
            rows = c.execute(q, (pid, limit))
        else:
            rows = c.execute("select * from timeline order by id desc limit ?",
                             (limit,))
        return [dict(r) for r in rows]


# ─────────────────────────────────────────────────────── skills


def skill_add(name: str, body: str, icon: str = "⚡", apps: str = "") -> dict:
    sid = nid()
    with db() as c:
        c.execute("insert into skills(id,name,icon,body,apps,created_at)"
                  " values(?,?,?,?,?,?)", (sid, name, icon, body, apps, now()))
        return dict(c.execute("select * from skills where id=?", (sid,)).fetchone())


def skill_list() -> list[dict]:
    with db() as c:
        return [dict(r) for r in c.execute(
            "select * from skills order by runs desc, created_at desc")]


def skill_del(sid: str) -> None:
    with db() as c:
        c.execute("delete from skills where id=?", (sid,))


def skill_bump(sid: str) -> None:
    with db() as c:
        c.execute("update skills set runs=runs+1 where id=?", (sid,))


def seed_skills() -> None:
    """چند مهارت پیش‌فرض که از کارهای واقعی همین سرور آمده‌اند."""
    with db() as c:
        if c.execute("select count(*) from skills").fetchone()[0]:
            return
    for n, i, b in [
        ("Health check", "🩺",
         "وضعیت همهٔ سرویس‌ها را بررسی کن و هر چیز غیرعادی را گزارش بده. "
         "خلاصه و در قالب فهرست."),
        ("Daily report", "📊",
         "گزارش روزانهٔ سرور: سرویس‌های فعال، مصرف توکن و هزینه، "
         "خطاهای مهم، و یک توصیه."),
        ("Explain this error", "🐞",
         "این خطا را ساده توضیح بده و راه‌حل گام‌به‌گام بده:\n\n"),
        ("Summarise session", "📝",
         "این گفتگو را در حداکثر ۵ نکته خلاصه کن."),
    ]:
        skill_add(n, b, icon=i)


# ─────────────────────────────────────────────────────── perms / receipts


def perm_get(app: str) -> str:
    with db() as c:
        r = c.execute("select mode from perms where app=?", (app,)).fetchone()
        return r["mode"] if r else "ask"


def perm_set(app: str, mode: str) -> None:
    if mode not in ("ask", "acceptEdits", "bypass"):
        return
    with db() as c:
        c.execute("insert into perms(app,mode) values(?,?)"
                  " on conflict(app) do update set mode=?", (app, mode, mode))


def perm_all() -> dict[str, str]:
    with db() as c:
        return {r["app"]: r["mode"] for r in c.execute("select * from perms")}


def receipt_add(pid: str | None, app: str, task: str,
                evidence: dict, cost: float = 0.0) -> dict:
    rid = nid()
    with db() as c:
        c.execute("insert into receipts(id,project_id,app,task,evidence,"
                  "cost_usd,created_at) values(?,?,?,?,?,?,?)",
                  (rid, pid, app, task,
                   json.dumps(evidence, ensure_ascii=False), cost, now()))
        return dict(c.execute("select * from receipts where id=?",
                              (rid,)).fetchone())


def receipt_list(pid: str | None = None, limit: int = 30) -> list[dict]:
    with db() as c:
        if pid:
            rows = c.execute("select * from receipts where project_id=?"
                             " order by created_at desc limit ?", (pid, limit))
        else:
            rows = c.execute("select * from receipts order by created_at desc"
                             " limit ?", (limit,))
        out = []
        for r in rows:
            d = dict(r)
            try:
                d["evidence"] = json.loads(d.get("evidence") or "{}")
            except Exception:                                  # noqa: BLE001
                d["evidence"] = {}
            out.append(d)
        return out


def receipt_verdict(rid: str, status: str, by: str) -> None:
    if status not in ("approved", "rejected"):
        return
    with db() as c:
        c.execute("update receipts set status=?,verified_by=? where id=?",
                  (status, by, rid))


# ─────────────────────────────────────────────────────── combo health


def health_put(combo: str, ok: bool, ms: int, err: str = "") -> None:
    with db() as c:
        c.execute("insert or replace into combo_health(combo,checked_at,ok,ms,err)"
                  " values(?,?,?,?,?)", (combo, now(), 1 if ok else 0, ms, err[:200]))


def health_latest() -> dict[str, dict]:
    with db() as c:
        out: dict[str, dict] = {}
        for r in c.execute("select * from combo_health order by checked_at desc"):
            if r["combo"] not in out:
                out[r["combo"]] = dict(r)
        return out


def health_history(combo: str, limit: int = 20) -> list[dict]:
    with db() as c:
        return [dict(r) for r in c.execute(
            "select * from combo_health where combo=?"
            " order by checked_at desc limit ?", (combo, limit))]


# ─────────────────────────────── حافظهٔ خودکارِ پروژه (بدون پین دستی)


def session_project(app: str, sid: str) -> str | None:
    """نشست عضو کدام پروژه است؟ None یعنی گفت‌وگوی کلی."""
    with db() as c:
        r = c.execute("select project_id from session_meta where app=? and sid=?",
                      (app, sid)).fetchone()
    pid = (r["project_id"] if r else None) or None
    if pid and not proj_get(pid):        # پروژه پاک شده، پیوند مرده را نادیده بگیر
        return None
    return pid


def bind_session(app: str, sid: str, pid: str | None) -> dict:
    """نشست را به پروژه‌ای می‌بندد (یا با None آزاد می‌کند)."""
    meta = meta_set(app, sid, project_id=pid)
    if pid:
        tl(pid, app, "session", f"session joined: {sid[:24]}")
    return meta


def project_sessions(pid: str) -> list[dict]:
    with db() as c:
        return [dict(r) for r in c.execute(
            "select * from session_meta where project_id=? order by updated_at desc",
            (pid,))]


# جمله‌هایی که ارزش ماندن در حافظهٔ تیم را دارند. عمداً محافظه‌کارانه است:
# حافظهٔ شلوغ بدتر از حافظهٔ خالی است، چون هر خطش در هر درخواست دوباره
# هزینه می‌شود.
_AUTO_PAT = [
    # تصمیم و نتیجه
    r"(?:^|\n)\s*(?:تصمیم|نتیجه|خلاصه|یافته)\s*[:：]\s*(.{8,180})",
    r"(?:^|\n)\s*(?:decision|result|conclusion|finding|summary)\s*:\s*(.{8,180})",
    # چیزی که پیدا شد / عوض شد
    r"(?:^|\n)\s*(?:پیدا کردم|مشکل|علت|راه‌حل)\s*[:：]\s*(.{8,180})",
    r"(?:^|\n)\s*(?:root cause|fixed|the bug (?:is|was))\s*:?\s*(.{8,180})",
]
_AUTO_RE = [re.compile(p, re.I) for p in _AUTO_PAT]

# چیزهایی که هرگز نباید وارد حافظهٔ مشترک شوند
_SECRET_RE = re.compile(
    r"(sk-[A-Za-z0-9_\-]{12,}|ghp_[A-Za-z0-9]{20,}|ogt_[a-f0-9]{20,}"
    r"|[0-9]{8,10}:AA[A-Za-z0-9_\-]{30,}"          # توکن تلگرام
    r"|password\s*[:=]\s*\S+|رمز\s*[:：]\s*\S+)", re.I)


def _looks_secret(t: str) -> bool:
    return bool(_SECRET_RE.search(t or ""))


def auto_harvest(pid: str, app: str, text: str, limit: int = 3) -> list[str]:
    """
    حافظهٔ خودکار: بدون اینکه کاربر چیزی پین کند، از جواب ایجنت
    نکته‌های ارزشمند را برمی‌دارد.

    سه لایه:
      ۱) خط صریح 'MEMORY:' — همیشه برداشته می‌شود
      ۲) الگوهای تصمیم/نتیجه/علت
      ۳) هیچ‌کدام نبود؟ هیچ. جملهٔ تصادفی برنمی‌داریم.

    تکراری‌ها و هرچیزی که بوی رمز بدهد کنار گذاشته می‌شود.
    """
    text = text or ""
    got: list[str] = []

    explicit = [m.group(1).strip() for m in MEM_RE.finditer(text)]
    cands = list(explicit)
    if not cands:
        for rx in _AUTO_RE:
            for m in rx.finditer(text):
                cands.append(m.group(1).strip())

    with db() as c:
        have = {(r["text"] or "").strip().lower() for r in c.execute(
            "select text from memory where project_id=?", (pid,))}
    for c in cands:
        c = re.sub(r"\s+", " ", c).strip(" .،؛:-")
        if len(c) < 8 or len(c) > 300:
            continue
        if _looks_secret(c):
            tl(pid, app, "memory", "skipped a line that looked like a secret")
            continue
        k = c.lower()
        if k in have:
            continue
        have.add(k)
        mem_add(pid, c, app=app, kind="auto" if c not in explicit else "fact")
        got.append(c)
        if len(got) >= limit:
            break
    return got
