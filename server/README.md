# Le serveur de la maison

Il fait tourner sur le PC fixe (WSL2, carte graphique NVIDIA) les modèles que l'iPhone
ne peut pas porter : la conversation et la prononciation (`docs/cadrage-v2.md`).
L'app l'interroge par Tailscale, à la maison comme dehors. Il ne garde rien de
l'apprenant : tout l'état reste sur l'iPhone.

Pour l'instant, il n'a qu'une route : `GET /health`, interrogée par le voyant des
Réglages de l'app.

## Le chemin d'une requête

```
iPhone ──HTTPS──▶ Tailscale (Windows) ── tailscale serve ──▶ localhost:8000 ──▶ uvicorn (WSL2)
```

- **Tailscale tourne sous Windows**, pas dans WSL2. `tailscale serve` reçoit les
  requêtes du réseau Tailscale en HTTPS, avec un vrai certificat `*.ts.net`, et les
  passe à `localhost:8000`.
- **Windows transmet son `localhost` à WSL2.** C'est le réglage par défaut de WSL2
  (`localhostForwarding`). Le serveur n'a donc pas à s'ouvrir sur le réseau, et le
  mode `mirrored` est inutile.
- **Le HTTPS est fourni par Tailscale.** iOS refuse le HTTP simple vers une adresse
  qui n'est pas locale, et l'app n'a donc aucune exception à déclarer.
- **Pas de mot de passe** : seuls les appareils de ton réseau Tailscale voient le
  serveur.

## Installation (une fois)

### 1. Tailscale

1. Installe Tailscale sur Windows et sur l'iPhone, avec le même compte.
2. Dans la console d'administration (login.tailscale.com, onglet DNS), active
   **MagicDNS** et **HTTPS Certificates**.
3. Le nom du PC dans Tailscale apparaît dans la console, sous la forme
   `nom-du-pc.nom-du-reseau.ts.net`. C'est l'adresse à donner à l'app.

### 2. Le serveur, dans WSL2

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh   # si uv n'est pas installé
cd assimil-learning/server
uv sync
uv run pytest -q                                   # 3 tests
```

### 3. L'exposer par Tailscale, dans PowerShell (Windows)

```powershell
tailscale serve --bg 8000
tailscale serve status    # doit montrer https://nom-du-pc....ts.net -> http://127.0.0.1:8000
```

`--bg` garde le réglage après un redémarrage. Pour le retirer : `tailscale serve --https=443 off`.

## Lancer le serveur

Dans WSL2 :

```bash
cd assimil-learning/server
uv run uvicorn app.main:app --host 127.0.0.1 --port 8000
```

Vérifier, du plus proche au plus loin :

1. **Dans WSL2** : `curl localhost:8000/health`
2. **Sous Windows** (PowerShell) : `curl.exe http://localhost:8000/health`. Si ça
   échoue alors que l'étape 1 marche, relance le serveur avec `--host 0.0.0.0`.
3. **Sur l'iPhone**, Tailscale allumé, dans Safari : `https://nom-du-pc.nom-du-reseau.ts.net/health`
4. **Dans l'app** : Réglages, Serveur, tu saisis l'adresse, et le voyant passe au vert.

Refais l'étape 3 en 4G ou en 5G, Wi-Fi coupé : c'est le cas « de n'importe où ».

La réponse ressemble à :

```json
{"status": "ok", "version": "0.1.0", "api": 1, "gpu": "NVIDIA GeForce RTX 5070 Ti"}
```

`gpu` vaut `null` quand `nvidia-smi` ne répond pas dans WSL2. Dans ce cas, le pilote
NVIDIA de Windows n'est pas vu, et les modèles tourneront sur le processeur.

## Essais de modèles

`essais/` mesure un modèle avant de le brancher sur l'app : `essais/README.md`.

## Tests

```bash
uv run pytest -q
```
