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
    # قطعیت انتساب از یک تابع واحد می‌آید، نه ternary پراکنده
    assert "const mark=" in h.replace(" ", "").replace("const mark =", "const mark=") \
        or "constmark=" in h.replace(" ", "")
    assert "mark(lm.exact)" in h, "certainty marker not applied to live model"
    # حدس هرگز نباید قطعی نشان داده شود
    assert "e===true?''" in h.replace(" ", ""), "mark() must treat only true as exact"


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


# ── رگرسیون: دو باگی که فقط روی دادهٔ واقعی سرور خودش را نشان داد


def test_combo_with_same_model_twice_is_still_exact(tmp_path, monkeypatch):
    """
    Brain واقعی همان مدل را از دو ارائه‌دهنده دارد:
      cl/deepseek/deepseek-v4.1-flash  +  tkbr/deepseek-v4.1-flash:free
    هر دو به یک نام ساده می‌رسند. اگر ایندکس یکتا نشود کامبو دوبار
    شمرده می‌شود و انتساب درست، به‌غلط «مبهم» علامت می‌خورد.
    """
    from app import resolver
    monkeypatch.setattr(resolver, "combo_members", lambda: {
        "Brain": ["cl/deepseek/deepseek-v4.1-flash",
                  "tkbr/deepseek-v4.1-flash:free"],
        "Other": ["gemini/gemini-3.6-flash"],
    })
    idx = resolver._index()
    assert idx["deepseek-v4.1-flash"] == ["Brain"], "combo counted twice"

    monkeypatch.setattr(resolver, "recent", lambda n=140: [
        {"id": 9, "timestamp": 1790000000000, "provider": "cl",
         "model": "deepseek-v4.1-flash:free", "cost": 0.001, "status": "ok"}])
    assert resolver.live()["Brain"]["exact"] is True


def test_timestamp_accepts_iso_strings():
    """ستون timestamp همیشه عدد نیست؛ اگر رشته را رد کنیم سن همیشه خالی است."""
    from app.resolver import _ts
    assert _ts(1790000000000) == 1790000000.0        # میلی‌ثانیه
    assert _ts(1790000000) == 1790000000.0           # ثانیه
    assert _ts("1790000000000") == 1790000000.0      # عدد رشته‌ای
    assert _ts("2026-09-23T14:30:00Z") is not None   # ISO
    assert _ts("2026-09-23T14:30:00+00:00") is not None
    assert _ts(None) is None and _ts("") is None and _ts("junk") is None


def test_age_is_reported_for_live_model(monkeypatch):
    import time as _t
    from app import resolver
    monkeypatch.setattr(resolver, "combo_members", lambda: {
        "Agentic": ["gemini/gemini-3.6-flash"]})
    monkeypatch.setattr(resolver, "recent", lambda n=140: [
        {"id": 1, "timestamp": int((_t.time() - 90) * 1000), "provider": "gemini",
         "model": "gemini-3.6-flash", "cost": 0.0, "status": "ok"}])
    a = resolver.live()["Agentic"]["age_s"]
    assert a is not None and 80 <= a <= 100, f"age wrong: {a}"


def test_unused_combo_reports_unknown_not_false(monkeypatch):
    """کامبویی که اصلاً استفاده نشده «نامعلوم» است، نه «مبهم»."""
    from app import resolver
    monkeypatch.setattr(resolver, "combo_members", lambda: {"Image": ["a/b"]})
    monkeypatch.setattr(resolver, "recent", lambda n=140: [])
    c = resolver.live()["Image"]
    assert c["current"] is None and c["exact"] is None


# ═══════════ v2.1: کپی، حافظهٔ خودکار، دو حالت، لمسی، ارسال hermes/openclaw


def test_all_four_agents_accept_prompts():
    """
    hermes و openclaw هم باید send داشته باشند. قبلاً چت با هرمس
    «does not accept prompts yet» می‌داد و دکمهٔ نشست تازه هم نداشت،
    چون هر دو از روی همین capability ساخته می‌شوند.
    """
    from app.adapters import ADAPTERS
    for k in ("hermes", "claude", "pi", "openclaw"):
        assert "send" in ADAPTERS[k].capabilities, f"{k} cannot send"
        assert hasattr(ADAPTERS[k], "send")


