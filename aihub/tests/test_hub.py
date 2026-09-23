"""
تست‌های AI Hub.

اصل حاکم بر این تست‌ها: fixtureها دقیقاً شکل دادهٔ **واقعی سرور** را تقلید
می‌کنند (نتیجهٔ probeهای hub1/hub2)، نه شکلی که دلمان می‌خواهد. مثلاً
Pi با `type=message` و `message.role`، و OpenClaw از `session_nodes`
(نه `session_conversations` که صفر ردیف دارد).

اجرا:  cd /home/user/aihub && AIHUB_ROOT=/tmp/fake pytest -q
"""
import json
import os
import sqlite3
import time
import datetime
from pathlib import Path

import pytest

ROOT = os.environ.setdefault("AIHUB_ROOT", "/tmp/aihub-test")


# ------------------------------------------------------------------ fixtures


@pytest.fixture(scope="session", autouse=True)
def fake_fs():
    """می‌سازد: Claude jsonl، Pi jsonl، OpenClaw sqlite، 9Router sqlite."""
    base = Path(ROOT)
    (base / "root/.claude/projects/-root").mkdir(parents=True, exist_ok=True)
    (base / "root/.pi/agent/sessions/--root--").mkdir(parents=True, exist_ok=True)
    (base / "root/.openclaw/agents/main/agent").mkdir(parents=True, exist_ok=True)
    (base / "root/.9router/db").mkdir(parents=True, exist_ok=True)

    # --- Claude: رکوردهای ناهمگون + cost-state پایانی (شکل واقعی) ---
    recs = [
        {"type": "mode", "mode": "default"},
        {"type": "user", "timestamp": "2026-09-23T09:00:00Z",
         "message": {"role": "user",
                     "content": [{"type": "text",
                                  "text": "سلام، وضعیت سرور چطور است؟"}]}},
        {"type": "assistant", "timestamp": "2026-09-23T09:00:10Z",
         "message": {"role": "assistant", "model": "deepseek-v4.1-flash",
                     "content": [{"type": "text", "text": "سلام"}]}},
        {"type": "cost-state",
         "modelUsage": {"deepseek-v4.1-flash": {"inputTokens": 100}},
         "totalCostUSD": 0.012, "sessionId": "b6c543a8"},
    ]
    (base / "root/.claude/projects/-root/b6c543a8-9a74-4d85.jsonl").write_text(
        "\n".join(json.dumps(r, ensure_ascii=False) for r in recs),
        encoding="utf-8")

    # --- Pi: type=message با message.role (شکل واقعی) ---
    pr = [
        {"type": "session", "cwd": "/root", "id": "330c582d",
         "timestamp": "2026-09-23T10:00:00Z", "version": "0.87.1"},
        {"type": "model_change", "model": "Agentic",
         "timestamp": "2026-09-23T10:01:00Z"},
        {"type": "message", "id": "a1", "timestamp": "2026-09-23T10:20:00Z",
         "message": {"role": "user",
                     "content": [{"type": "text", "text": "Does Pi have a web UI?"}]}},
        {"type": "message", "id": "330c582d", "timestamp": "2026-09-23T10:20:04Z",
         "message": {"role": "assistant",
                     "content": [{"type": "text",
                                  "text": "Pi has no native web UI built in."}]}},
    ]
    (base / "root/.pi/agent/sessions/--root--/2026-09-23T10-00_330c582d.jsonl"
     ).write_text("\n".join(json.dumps(r) for r in pr), encoding="utf-8")
    # کلیدهای واقعی Pi (تأییدشده روی سرور): defaultProvider / defaultModel
    (base / "root/.pi/agent/settings.json").write_text(
        json.dumps({"defaultProvider": "ninerouter", "defaultModel": "Agentic",
                    "defaultThinkingLevel": "off",
                    "enabledModels": ["ninerouter/*"]}), encoding="utf-8")

    # --- OpenClaw: نشست‌ها در session_nodes، session_conversations خالی ---
    db = base / "root/.openclaw/agents/main/agent/openclaw-agent.sqlite"
    if db.exists():
        db.unlink()
    c = sqlite3.connect(db)
    c.execute("create table session_nodes(session_key,current_session_id,"
              "entry_json,entry_valid,updated_at,status,created_at,"
              "created_via,created_actor_type,created_actor_id)")
    c.execute("create table session_conversations(session_id,conversation_id,"
              "role,route_context_json,first_seen_at,last_seen_at)")
    c.execute("insert into session_nodes values(?,?,?,1,?,?,?,?,?,?)",
              ("agent:main:dashboard:05bce9eb", "3f39c300-b7b4-4e8a-8445",
               json.dumps({"sessionId": "3f39c300", "title": "گزارش روزانه"},
                          ensure_ascii=False),
               int(time.time() * 1000), "active", 0, "dashboard", "user", "hamid"))
    c.commit()
    c.close()
    # ساختار واقعی OpenClaw: agents.defaults.model + models.providers.*
    (base / "root/.openclaw/openclaw.json").write_text(json.dumps({
        "agents": {"defaults": {"workspace": "/root/.openclaw/workspace",
                                "model": "ninerouter/Agentic"}},
        "models": {"mode": "merge", "providers": {"ninerouter": {
            "baseUrl": "http://127.0.0.1:20128/v1",
            "models": [{"id": "ultimate"}, {"id": "Agentic"}, {"id": "Brain"}]}}},
        "gateway": {"port": 18789}}), encoding="utf-8")

    # Hermes config.yaml — بلوک model در ستون صفر
    (base / "root/.hermes").mkdir(parents=True, exist_ok=True)
    (base / "root/.hermes/config.yaml").write_text(
        "model:\n  default: ox-alpha\n  provider: custom\n"
        "  base_url: http://127.0.0.1:20128/v1\n"
        "database:\n  journal_mode: wal\n"
        "agent:\n  default: should-not-win\n", encoding="utf-8")

    # --- 9Router ---
    rdb = base / "root/.9router/db/data.sqlite"
    if rdb.exists():
        rdb.unlink()
    r = sqlite3.connect(rdb)
    r.execute("create table usageHistory(id integer primary key,timestamp,"
              "provider,model,connectionId,apiKey,endpoint,promptTokens,"
              "completionTokens,cost,status,tokens,meta)")
    r.execute("create table usageDaily(dateKey primary key,data)")
    r.execute("create table combos(id integer primary key,name,data)")
    for i, (m, pt, ct) in enumerate([("Agentic", 1200, 340),
                                     ("Brain", 800, 120), ("vps", 400, 90)]):
        r.execute("insert into usageHistory values(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                  (i + 1, int(time.time() * 1000), "p", m, "c", "k", "/v1",
                   pt, ct, 0.01, "ok", pt + ct, "{}"))
    today = datetime.date.today()
    for d in range(7):
        day = (today - datetime.timedelta(days=d)).isoformat()
        r.execute("insert into usageDaily values(?,?)",
                  (day, json.dumps({"requests": 31 - d,
                                    "promptTokens": 221277 - d * 9000,
                                    "completionTokens": 2578,
                                    "cost": 0.2282 - d * 0.02,
                                    "byProvider": {}})))
    for n in ["ultimate", "Agentic", "Image", "Brain", "ox-alpha", "vps"]:
        r.execute("insert into combos(name,data) values(?,?)",
                  (n, json.dumps({"models": []})))
    r.commit()
    r.close()
    yield base


