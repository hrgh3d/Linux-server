"""
تست‌های AI Hub v2 — متادیتای نشست، مدل زنده، پروژهٔ مشترک، حافظه،
مهارت‌ها، مجوزها و دروازهٔ کیفیت.

اجرا:
  cd /home/user/aihub
  AIHUB_ROOT=/tmp/aihub-test AIHUB_DATA=/tmp/aihub-test/data pytest tests/ -q
"""
import json
import os
import sqlite3
from pathlib import Path

import pytest

ROOT = os.environ.setdefault("AIHUB_ROOT", "/tmp/aihub-test")
os.environ.setdefault("AIHUB_DATA", ROOT + "/data")

# fixtureهای فایل‌سیستم از test_hub می‌آیند
from test_hub import fake_fs  # noqa: F401,E402


@pytest.fixture(scope="module", autouse=True)
def clean_db(fake_fs):                                          # noqa: F811
    """هر بار دیتابیس Hub از نو ساخته می‌شود تا تست‌ها مستقل بمانند."""
    from app import store
    p = Path(os.environ["AIHUB_DATA"]) / "hub.sqlite"
    if p.exists():
        p.unlink()
    store._inited = False
    yield


@pytest.fixture(scope="module")
def client(clean_db):
    from fastapi.testclient import TestClient
    from app.main import app
    return TestClient(app)


# ───────────────────────────────────── session metadata


def test_rename_does_not_touch_the_real_file(client):
    """
    قلب طراحی: تغییر نام فقط در دیتابیس Hub است. فایل اصلی برنامه
    باید بایت‌به‌بایت دست‌نخورده بماند.
    """
    f = next((Path(ROOT) / "root/.pi/agent/sessions/--root--").glob("*.jsonl"))
    before = f.read_bytes()
    sid = f.stem

    r = client.patch(f"/api/session/pi/{sid}/meta",
                     json={"title": "پروژهٔ رصد سرور", "icon": "🛰"})
    assert r.status_code == 200, r.text
    assert f.read_bytes() == before, "the real session file was modified!"

    ss = client.get("/api/sessions", params={"app": "pi"}).json()
    s = next(x for x in ss if x["id"] == sid)
    assert s["title"] == "پروژهٔ رصد سرور"
    assert s["icon"] == "🛰"
    assert s["real_title"], "original title must be preserved"


def test_pinned_sessions_sort_first(client):
    ss = client.get("/api/sessions").json()
    target = ss[-1]
    client.patch(f"/api/session/{target['source']}/{target['id']}/meta",
                 json={"pinned": 1})
    ss2 = client.get("/api/sessions").json()
    assert ss2[0]["id"] == target["id"], "pinned session did not float to top"
    client.patch(f"/api/session/{target['source']}/{target['id']}/meta",
                 json={"pinned": 0})


def test_archive_hides_then_restores(client):
    ss = client.get("/api/sessions").json()
    t = ss[0]
    n0 = len(ss)
    client.patch(f"/api/session/{t['source']}/{t['id']}/meta",
                 json={"archived": 1})
    assert len(client.get("/api/sessions").json()) == n0 - 1
    assert len(client.get("/api/sessions",
                          params={"include_archived": True}).json()) == n0
    client.patch(f"/api/session/{t['source']}/{t['id']}/meta",
                 json={"archived": 0})
    assert len(client.get("/api/sessions").json()) == n0


def test_soft_delete_is_reversible(client):
    ss = client.get("/api/sessions").json()
    t = ss[0]
    r = client.delete(f"/api/session/{t['source']}/{t['id']}")
    assert r.json()["mode"] == "archived"
    client.patch(f"/api/session/{t['source']}/{t['id']}/meta",
                 json={"archived": 0})


def test_hard_delete_keeps_a_trash_copy(client):
    """حذف واقعی باید همیشه یک نسخه در سطل زباله بگذارد."""
    d = Path(ROOT) / "root/.pi/agent/sessions/--doomed--"
    d.mkdir(parents=True, exist_ok=True)
    f = d / "2026-09-20T10-00_deadbeef.jsonl"
    f.write_text(json.dumps({"type": "session", "cwd": "/x", "id": "deadbeef",
                             "timestamp": "2026-09-20T10:00:00Z"}) + "\n")
    r = client.delete("/api/session/pi/2026-09-20T10-00_deadbeef",
                      params={"hard": 1})
    assert r.status_code == 200, r.text
    assert not f.exists(), "file was not deleted"
    assert r.json()["backup"], "no trash copy was made"
    assert Path(r.json()["backup"]).exists()