def test_hermes_send_uses_oneshot_not_interactive():
    """حالت تعاملی روی سرور بدون TTY هنگ می‌کند."""
    import inspect
    from app.adapters import HermesAdapter
    src = inspect.getsource(HermesAdapter.send)
    assert "--oneshot" in src
    assert '"chat"' in src, "must use `hermes chat`, not `hermes send`"


def test_hermes_reply_is_unwrapped_from_frame():
    """جواب داخل قاب ╭─ Hermes ─╮ است؛ کاربر نباید قاب و بلوک resume را ببیند."""
    from app.adapters import HermesAdapter
    raw = ("Query: hi\nInitializing agent...\n────────\n\n"
           "╭─ ☤ Hermes ──────────────╮\nPONG\n╰─────────────────────────╯\n\n"
           "Resume this session with:\n  hermes --resume 20260923_181056_ff17a3\n"
           "Session:  20260923_181056_ff17a3\n")
    m = HermesAdapter._FRAME.search(raw)
    assert m and m.group(1).strip() == "PONG"
    assert "Resume this session" not in m.group(1)


def test_openclaw_send_does_not_use_local(monkeypatch):
    """
    --local وقتی gateway بالاست رد می‌شود («A Gateway is running for this
    state directory») — روی سرور تأیید شد. --deliver هم نباید باشد وگرنه
    جواب به تلگرام/واتساپ پست می‌شود.
    خودِ فرمان ساخته‌شده را بازرسی می‌کنیم، نه متن سورس را.
    """
    from app import adapters
    seen = {}

    def fake_sh(cmd, timeout=10):
        seen["cmd"] = cmd
        return 0, '{"ok":true,"reply":"PONG"}'

    monkeypatch.setattr(adapters, "_sh", fake_sh)
    ok, out, _sid = adapters.OpenClawAdapter().send("hi")
    assert ok and out == "PONG"
    cmd = seen["cmd"]
    assert cmd[:2] == ["openclaw", "agent"]
    assert "--json" in cmd
    assert "--local" not in cmd, "gateway is always up; --local fails"
    assert "--deliver" not in cmd, "must not post the reply to a chat channel"
    assert "hi" in cmd


def test_openclaw_send_surfaces_gateway_errors(monkeypatch):
    """خطای واقعی باید به کاربر برسد، نه یک جیسون خام."""
    from app import adapters
    err = ('{"ok":false,"error":{"type":"cli_error","message":'
           '"A Gateway is running for this state directory"}}')
    monkeypatch.setattr(adapters, "_sh", lambda c, timeout=10: (1, err))
    ok, out, _sid = adapters.OpenClawAdapter().send("hi")
    assert ok is False
    assert "Gateway is running" in out


def test_auto_memory_harvests_without_manual_pinning(tmp_path, monkeypatch):
    """خواستهٔ کاربر: حافظه خودکار باشد، نه اینکه هر چیزی را دستی پین کند."""
    from app import store
    p = store.proj_create("t", "goal", "🧠", "manual", 1.0)
    pid = p["id"]
    assert store.auto_harvest(pid, "pi", "MEMORY: nginx has 8 workers") == \
        ["nginx has 8 workers"]
    # الگوی تصمیم، بدون MEMORY:
    got = store.auto_harvest(pid, "claude", "بررسی کردم.\nنتیجه: کش را خاموش کن")
    assert got and "کش" in got[0]
    got = store.auto_harvest(pid, "claude", "Root cause: the index was missing")
    assert got and "index" in got[0]


def test_auto_memory_stays_quiet_on_smalltalk():
    """حافظهٔ شلوغ بدتر از خالی است — هر چیزی نباید ذخیره شود."""
    from app import store
    pid = store.proj_create("t2", "g", "🧠", "manual", 1.0)["id"]
    assert store.auto_harvest(pid, "pi", "سلام حالت چطوره؟ خوبم مرسی.") == []
    assert store.auto_harvest(pid, "pi", "ok") == []