@pytest.fixture(scope="session")
def client(fake_fs):
    from fastapi.testclient import TestClient
    from app.main import app
    return TestClient(app)


# ------------------------------------------------------------------ adapters


def test_claude_sessions_parse_persian_and_model():
    from app.adapters import ClaudeAdapter
    ss = ClaudeAdapter().sessions()
    assert ss, "Claude adapter returned no sessions"
    s = ss[0]
    assert s.source == "claude"
    # متن فارسی باید سالم بماند — نه mojibake، نه خالی
    assert "سلام" in (s.preview or "") or s.msg_count >= 2
    assert s.model == "deepseek-v4.1-flash"


def test_pi_sessions_use_message_type():
    """رگرسیون: قبلاً type=user/assistant فرض شده بود و صفر پیام می‌شمرد."""
    from app.adapters import PiAdapter
    ss = PiAdapter().sessions()
    assert ss, "Pi adapter returned no sessions"
    assert ss[0].msg_count == 2, f"expected 2 messages, got {ss[0].msg_count}"
    assert "web UI" in (ss[0].preview or "")


def test_pi_model_from_model_change_record():
    from app.adapters import PiAdapter
    assert PiAdapter().sessions()[0].model == "Agentic"


def test_openclaw_reads_session_nodes_not_conversations():
    """رگرسیون: session_conversations صفر ردیف دارد؛ باید session_nodes بخواند."""
    from app.adapters import OpenClawAdapter
    ss = OpenClawAdapter().sessions()
    assert ss, "OpenClaw returned nothing — did it read the empty table again?"
    assert ss[0].title == "dashboard"
    assert ss[0].state == "working"