def test_tags_round_trip(client):
    ss = client.get("/api/sessions").json()
    t = ss[0]
    client.patch(f"/api/session/{t['source']}/{t['id']}/meta",
                 json={"tags": "کاری,مهم"})
    s = next(x for x in client.get("/api/sessions").json()
             if x["id"] == t["id"])
    assert s["tags"] == ["کاری", "مهم"]


# ───────────────────────────────────── live model resolution


def test_resolver_maps_real_model_to_combo():
    """
    واقعیت سرور: usageHistory.model مدل واقعی است، combos.models اعضا.
    resolver باید از یکی به دیگری برسد.
    """
    from app import resolver
    mem = resolver.combo_members()
    assert "Agentic" in mem
    per = resolver.live()
    assert "Agentic" in per
    a = per["Agentic"]
    assert a["members"] >= 2
    if a["current"]:
        assert isinstance(a["exact"], bool)


def test_bare_model_normalisation():
    """پیشوند ارائه‌دهنده و پسوند :free نباید انتساب را خراب کند."""
    from app.resolver import _bare
    assert _bare("openrouter/deepseek/deepseek-v4-flash-0731") == \
        "deepseek-v4-flash-0731"
    assert _bare("gemini/gemini-3.6-flash") == "gemini-3.6-flash"
    assert _bare("tkbr/deepseek-v4.1-flash:free") == "deepseek-v4.1-flash"
    assert _bare("cl/deepseek/deepseek-v4.1-flash") == "deepseek-v4.1-flash"
    # این دو باید یکی شمرده شوند
    assert _bare("x/y:free") == _bare("z/y")


def test_models_live_endpoint(client):
    d = client.get("/api/models/live").json()
    assert "combos" in d and "agents" in d
    assert set(d["agents"]) >= {"claude", "pi", "openclaw"}


def test_combo_members_endpoint(client):
    d = client.get("/api/models/members/Agentic").json()
    assert d["combo"] == "Agentic"
    assert len(d["members"]) >= 2
    assert "short" in d["members"][0]


def test_ambiguous_model_is_flagged_not_guessed():
    """
    اگر یک مدل عضو دو کامبو باشد، نباید وانمود کنیم انتساب قطعی است.
    """
    from app import resolver
    idx = resolver._index()
    multi = [m for m, cs in idx.items() if len(cs) > 1]
    per = resolver.live()
    for c in per.values():
        if c["current"] and resolver._bare(c["current"]) in multi:
            assert c["exact"] is False, \
                "an ambiguous model was reported as exact"


# ───────────────────────────────────── projects & shared memory


def test_project_lifecycle(client):
    r = client.post("/api/projects", json={
        "name": "بهینه‌سازی سرور", "goal": "مصرف رم را ۳۰٪ کم کن",
        "icon": "🧠", "mode": "sequential", "budget": 0.5})
    assert r.status_code == 200, r.text
    p = r.json()["project"]
    pid = p["id"]
    assert p["goal"].startswith("مصرف رم")
    assert p["budget_usd"] == 0.5

    # فایل‌های روی دیسک هم ساخته شده باشند
    d = Path(os.environ["AIHUB_DATA"]) / "projects" / pid
    assert (d / "GOAL.md").exists() and (d / "MEMORY.md").exists()

    client.post(f"/api/projects/{pid}/role",
                json={"app": "pi", "role": "پیدا کردن پرمصرف‌ها", "ord": 0})
    client.post(f"/api/projects/{pid}/role",
                json={"app": "claude", "role": "نوشتن وصله", "ord": 1})
    p = client.get(f"/api/projects/{pid}").json()
    assert len(p["roles"]) == 2
    assert p["roles"][0]["app"] == "pi"


def test_shared_memory_and_markdown_mirror(client):
    pid = client.get("/api/projects").json()["projects"][0]["id"]
    client.post(f"/api/projects/{pid}/memory",
                json={"text": "nginx worker_processes = 8 (بیش از حد)",
                      "app": "pi"})
    client.post(f"/api/projects/{pid}/memory",
                json={"text": "php-fpm pm.max_children = 50", "app": "pi"})
    p = client.get(f"/api/projects/{pid}").json()
    assert len(p["memory"]) == 2
    md = (Path(os.environ["AIHUB_DATA"]) / "projects" / pid /
          "MEMORY.md").read_text(encoding="utf-8")
    assert "worker_processes" in md
    assert "— pi" in md


