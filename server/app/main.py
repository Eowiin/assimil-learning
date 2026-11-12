"""Le serveur de la maison.

L'app l'interroge par Tailscale. Le serveur ne garde rien de l'apprenant :
l'iPhone envoie à chaque échange ce qu'il faut, et range lui-même ce qui revient
(cadrage v2, décision 2).
"""

import shutil
import subprocess
from functools import lru_cache

from fastapi import FastAPI
from pydantic import BaseModel

VERSION = "0.1.0"
# Monte quand une route change de forme : l'app saura qu'elle parle à un serveur
# trop ancien ou trop récent pour elle.
API_VERSION = 1

app = FastAPI(title="Assimil, serveur de la maison", version=VERSION)


class Health(BaseModel):
    status: str
    version: str
    api: int
    gpu: str | None


@lru_cache(maxsize=1)
def gpu_name() -> str | None:
    """Le nom de la carte graphique, si `nvidia-smi` répond. Sous WSL2, il est
    fourni par le pilote Windows. Lu une fois : la carte ne change pas en route."""
    if shutil.which("nvidia-smi") is None:
        return None
    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"],
            capture_output=True, text=True, timeout=5, check=True,
        ).stdout
    except (subprocess.SubprocessError, OSError):
        return None
    first = out.strip().splitlines()
    return first[0].strip() if first else None


@app.get("/health")
def health() -> Health:
    """Ce que le voyant de l'app interroge : le serveur répond, et sur quelle carte."""
    return Health(status="ok", version=app.version, api=API_VERSION, gpu=gpu_name())