def test_auto_memory_never_stores_secrets():
    """کلید و رمز نباید در متنی بنشیند که به همهٔ ایجنت‌ها تزریق می‌شود."""
    from app import store
    pid = store.proj_create("t3", "g", "🧠", "manual", 1.0)["id"]
    for bad in ("MEMORY: key is sk-5c239655416ea7f6-u4d2tf-8bca7f49",
                "MEMORY: token ogt_39cabeb073b7220fdd0b681ed79dc47ccec7c1fa6",
                "MEMORY: password: hamidgh69",
                "MEMORY: رمز: hamidgh69"):
        assert store.auto_harvest(pid, "pi", bad) == [], bad
    assert store.proj_get(pid)["memory"] == []


def test_auto_memory_does_not_duplicate():
    from app import store
    pid = store.proj_create("t4", "g", "🧠", "manual", 1.0)["id"]
    store.auto_harvest(pid, "pi", "MEMORY: disk is 74G free")
    store.auto_harvest(pid, "claude", "MEMORY: disk is 74G free")
    store.auto_harvest(pid, "claude", "MEMORY:  Disk Is 74G Free ")
    assert len(store.proj_get(pid)["memory"]) == 1


def test_session_binds_to_project_and_unbinds():
    from app import store
    pid = store.proj_create("t5", "g", "🧠", "manual", 1.0)["id"]
    store.bind_session("pi", "sess-1", pid)
    assert store.session_project("pi", "sess-1") == pid
    assert len(store.project_sessions(pid)) == 1
    store.bind_session("pi", "sess-1", None)
    assert store.session_project("pi", "sess-1") is None


def test_deleted_project_does_not_strand_its_sessions():
    """اگر پیوند مرده بماند نشست نه در «کلی» دیده می‌شود نه زیر پروژه."""
    from app import store
    pid = store.proj_create("t6", "g", "🧠", "manual", 1.0)["id"]
    store.bind_session("pi", "sess-2", pid)
    store.proj_delete(pid)
    assert store.session_project("pi", "sess-2") is None


def test_schema_migration_adds_project_id_to_old_db(tmp_path, monkeypatch):
    """
    دیتابیس سرور از قبل ساخته شده؛ «create table if not exists» ستون تازه
    را اضافه نمی‌کند و کوئری با no such column می‌شکند.
    """
    import sqlite3
    db = tmp_path / "old.sqlite"
    con = sqlite3.connect(db)
    con.executescript("""create table session_meta(
        app text not null, sid text not null, title text, icon text,
        color text, pinned integer default 0, archived integer default 0,
        tags text default '', note text, updated_at real,
        primary key(app,sid));""")
    con.commit()
    from app import store
    store._migrate(con)
    cols = {r[1] for r in con.execute("pragma table_info(session_meta)")}
    assert "project_id" in cols
    store._migrate(con)          # دوباره اجرا شود نباید بترکد
    con.close()


def test_frontend_has_copy_everywhere():
    h = _html()
    assert "async function copyText" in h
    assert "data-copy=" in h, "no per-message copy button"
    assert "copySession" in h, "cannot copy a whole conversation"
    assert "bindCodeCopy" in h and "cbc" in h, "code blocks have no copy button"
    # روی http کلیپ‌بورد امن نیست، باید fallback داشته باشد
    assert "execCommand('copy')" in h, "no clipboard fallback for insecure context"


def test_frontend_is_usable_without_a_mouse():
    """
    خواستهٔ کاربر: روی موبایل موس نیست. هرچه با :hover ظاهر می‌شد
    باید روی دستگاه لمسی دائمی باشد و هدف لمس به‌اندازهٔ انگشت.
    """
    h = _html()
    assert "@media(hover:none)" in h, "no touch fallback at all"
    # بلوکی که کنترل‌های hover-only را دائمی می‌کند
    block = [b for b in h.split("@media(hover:none)")
             if "opacity:1 !important" in b[:900]]
    assert block, "no block forces hover-only controls visible"
    b = block[0]
    for sel in (".si .more", ".mn .pinb", ".memi .d"):
        assert sel in b, f"{sel} stays invisible on touch"


def test_frontend_has_two_modes_general_and_projects():
    h = _html()
    assert 'data-t="sessions"' in h and 'data-t="projects"' in h
    assert ">General<" in h, "the non-project mode should be named clearly"
    # نشست عضو پروژه نباید در حالت کلی تکرار شود
    assert "!s.project_id" in h
    # و باید زیر پروژهٔ خودش دیده شود
    assert "s.project_id===p.id" in h