def test_context_injection_contains_everything_an_agent_needs(client):
    pid = client.get("/api/projects").json()["projects"][0]["id"]
    d = client.get(f"/api/projects/{pid}/context/claude").json()
    c = d["context"]
    assert "[PROJECT:" in c
    assert "[GOAL:" in c and "مصرف رم" in c
    assert "[YOUR ROLE: نوشتن وصله]" in c
    assert "[SHARED MEMORY]" in c and "worker_processes" in c
    assert "[TEAM]" in c and "pi" in c
    assert "MEMORY:" in c, "agent is not told how to write back"
    assert d["approx_tokens"] > 0


def test_context_is_not_bloated(client):
    """هر کاراکتر context در هر درخواست تکرار و هزینه می‌شود."""
    pid = client.get("/api/projects").json()["projects"][0]["id"]
    d = client.get(f"/api/projects/{pid}/context/claude").json()
    assert d["chars"] < 2500, f"context too large: {d['chars']} chars"


def test_memory_harvest_from_agent_reply():
    """خطوط MEMORY: باید خودکار وارد حافظهٔ مشترک شوند."""
    from app import store
    p = store.proj_create("harvest test", "g")
    out = ("Here is what I found.\n"
           "MEMORY: disk is 74G free\n"
           "some prose\n"
           "MEMORY: swap is disabled\n")
    facts = store.harvest(p["id"], "pi", out)
    assert facts == ["disk is 74G free", "swap is disabled"]
    got = [m["text"] for m in store.proj_get(p["id"])["memory"]]
    assert "disk is 74G free" in got and "swap is disabled" in got


def test_memory_pin_and_delete(client):
    pid = client.get("/api/projects").json()["projects"][0]["id"]
    m = client.post(f"/api/projects/{pid}/memory",
                    json={"text": "temporary note"}).json()["entry"]
    client.post(f"/api/memory/{m['id']}/pin", params={"on": 1})
    p = client.get(f"/api/projects/{pid}").json()
    assert p["memory"][0]["id"] == m["id"], "pinned entry not first"
    client.delete(f"/api/memory/{m['id']}")
    ids = [x["id"] for x in client.get(f"/api/projects/{pid}").json()["memory"]]
    assert m["id"] not in ids


def test_budget_guard_blocks_when_exhausted():
    """سقف هزینه باید واقعاً جلوی اجرا را بگیرد، نه فقط هشدار بدهد."""
    from app import store, orchestra
    p = store.proj_create("budget test", "g", budget=0.10)
    ok, why = orchestra.budget_check(p["id"])
    assert ok
    store.proj_update(p["id"], spent_usd=0.20)
    ok, why = orchestra.budget_check(p["id"])
    assert not ok and "budget" in why.lower()


def test_project_delete_moves_to_trash(client):
    p = client.post("/api/projects", json={"name": "throwaway"}).json()["project"]
    d = Path(os.environ["AIHUB_DATA"]) / "projects" / p["id"]
    assert d.exists()
    client.delete(f"/api/projects/{p['id']}")
    assert not d.exists()
    assert client.get(f"/api/projects/{p['id']}").status_code == 404
    trash = list((Path(os.environ["AIHUB_DATA"]) / "trash").glob("*proj_*"))
    assert trash, "deleted project left no trash copy"


# ───────────────────────────────────── skills / perms / timeline


def test_skills_seeded_and_listed(client):
    sk = client.get("/api/skills").json()["skills"]
    assert len(sk) >= 4
    assert any("Health" in s["name"] for s in sk)


def test_skill_create_and_delete(client):
    s = client.post("/api/skills", json={
        "name": "Combo test", "body": "تست کامبوها", "icon": "🧪"}).json()["skill"]
    assert s["name"] == "Combo test"
    client.delete(f"/api/skills/{s['id']}")
    assert s["id"] not in [x["id"] for x in
                           client.get("/api/skills").json()["skills"]]


def test_permission_profiles(client):
    client.post("/api/perms", json={"app": "openclaw", "mode": "ask"})
    client.post("/api/perms", json={"app": "pi", "mode": "bypass"})
    p = client.get("/api/perms").json()["perms"]
    assert p["openclaw"] == "ask" and p["pi"] == "bypass"


def test_permission_rejects_invalid_mode(client):
    client.post("/api/perms", json={"app": "pi", "mode": "yolo"})
    assert client.get("/api/perms").json()["perms"].get("pi") != "yolo"


def test_timeline_records_events(client):
    ev = client.get("/api/timeline").json()["events"]
    assert ev, "timeline is empty"
    assert any(e["kind"] == "project" for e in ev)


def test_graph_has_agents_and_projects(client):
    g = client.get("/api/graph").json()
    kinds = {n["type"] for n in g["nodes"]}
    assert "agent" in kinds and "project" in kinds
    assert g["edges"], "no project→agent edges"


