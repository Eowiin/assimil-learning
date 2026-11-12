from fastapi.testclient import TestClient

from app import main


def test_health_repond_ok(monkeypatch):
    monkeypatch.setattr(main, "gpu_name", lambda: "NVIDIA GeForce RTX 5070 Ti")
    response = TestClient(main.app).get("/health")
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert body["api"] == main.API_VERSION
    assert body["gpu"] == "NVIDIA GeForce RTX 5070 Ti"


def test_health_sans_carte_graphique(monkeypatch):
    monkeypatch.setattr(main, "gpu_name", lambda: None)
    body = TestClient(main.app).get("/health").json()
    assert body["status"] == "ok"
    assert body["gpu"] is None


def test_gpu_name_sans_nvidia_smi(monkeypatch):
    main.gpu_name.cache_clear()
    monkeypatch.setattr(main.shutil, "which", lambda _: None)
    assert main.gpu_name() is None
    main.gpu_name.cache_clear()