def test_router_usage_and_combos():
    from app.adapters import RouterAdapter
    r = RouterAdapter()
    u = r.usage_today()
    assert u["requests"] == 31
    assert u["cost"] > 0.2
    assert len(r.usage_series(7)) == 7
    names = [c["name"] for c in r.combos()]
    assert "Agentic" in names and len(names) == 6


def test_every_adapter_is_exception_isolated(monkeypatch):
    """اگر یک آداپتور بترکد، بقیه نباید خالی شوند — قلب طراحی."""
    from app import adapters
    def boom(*a, **k):
        raise RuntimeError("simulated failure")
    monkeypatch.setattr(adapters.HermesAdapter, "sessions", boom)
    ok = 0
    for ad in adapters.ADAPTERS.values():
        try:
            ad.sessions()
            ok += 1
        except Exception:
            pass
    assert ok >= 3, "one broken adapter took the others down"


def test_tail_json_lines_handles_garbage():
    from app.adapters import _tail_json_lines
    p = Path(ROOT) / "junk.jsonl"
    p.write_text('{"type":"ok"}\nnot json at all\n{"type":"ok2"}\n')
    rows = _tail_json_lines(str(p), 10)
    assert [r["type"] for r in rows] == ["ok", "ok2"]


def test_text_of_handles_all_content_shapes():
    from app.adapters import _text_of
    assert _text_of("plain") == "plain"
    assert "hi" in _text_of([{"type": "text", "text": "hi"}])
    assert _text_of(None) == ""
    assert _text_of([{"type": "tool_use", "name": "Bash"}]) is not None


# ------------------------------------------------------------------ API


def test_health(client):
    r = client.get("/api/health")
    assert r.status_code == 200 and r.json()["ok"] is True


def test_overview_never_500s_and_lists_all_apps(client):
    r = client.get("/api/overview")
    assert r.status_code == 200
    d = r.json()
    keys = {a["key"] for a in d["apps"]}
    assert {"hermes", "claude", "pi", "openclaw", "router"} <= keys
    assert d["usage"]["requests"] == 31


def test_sessions_endpoint_merges_and_sorts(client):
    r = client.get("/api/sessions")
    assert r.status_code == 200
    ss = r.json()
    assert len(ss) >= 3
    sources = {s["source"] for s in ss}
    assert {"claude", "pi", "openclaw"} <= sources
    # مرتب‌سازی نزولی بر اساس last_active
    stamps = [s["last_active"] or "" for s in ss]
    assert stamps == sorted(stamps, reverse=True)


def test_search_finds_persian_text(client):
    """متن فارسی باید در جست‌وجوی سراسری پیدا شود."""
    r = client.get("/api/search", params={"q": "سرور"})
    assert r.status_code == 200
    hits = r.json()
    assert any("سرور" in h["snippet"] for h in hits), hits