def test_frontend_memory_is_automatic_not_manual():
    h = _html()
    assert "learned" in h, "user is never shown what was auto-remembered"
    assert "added to shared memory" in h
    assert "moveToProject" in h and "addChatDlg" in h
    assert "bindSession" in h


def test_send_endpoint_injects_context_and_harvests():
    import inspect
    from app import main
    src = inspect.getsource(main.send)
    assert "session_project" in src, "send never checks project membership"
    assert "build_context" in src, "shared memory is not injected"
    assert "auto_harvest" in src, "nothing is learned back"


def test_openclaw_counts_real_messages(tmp_path, monkeypatch):
    """
    باگ: msg_count برای openclaw هرگز پر نمی‌شد و همیشه ۰ بود، پس نشستی
    با ۴۳۱ رویداد «خالی» به نظر می‌رسید و نامزد حذف می‌شد.
    """
    import sqlite3
    db = tmp_path / "oc.sqlite"
    con = sqlite3.connect(db)
    con.executescript("""
      create table session_nodes(session_key text, current_session_id text,
        entry_json text, status text, updated_at int, created_via text);
      create table transcript_events(session_id text, seq int,
        event_json text, created_at int);
    """)
    con.execute("insert into session_nodes values(?,?,?,?,?,?)",
                ("agent:main:dashboard:abc", "abc", "{}", "idle", 1790000000000,
                 "dashboard"))
    for i in range(7):
        con.execute("insert into transcript_events values(?,?,?,?)",
                    ("abc", i, '{"type":"message"}', 1790000000000))
    con.execute("insert into transcript_events values(?,?,?,?)",
                ("abc", 9, '{"type":"custom"}', 1790000000000))
    con.commit(); con.close()

    from app.adapters import OpenClawAdapter
    ad = OpenClawAdapter()
    monkeypatch.setattr(ad, "DB", str(db))
    ss = ad.sessions()
    assert ss and ss[0].msg_count == 7, "only real messages should count"


def test_hermes_reports_unknown_count_not_zero():
    """«نمی‌دانم» با «خالی» یکی نیست — صفر گذاشتن نشست پر را قربانی می‌کند."""
    import inspect
    from app.adapters import HermesAdapter
    assert "msg_count=None" in inspect.getsource(HermesAdapter.sessions)


def test_junk_scan_never_proposes_pinned_or_project_sessions(monkeypatch):
    """پاک‌سازی نباید به چیزی که کاربر سنجاق کرده یا در پروژه است دست بزند."""
    import asyncio
    from app import main
    rows = [
        {"id": "a", "source": "pi", "msg_count": 0, "title": "", "preview": "",
         "pinned": True},
        {"id": "b", "source": "pi", "msg_count": 0, "title": "", "preview": "",
         "project_id": "p1"},
        {"id": "c", "source": "pi", "msg_count": 0, "title": "", "preview": ""},
        {"id": "d", "source": "hermes", "msg_count": None, "title": "سلام",
         "preview": ""},
    ]

    async def fake(app_key=None, include_archived=False):
        return rows
    monkeypatch.setattr(main, "sessions", fake)
    got = asyncio.run(main.sessions_junk())
    ids = {c["id"] for c in got["candidates"]}
    assert ids == {"c"}, f"unsafe proposal: {ids}"
    assert "nothing was deleted" in got["note"]


def test_frontend_shows_unknown_count_as_dash():
    h = _html()
    assert "s.msg_count==null?'—'" in h, "unknown count must not render as 0"