def test_overview2_is_one_shot(client):
    d = client.get("/api/overview2").json()
    for k in ("apps", "usage", "projects", "timeline", "live", "perms"):
        assert k in d, f"overview2 missing {k}"


def test_receipts_created_by_runs(client):
    from app import store
    p = store.proj_create("receipt test", "g")
    store.receipt_add(p["id"], "pi", "find hogs",
                      {"duration_s": 3, "memory_added": ["x"]}, 0.01)
    r = client.get("/api/receipts", params={"project_id": p["id"]}).json()
    assert r["receipts"][0]["app"] == "pi"
    assert r["receipts"][0]["status"] == "pending"
    assert isinstance(r["receipts"][0]["evidence"], dict)


def test_handoff_summary_is_compact():
    from app.orchestra import handoff_summary
    msgs = [{"role": "user", "text": "سلام" * 200},
            {"role": "assistant", "text": "جواب" * 200}]
    s = handoff_summary(msgs)
    assert "[HANDOFF" in s
    assert len(s) < 1200, "handoff summary would blow up the prompt"


def test_unknown_project_404(client):
    assert client.get("/api/projects/nope").status_code == 404


def test_new_session_per_agent(client):
    r = client.post("/api/session/new/pi")
    assert r.status_code == 200 and r.json()["app"] == "pi"
    # ایجنتی که پرامپت نمی‌پذیرد نباید نشست بسازد
    assert client.post("/api/session/new/router").status_code == 400


# ───────────────────────────────────── frontend v2


def _html():
    return (Path(__file__).parent.parent / "static/index.html").read_text(
        encoding="utf-8")


def test_frontend_has_per_agent_new_button():
    """خواستهٔ ۳: دکمهٔ ＋ روی هدر هر ایجنت، نه یک دکمهٔ کلی بالا."""
    h = _html()
    assert 'data-new="' in h, "per-agent new button missing"
    assert "newSession(e.target.dataset.new)" in h


def test_frontend_shows_real_model_behind_combo():
    """خواستهٔ ۱: مدل واقعی کنار نام کامبو."""
    h = _html()
    assert "lm.real" in h, "real model never rendered"
    assert "S.live.agents" in h
    # علامت ~ برای انتساب غیرقطعی
    assert "lm.exact?''" in h.replace(" ", "") or "exact?'':'~'" in h.replace(" ", "")


def test_frontend_has_session_management():
    """خواستهٔ ۲: rename / icon / tag / archive / delete."""
    h = _html()
    for fn in ("renameDlg", "iconDlg", "tagDlg", "sessMenu", "metaSet"):
        assert fn in h, f"missing {fn}"
    assert "Delete permanently" in h
    assert "trash for 30 days" in h


def test_frontend_has_projects_and_memory():
    """خواستهٔ ۴ و ۵."""
    h = _html()
    for fn in ("openProject", "projDlg", "ctxPreview", "runRole", "runProject"):
        assert fn in h, f"missing {fn}"
    assert "Shared memory" in h
    assert "MEMORY:" in h, "users are never told how agents write to memory"


def test_frontend_has_new_capabilities():
    h = _html()
    for fn in ("handoffDlg", "raceDlg", "permDlg", "skillsDlg", "reviewDlg",
               "membersDlg"):
        assert fn in h, f"missing {fn}"


def test_frontend_destructive_actions_confirm():
    h = _html()
    assert "confirmDlg" in h
    assert h.count("confirmDlg(") >= 3


def test_frontend_still_rtl_safe():
    h = _html()
    assert "unicode-bidi:plaintext" in h
    assert 'class="rtl"' in h


def test_frontend_chrome_still_english():
    h = _html()
    for w in ["Sessions", "Projects", "Shared memory", "Hand off", "Permissions",
              "Race combos", "Rename", "Archive", "Budget cap"]:
        assert w in h, f"missing English label: {w}"


def test_frontend_no_external_resources():
    import re
    h = _html()
    for m in re.findall(r'(?:src|href)="([^"]+)"', h):
        assert not m.startswith("http"), f"external resource: {m}"


def test_frontend_escapes_everything_user_supplied():
    """
    عنوان نشست، متن پیام، نام پروژه و حافظه همه محتوای کاربر/مدل‌اند و
    مستقیم در innerHTML می‌روند — هرکدام باید از esc عبور کنند.
    """
    h = _html()
    assert "constesc=" in h.replace(" ", ""), "no escape helper"
    for expr in ("esc(s.title", "esc(m.text", "esc(p.name", "esc(t.text)",
                 "esc(s.preview", "esc(r.task)"):
        assert expr in h, f"unescaped render: {expr}"