def test_search_finds_english_text(client):
    hits = client.get("/api/search", params={"q": "web UI"}).json()
    assert any(h["app"] == "pi" for h in hits)


def test_search_rejects_too_short(client):
    assert client.get("/api/search", params={"q": "a"}).status_code == 422


def test_session_detail_returns_messages(client):
    ss = client.get("/api/sessions", params={"app": "pi"}).json()
    sid = ss[0]["id"]
    d = client.get(f"/api/session/pi/{sid}").json()
    assert len(d["messages"]) == 2
    assert d["messages"][0]["role"] == "user"


def test_session_detail_unknown_app_404(client):
    assert client.get("/api/session/nope/x").status_code == 404


def test_models_endpoint(client):
    d = client.get("/api/models").json()
    assert "Agentic" in d["combos"]
    assert set(d["per_app"]) >= {"claude", "pi", "openclaw"}


def test_send_to_unknown_app_404(client):
    r = client.post("/api/send", json={"app": "ghost", "text": "hi"})
    assert r.status_code == 404


def test_service_whitelist_blocks_arbitrary_units(client):
    """نباید بشود با یک درخواست دستکاری‌شده sshd یا tailscaled را خواباند."""
    for bad in ["sshd", "tailscaled", "ssh", "systemd-journald", "../../evil"]:
        r = client.post("/api/service", json={"unit": bad, "action": "stop"})
        assert r.status_code == 400, f"{bad} was NOT blocked"


def test_service_rejects_bad_action(client):
    r = client.post("/api/service", json={"unit": "nginx", "action": "rm -rf"})
    assert r.status_code == 400


def test_attention_endpoint(client):
    r = client.get("/api/attention")
    assert r.status_code == 200 and isinstance(r.json(), list)


def test_usage_endpoint(client):
    d = client.get("/api/usage").json()
    assert d["today"]["requests"] == 31
    assert len(d["recent"]) == 3


def test_index_serves_html(client):
    r = client.get("/")
    assert r.status_code == 200 and "AI Hub" in r.text


# ------------------------------------------------------------------ frontend


def test_frontend_has_rtl_support():
    html = (Path(__file__).parent.parent / "static/index.html").read_text(encoding="utf-8")
    assert "unicode-bidi:plaintext" in html, "Persian text will break without this"
    assert "rtl-auto" in html


def test_frontend_chrome_is_english():
    html = (Path(__file__).parent.parent / "static/index.html").read_text(encoding="utf-8")
    for label in ["Dashboard", "Sessions", "Control", "Insight",
                  "Send", "Apply", "Restart", "Compare"]:
        assert label in html, f"missing English label: {label}"


def test_frontend_confirms_destructive_actions():
    html = (Path(__file__).parent.parent / "static/index.html").read_text(encoding="utf-8")
    assert "confirmDanger" in html
    # هر فراخوانی restart باید از مسیر تأیید عبور کند
    assert html.count("confirmDanger(") >= 3


def test_frontend_escapes_user_content():
    """پیام‌های نشست ممکن است HTML داشته باشند — باید esc شوند."""
    html = (Path(__file__).parent.parent / "static/index.html").read_text(encoding="utf-8")
    assert "const esc =" in html
    assert "esc(m.text)" in html and "esc(h.snippet)" in html


def test_frontend_is_mobile_first():
    html = (Path(__file__).parent.parent / "static/index.html").read_text(encoding="utf-8")
    assert "width=device-width" in html
    assert "safe-area-inset" in html, "iPhone notch handling missing"
    assert "<nav>" in html, "bottom navigation missing"


def test_frontend_has_no_external_dependencies():
    """باید کاملاً آفلاین کار کند — هیچ CDN، فونت یا اسکریپت بیرونی."""
    html = (Path(__file__).parent.parent / "static/index.html").read_text(encoding="utf-8")
    import re
    for m in re.findall(r'(?:src|href)="([^"]+)"', html):
        assert not m.startswith("http"), f"external dependency: {m}"