def test_metadata_changes_are_visible_immediately_not_after_cache_ttl(client):
    """
    باگ واقعی: merge متادیتا داخل تابعِ کش‌شونده بود، پس bind/rename تا
    ۴ ثانیه دیده نمی‌شد — روی سرور «bound -> [None]» داد. متادیتا هرگز
    نباید کش شود؛ فقط خواندن گرانِ خود ایجنت‌ها.
    """
    pid = client.post("/api/projects", json={
        "name": "p", "goal": "g", "icon": "🧠",
        "mode": "manual", "budget": 1}).json()["project"]["id"]
    ss = client.get("/api/sessions").json()
    assert ss, "fixture has no sessions"
    # نشست «پیش‌نویس» (با ＋ ساخته شده، هنوز بی‌پیام) عنوانِ سمتِ ایجنت
    # ندارد پس real_title آن قاعدتاً None است؛ اینجا نشست واقعی می‌خواهیم.
    s = [x for x in ss if not x.get("draft")][0]

    r = client.post(f"/api/session/{s['source']}/{s['id']}/bind",
                    json={"project_id": pid})
    assert r.status_code == 200
    # بدون هیچ صبری
    back = [x for x in client.get("/api/sessions").json()
            if x["id"] == s["id"]][0]
    assert back["project_id"] == pid, "bind invisible — sessions cache is stale"

    client.patch(f"/api/session/{s['source']}/{s['id']}/meta",
                 json={"title": "نام تازه"})
    back = [x for x in client.get("/api/sessions").json()
            if x["id"] == s["id"]][0]
    assert back["title"] == "نام تازه", "rename invisible"
    assert back["real_title"] == s["title"], "original title lost"

    client.post(f"/api/session/{s['source']}/{s['id']}/bind",
                json={"project_id": None})
    back = [x for x in client.get("/api/sessions").json()
            if x["id"] == s["id"]][0]
    assert back["project_id"] is None, "unbind invisible"


def test_raw_session_cache_is_not_poisoned_by_merge(client):
    """
    merge نباید روی شیء کش‌شده بنویسد، وگرنه real_title پس از دومین
    تغییرِ نام به «نام قبلیِ کاربر» تبدیل می‌شود و عنوان اصلیِ ایجنت
    برای همیشه گم می‌شود.
    """
    ss = client.get("/api/sessions").json()
    s = ss[-1]                      # نشستی که تست‌های قبلی دستش نزده‌اند
    sid, src = s["id"], s["source"]
    origin = s.get("real_title") or s["title"]

    client.patch(f"/api/session/{src}/{sid}/meta", json={"title": "AAA"})
    a = [x for x in client.get("/api/sessions").json() if x["id"] == sid][0]
    client.patch(f"/api/session/{src}/{sid}/meta", json={"title": "BBB"})
    b = [x for x in client.get("/api/sessions").json() if x["id"] == sid][0]

    assert a["title"] == "AAA" and b["title"] == "BBB"
    assert a["real_title"] == b["real_title"] == origin, \
        "real_title drifted — the cached object was mutated"


# ═══════════ v2.2: کاتالوگ مدل بومی هر ایجنت + مدل پیش‌فرض سراسری


def test_catalog_takes_only_combos_from_9router(monkeypatch):
    """
    تصحیح کاربر: از 9router فقط کامبوها را می‌خواهیم، نه هر ۱۵۲۷ مدلی
    که روتر سرو می‌کند. اگر روزی کسی فهرست خام را برگرداند اینجا می‌شکند.
    """
    import inspect
    from app import catalog
    src = inspect.getsource(catalog)
    assert "/v1/models" not in src, "must not pull the raw 1527-model list"
    assert "select name, models from combos" in src


def test_hermes_native_models_come_from_its_own_config(tmp_path, monkeypatch):
    """مدل‌های بومی هرمس از بلوک custom_providers خودش خوانده می‌شوند."""
    cfg = tmp_path / "config.yaml"
    cfg.write_text(
        "model:\n  default: Brain\n"
        "database:\n  journal_mode: wal\n"
        "custom_providers:\n"
        "  - name: Railway\n"
        "    base_url: http://127.0.0.1:20128/v1\n"
        "    models:\n"
        "      Agentic: {}\n"
        "      gemini/gemini-3.8-flash: {}\n"
        "      cf/@cf/qwen/qwq-32b: {}\n"
        "telemetry:\n  enabled: false\n", encoding="utf-8")
    from app import catalog
    monkeypatch.setattr(catalog, "rp", lambda p: str(cfg)
                        if "hermes" in p else p)
    got = {m["id"] for m in catalog._hermes_native()}
    assert "gemini/gemini-3.8-flash" in got
    assert "cf/@cf/qwen/qwq-32b" in got
    assert "Agentic" in got
    # نباید از بلوک بعدی چیزی بردارد
    assert not any("telemetry" in g or "enabled" in g for g in got)


