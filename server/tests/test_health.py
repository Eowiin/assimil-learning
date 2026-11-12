from fastapi.testclient import TestClient

from app import main


def client(monkeypatch, gpu, moteurs=None):
    monkeypatch.setattr(main, "gpu_name", lambda: gpu)
    return TestClient(main.create_app(moteurs=moteurs, charger=False))


def test_health_repond_ok(monkeypatch):
    body = client(monkeypatch, "NVIDIA GeForce RTX 5070 Ti").get("/health").json()
    assert body["status"] == "ok"
    assert body["api"] == main.API_VERSION
    assert body["gpu"] == "NVIDIA GeForce RTX 5070 Ti"


def test_health_sans_carte_graphique(monkeypatch):
    body = client(monkeypatch, None).get("/health").json()
    assert body["status"] == "ok"
    assert body["gpu"] is None


def test_health_annonce_la_conversation_si_chargee(monkeypatch):
    assert client(monkeypatch, None).get("/health").json()["modules"] == []
    assert client(monkeypatch, None, moteurs=object()).get("/health").json()["modules"] == ["conversation"]


def test_gpu_name_sans_nvidia_smi(monkeypatch):
    main.gpu_name.cache_clear()
    monkeypatch.setattr(main.shutil, "which", lambda _: None)
    assert main.gpu_name() is None
    main.gpu_name.cache_clear()
