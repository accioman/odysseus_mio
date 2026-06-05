import json
from pathlib import Path

from fastapi import FastAPI
from fastapi.testclient import TestClient

import routes.cookbook_routes as cookbook_routes


def test_cookbook_task_log_tail_reads_local_windows_log(tmp_path, monkeypatch):
    sid = "cookbook-92d17a91"
    log_dir = tmp_path / "odysseus-tmux"
    log_dir.mkdir()
    (log_dir / f"{sid}.log").write_text("one\ntwo\nthree\n", encoding="utf-8")
    (tmp_path / "cookbook_state.json").write_text(
        json.dumps({"tasks": [{"sessionId": sid, "type": "download", "platform": "windows"}]}),
        encoding="utf-8",
    )

    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    monkeypatch.setattr(cookbook_routes, "TMUX_LOG_DIR", log_dir)
    monkeypatch.setattr(cookbook_routes, "IS_WINDOWS", True)
    monkeypatch.setattr(cookbook_routes, "require_admin", lambda request: None)

    app = FastAPI()
    app.include_router(cookbook_routes.setup_cookbook_routes())

    resp = TestClient(app).get(f"/api/cookbook/tasks/{sid}/log?lines=2")
    assert resp.status_code == 200
    data = resp.json()
    assert data["ok"] is True
    assert data["source"] == "local-log"
    assert data["output"] == "two\nthree"


def test_download_copy_action_fetches_authoritative_log_tail():
    source = (Path(__file__).resolve().parents[1] / "static/js/cookbookRunning.js").read_text(
        encoding="utf-8"
    )

    assert "async function _fetchTaskLogTail(task, count = 50)" in source
    assert "/api/cookbook/tasks/${encodeURIComponent(sid)}/log?lines=${encodeURIComponent(count)}" in source
    assert "_copyTaskLogTail(el, task, lastOutput, 50)" in source
    assert "No download log available." not in source