def test_pi_native_models_come_from_its_own_models_json(tmp_path, monkeypatch):
    import json as _j
    f = tmp_path / "models.json"
    f.write_text(_j.dumps({"providers": {
        "ninerouter": {"models": [{"id": "Agentic"}, {"id": "Brain"}]},
        "google": {"models": [{"id": "gemini-x"}]}}}), encoding="utf-8")
    from app import catalog
    monkeypatch.setattr(catalog, "rp", lambda p: str(f) if "pi/" in p or
                        "models.json" in p else p)
    got = catalog._pi_native()
    assert {"Agentic", "Brain", "gemini-x"} == {m["id"] for m in got}
    assert {m["provider"] for m in got} == {"ninerouter", "google"}


def test_catalog_does_not_duplicate_combos_into_native(monkeypatch):
    from app import catalog
    catalog.invalidate()
    monkeypatch.setattr(catalog, "combos",
                        lambda: [{"id": "Agentic", "members": 12, "kind": "combo"}])
    monkeypatch.setattr(catalog, "native",
                        lambda a: [{"id": "Agentic", "provider": "x"},
                                   {"id": "gemini/g-1", "provider": "gemini"}])
    c = catalog.for_agent("pi")
    ids = [m["id"] for g in c["native_groups"] for m in g["models"]]
    assert "Agentic" not in ids, "combo duplicated into the native list"
    assert "gemini/g-1" in ids


def test_default_model_applies_to_every_agent(client, monkeypatch):
    """گزینهٔ «یک کامبو را روی همهٔ ایجنت‌ها بنشان»."""
    from app import catalog
    from app.adapters import ADAPTERS
    catalog.invalidate()
    monkeypatch.setattr(catalog, "combos",
                        lambda: [{"id": "Brain", "members": 2, "kind": "combo"}])
    calls = {}
    for k, ad in ADAPTERS.items():
        if "set_model" in ad.capabilities:
            monkeypatch.setattr(
                ad, "set_model",
                lambda m, _k=k: (calls.__setitem__(_k, m), (True, f"{_k}={m}"))[1])
    r = client.post("/api/model/default", json={"model": "Brain"})
    assert r.status_code == 200
    d = r.json()
    assert d["count"] >= 3, d
    assert set(d["applied"]) <= set(ADAPTERS)
    for k in d["applied"]:
        assert calls[k] == "Brain"


def test_default_model_is_honest_about_agents_that_cannot_switch(client,
                                                                monkeypatch):
    """ایجنتی که پشتیبانی نمی‌کند باید صریح skip شود، نه وانمود به موفقیت."""
    from app import catalog
    catalog.invalidate()
    monkeypatch.setattr(catalog, "combos", lambda: [{"id": "Brain",
                                                     "members": 2,
                                                     "kind": "combo"}])
    d = client.post("/api/model/default", json={"model": "Brain"}).json()
    assert "router" in d["results"]
    assert d["results"]["router"]["skipped"] is True
    assert d["results"]["router"]["ok"] is False


def test_default_model_refuses_unknown_model_per_agent(client, monkeypatch):
    """
    اگر مدل نه کامبوست و نه در فهرست بومی آن ایجنت، نباید کورکورانه
    ست شود — وگرنه ایجنت با مدلی می‌ماند که نمی‌شناسد و هر درخواست می‌شکند.
    """
    from app import catalog
    catalog.invalidate()
    monkeypatch.setattr(catalog, "combos", lambda: [])
    monkeypatch.setattr(catalog, "native", lambda a: [{"id": "only-this",
                                                       "provider": "p"}])
    d = client.post("/api/model/default",
                    json={"model": "does-not-exist"}).json()
    assert d["count"] == 0
    assert all(v.get("skipped") for v in d["results"].values())


def test_frontend_model_dialog_shows_native_and_combos():
    h = _html()
    assert 'data-mt="combos"' in h and 'data-mt="native"' in h
    assert "/api/catalog/" in h, "native catalog never fetched"
    assert "native_groups" in h


def test_frontend_can_set_default_on_all_agents():
    h = _html()
    assert 'id="applyAll"' in h
    assert "/api/model/default" in h
    assert "defaultReport" in h, "no per-agent result breakdown"


def test_frontend_apply_all_uses_clicked_model_not_current():
    """
    باگ قبلی: «Apply to all» مدل جاری را می‌فرستاد نه مدلی که کاربر
    کلیک کرده بود، پس عملاً هیچ تغییری نمی‌داد.
    """
    h = _html()
    seg = h[h.index("const pick=async(model)"):h.index("const drawCombos")]
    assert "post('/api/model/default',{model})" in seg.replace(" ", "")
    assert "cur||" not in seg