def test_timestamps_come_from_records_not_file_mtime():
    """
    رگرسیون مهم: اگر زمان از mtime گرفته شود، یک rsync یا restore
    همهٔ نشست‌های قدیمی را «همین الان» نشان می‌دهد و صفحهٔ attention
    بی‌معنی می‌شود.
    """
    from app.adapters import ClaudeAdapter, PiAdapter
    for s in ClaudeAdapter().sessions() + PiAdapter().sessions():
        assert s.last_active and s.last_active.startswith("2026-09-23T"), s.last_active
        # ساعت باید 09 یا 10 باشد (زمان رکورد)، نه ساعت اجرای تست
        assert s.last_active[11:13] in ("09", "10"), \
            f"timestamp looks like file mtime, not record time: {s.last_active}"


def test_old_sessions_are_idle_not_working():
    """نشست چندساعته نباید «working» علامت بخورد."""
    from app.adapters import ClaudeAdapter, PiAdapter
    states = {s.state for s in ClaudeAdapter().sessions() + PiAdapter().sessions()}
    assert states == {"idle"}, f"stale sessions marked active: {states}"


# ------------------------------------------- real config-key regressions


def test_pi_reads_defaultModel_key():
    """رگرسیون: کلید واقعی defaultModel است، نه model."""
    from app.adapters import PiAdapter
    assert PiAdapter().status().model == "Agentic"


def test_pi_set_model_writes_real_keys(tmp_path):
    from app.adapters import PiAdapter
    ok, msg = PiAdapter().set_model("Brain")
    assert ok, msg
    d = json.load(open(Path(ROOT) / "root/.pi/agent/settings.json"))
    assert d["defaultModel"] == "Brain"
    assert d["defaultProvider"] == "ninerouter"
    # کلیدهای دیگر نباید گم شوند
    assert d["enabledModels"] == ["ninerouter/*"]
    PiAdapter().set_model("Agentic")


def test_openclaw_model_from_agents_defaults():
    """رگرسیون: مسیر واقعی agents.defaults.model است، نه models.default."""
    from app.adapters import OpenClawAdapter
    assert OpenClawAdapter().current_model() == "Agentic"


def test_openclaw_set_model_preserves_other_keys():
    """بازنویسی config نباید gateway/plugins را پاک کند."""
    from app.adapters import OpenClawAdapter
    a = OpenClawAdapter()
    ok, msg = a.set_model("Brain")
    assert ok, msg
    d = json.load(open(a.CFG))
    assert d["agents"]["defaults"]["model"] == "ninerouter/Brain"
    assert d["agents"]["defaults"]["workspace"] == "/root/.openclaw/workspace"
    assert d["gateway"]["port"] == 18789, "unrelated config was destroyed"
    assert "models" in d
    a.set_model("Agentic")


def test_openclaw_models_from_providers():
    from app.adapters import OpenClawAdapter
    assert "Agentic" in OpenClawAdapter().models()


def test_hermes_model_from_config_yaml():
    """کلید واقعی model.default است و نباید به بلوک agent: نشتی کند."""
    from app.adapters import HermesAdapter
    assert HermesAdapter._config_model() == "ox-alpha"


def test_hermes_set_model_edits_yaml_without_damage():
    """
    `hermes model` تعاملی است و روی رانر hang می‌کند، پس ویرایش مستقیم
    فایل تنها راه است — و نباید بقیهٔ ۱۸۰۰ سطر config را خراب کند.
    """
    from app.adapters import HermesAdapter
    a = HermesAdapter()
    ok, msg = a.set_model("Agentic")
    assert ok, msg
    txt = open(a.CFG, encoding="utf-8").read()
    assert "default: Agentic" in txt
    # بقیهٔ فایل دست‌نخورده
    assert "provider: custom" in txt
    assert "journal_mode: wal" in txt
    assert "default: should-not-win" in txt, "other blocks were modified"
    assert a._config_model() == "Agentic"
    a.set_model("ox-alpha")
    assert a._config_model() == "ox-alpha"