def test_pi_native_includes_its_own_model_store(tmp_path, monkeypatch):
    """
    Pi کاتالوگ بومی خودش را در models-store.json دارد (anthropic 15 +
    openai 41). قبلاً فقط models.json خوانده می‌شد که همان ۶ کامبو بود،
    پس فهرست بومی Pi خالی نشان داده می‌شد.
    """
    import json as _j
    (tmp_path / "models.json").write_text(_j.dumps(
        {"providers": {"ninerouter": {"models": [{"id": "Agentic"}]}}}))
    (tmp_path / "models-store.json").write_text(_j.dumps(
        {"anthropic": {"models": [{"id": "claude-fable-5"}]},
         "openai": {"models": [{"id": "gpt-6-sol"}]}}))
    (tmp_path / "auth.json").write_text("{}")
    from app import catalog
    monkeypatch.setattr(catalog, "rp",
                        lambda p: str(tmp_path / p.rsplit("/", 1)[-1]))
    got = catalog._pi_native()
    ids = {m["id"] for m in got}
    assert "anthropic/claude-fable-5" in ids
    assert "openai/gpt-6-sol" in ids
    assert "Agentic" in ids


def test_pi_flags_models_without_credentials(tmp_path, monkeypatch):
    """auth.json خالی است — نباید وانمود کنیم این مدل‌ها آمادهٔ کارند."""
    import json as _j
    (tmp_path / "models.json").write_text("{}")
    (tmp_path / "models-store.json").write_text(_j.dumps(
        {"anthropic": {"models": [{"id": "claude-fable-5"}]}}))
    (tmp_path / "auth.json").write_text("{}")
    from app import catalog
    monkeypatch.setattr(catalog, "rp",
                        lambda p: str(tmp_path / p.rsplit("/", 1)[-1]))
    m = catalog._pi_native()[0]
    assert m["needs_key"] is True


def test_frontend_warns_about_models_without_credentials():
    h = _html()
    assert "needs_key" in h, "UI never surfaces the missing-credential flag"
    assert "no credentials for this provider" in h


# ═══════════ v2.3: چرخهٔ عمر نشست — هر پیام نباید نشست تازه بسازد


def test_every_adapter_passes_the_session_id_to_its_cli():
    """
    ریشهٔ باگ «هر پیام یک سشن جدید باز می‌کند»: Claude و Pi اصلاً
    session_id را به CLI پاس نمی‌دادند. هر چهار آداپتور باید بدهند.
    """
    import inspect
    from app import adapters
    for cls, flag in ((adapters.HermesAdapter, "--resume"),
                      (adapters.ClaudeAdapter, "--session-id"),
                      (adapters.PiAdapter, "--session-id"),
                      (adapters.OpenClawAdapter, "--session-id")):
        src = inspect.getsource(cls.send)
        assert flag in src, f"{cls.__name__}.send never passes {flag}"


def test_send_returns_the_session_id(monkeypatch):
    """بدون برگرداندن شناسه، رابط نمی‌داند گفت‌وگو را چطور ادامه دهد."""
    from app import adapters
    out = adapters.SendOut(True, "hi", "abc-123")
    ok, text, sid = out
    assert (ok, text, sid) == (True, "hi", "abc-123")
    assert out.session_id == "abc-123"


def test_hermes_session_id_is_parsed_from_its_output():
    from app.adapters import _hermes_sid
    out = ("╭─ ☤ Hermes ─╮\nسلام\n╰──╯\n\nResume this session with:\n"
           "  hermes --resume 20260924_065919_6b22af\n"
           '  hermes -c "بگو سلام"\n')
    assert _hermes_sid(out) == "20260924_065919_6b22af"
    assert _hermes_sid("no session here") is None


def test_hermes_body_excludes_the_resume_block():
    from app.adapters import _hermes_body
    out = ("╭─ ☤ Hermes ─╮\nجواب واقعی\n╰──╯\n\nResume this session with:\n"
           "  hermes --resume 20260924_1\n")
    b = _hermes_body(out)
    assert b == "جواب واقعی"
    assert "resume" not in b.lower()


def test_claude_maps_combo_names_to_a_real_model():
    """
    تست زنده روی سرور: `claude --model Agentic` می‌دهد
    [claude-code:unrecognized_model] و بعد پاسخ خالی. کلاد کد نام کامبو را
    نمی‌شناسد، پس باید به یک مدل واقعی نگاشت شود.
    """
    from app.adapters import ClaudeAdapter, COMBO_NAMES
    ad = ClaudeAdapter()
    for combo in COMBO_NAMES:
        ad._env_model = staticmethod(lambda _c=combo: _c)
        assert ad._real_model() not in COMBO_NAMES
    ad._env_model = staticmethod(lambda: "cl/anthropic/claude-opus-5.5")
    assert ad._real_model() == "cl/anthropic/claude-opus-5.5"


def test_claude_noise_is_not_shown_as_the_answer():
    from app.adapters import _strip_claude_noise
    out = ('[claude-code:unrecognized_model] {"model":"Brain"}\n'
           "جواب درست\n")
    assert _strip_claude_noise(out) == "جواب درست"


def test_new_session_endpoint_actually_creates_one(client):
    """
    قبلاً این endpoint فقط یک «hint» برمی‌گرداند و هیچ نمی‌ساخت، پس رابط
    شناسه‌ای نداشت و هر پیام یک گفت‌وگوی تازه می‌شد.
    """
    r = client.post("/api/session/new/pi", json={})
    assert r.status_code == 200
    sid = r.json().get("session_id")
    assert sid, "no session id returned"
    rows = client.get("/api/sessions?app_key=pi").json()
    assert any(s["id"] == sid for s in rows), "new session not listed"


def test_new_session_in_a_project_is_bound_immediately(client):
    pid = client.post("/api/projects", json={"name": "چسبندگی"}).json()["project"]["id"]
    sid = client.post("/api/session/new/pi",
                      json={"project_id": pid}).json()["session_id"]
    row = [s for s in client.get("/api/sessions").json() if s["id"] == sid][0]
    assert row["project_id"] == pid


def test_project_sessions_never_appear_in_general(client):
    """
    خواستهٔ صریح کاربر: نشست‌های پروژه نباید در «کلی» هم دیده شوند.
    """
    pid = client.post("/api/projects", json={"name": "فقط-پروژه"}).json()["project"]["id"]
    sid = client.post("/api/session/new/pi",
                      json={"project_id": pid}).json()["session_id"]
    rows = client.get("/api/sessions").json()
    general = [s for s in rows if not s.get("project_id")]
    assert sid not in [s["id"] for s in general]


def test_deleting_a_project_frees_its_sessions_instead_of_hiding_them(client):
    """
    نشست نباید با پروژه پاک شود و نباید هم گم شود: باید به «کلی» برگردد.
    """
    pid = client.post("/api/projects", json={"name": "موقت"}).json()["project"]["id"]
    sid = client.post("/api/session/new/pi",
                      json={"project_id": pid}).json()["session_id"]
    assert client.delete(f"/api/projects/{pid}").status_code == 200
    rows = client.get("/api/sessions").json()
    row = [s for s in rows if s["id"] == sid]
    assert row, "session vanished with its project"
    assert row[0]["project_id"] is None, "still bound to a deleted project"


def test_deleting_a_missing_project_is_reported_not_faked(client):
    """قبلاً همیشه ok می‌گفت، حتی برای شناسه‌ای که وجود نداشت."""
    assert client.delete("/api/projects/does-not-exist").status_code == 404


def test_frontend_new_session_button_calls_the_api():
    h = _html()
    seg = h[h.index("async function newSession"):]
    seg = seg[:seg.index("\n}")]
    assert "/api/session/new/" in seg, "the ＋ button never creates a session"


def test_frontend_keeps_the_returned_session_id():
    h = _html()
    assert "r.session_id" in h, "reply session id discarded — chat restarts"
    assert "view.sid=r.session_id" in h.replace(" ", "")


def test_frontend_has_a_delete_project_control():
    """endpoint وجود داشت ولی هیچ دکمه‌ای صدایش نمی‌زد."""
    h = _html()
    assert "delP" in h
    assert "/api/projects/'+encodeURIComponent(p.id)" in h.replace('"', "'")
