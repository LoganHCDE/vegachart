# VegaChart (Flask + Python/R Chart Generation Service)

VegaChart is a lightweight Flask-based API service that executes user-provided Python (matplotlib / seaborn) or R (ggplot2) plotting code and returns a rendered PNG image. It is designed for an interactive front‑end that sends chart code and optional tabular data (CSV) to the backend for rapid visualization prototyping.

The application supports:
- Dynamic Python plotting code execution (matplotlib / seaborn / pandas)
- Dynamic R ggplot2 execution via an isolated runner script (`run_r_script.r`)
- Optional CSV data injection (passed inline from the client)
- Customizable image & chart background themes
- Optional panel grid line toggling (R path)
- Feedback + lightweight analytics endpoints (PostgreSQL optional)
- Containerized deployment (Docker) + Heroku runtime configuration

> IMPORTANT: This service executes arbitrary code. Treat it as an internal/tooling component. Never expose it publicly without strong sandboxing, auth, rate-limits, and resource constraints.

---
## Table of Contents
1. Features
2. Architecture Overview
3. API Reference
4. Background / Theming Options
5. Environment Variables
6. Local Development
7. Running with Docker
8. Deploying to Heroku
9. (Optional) Fly.io Notes
10. Database (PostgreSQL) Usage
11. Security Considerations
12. Troubleshooting
13. Future Improvements
14. License

---
## 1. Features
- Dual-language chart execution: Python (`matplotlib`) and R (`ggplot2`).
- In-memory PNG generation (no temp files for Python path; R uses temp dir).
- CSV injection: server swaps user `read_csv` calls (Python) or loads a df in R.
- Theme mapping for image background vs chart panel background.
- Graceful fallback if `DATABASE_URL` is not set (feedback endpoints degrade politely).
- Structured logging for execution timing + process diagnostics.

---
## 2. Architecture Overview

```
Client (Browser / App)
  | JSON: { language, code, data (CSV), imgBgChoice, chartBgChoice, showGridLines }
  v
Flask API (/api/generate-chart)
  |-- Python path → in‑process exec() of sanitized/injected code
  |-- R path      → writes code & data to temp dir → invokes Rscript runner
  v
PNG Buffer → HTTP Response (image/png base64 or binary depending on client usage)

Optional PostgreSQL (feedback / analytics) via psycopg2 pool
```

Components:
- `app.py` — Flask app, endpoints, Python execution logic, DB pool.
- `run_r_script.r` — Robust ggplot2 executor: theming, error cleaning, safe loading.
- `Dockerfile` — Multi-stage style base build (Python + system deps + R toolchain).
- `heroku.yml` — Declarative container deployment for Heroku (uses Dockerfile).

---
## 3. API Reference

### POST `/api/generate-chart`
Generate a chart from user code.

Request (JSON):
```
{
  "language": "python" | "r",
  "code": "<plotting code>",
  "data": "col1,col2\n1,2\n3,4\n",          // optional CSV text
  "imgBgChoice": "dark" | "white" | "blue" | "transparent" | ...,
  "chartBgChoice": "white" | "teal" | ... ,   // optional (panel background override)
  "showGridLines": true | false               // R only (optional)
}
```
Successful Response (JSON example – adjust to your client spec):
```
{
  "status": "ok",
  "image": "data:image/png;base64,...."  // or raw bytes if configured
}
```
Error Response:
```
{
  "status": "error",
  "message": "Human-readable explanation"
}
```
Notes:
- Python path auto-injects a save snippet if `plt.show()` omitted.
- R path expects a ggplot object named `p` (the runner enforces this).

### POST `/api/submit-feedback`
Stores user feedback (text + optional metadata).

Request JSON (example):
```
{
  "rating": 5,
  "comment": "Loved the dark theme.",
  "context": { "chartType": "scatter" }
}
```
Responses:
- 200 JSON `{ "status": "stored" }` if DB available.
- 503 / graceful JSON fallback if `DATABASE_URL` not configured.

### POST `/api/track-event`
Lightweight analytics event logging.

Request JSON:
```
{ "event": "chart_render", "meta": { "language": "python" } }
```
Responses similar to feedback endpoint.

### GET `/` and Static Assets
Serves `chart.html` (if present) and any static file from project root.

---
## 4. Background / Theming Options
Two theme layers:
- Image background (overall canvas / PNG background).
- Chart panel background (R + Python injection logic; panel vs figure distinction).

Common choices (subset): `transparent`, `white`, `blue`, `green`, `yellow`, `orange`, `purple`, `teal`, `default` (dark). If `chartBgChoice` omitted, logic may reuse image background or fall back to dark.

R runner resolves:
- Image text color & transparency.
- Panel fill, grid line color, conditional grid toggling.

---
## 5. Environment Variables
| Variable        | Description | Default / Required |
|-----------------|-------------|--------------------|
| `PORT`          | Port for Gunicorn/Flask (Heroku provides) | 8080 locally |
| `DATABASE_URL`  | PostgreSQL connection string | Optional (disables feedback/events if absent) |
| `PYTHONUNBUFFERED` | Ensures real-time logging | `1` |
| `PYTHONDONTWRITEBYTECODE` | Avoids `.pyc` creation | `1` |

For local Postgres you can set (example):
```
DATABASE_URL=postgresql://user:pass@localhost:5432/vegachart
```

---
## 6. Local Development
### Prerequisites
- Python 3.11+
- (Optional) R installation with `ggplot2`, `readr`, etc., if you want R path locally.

### Setup
```
python -m venv .venv
.venv\Scripts\activate          # Windows
pip install --upgrade pip
pip install -r requirements.txt
set FLASK_ENV=development        # (optional for debug)
python app.py
```
Visit: http://localhost:8080/

### Testing R Execution Locally
If you have R installed:
```
Rscript run_r_script.r  # (will show usage error, but confirms Rscript availability)
```
Then POST to `/api/generate-chart` with `language: "r"`.

---
## 7. Running with Docker
Build & run (local):
```
docker build -t vegachart .
docker run -p 8080:8080 vegachart
```
Add DB:
```
docker run -e DATABASE_URL=postgresql://... -p 8080:8080 vegachart
```

---
## 8. Deploying to Heroku
This repo includes a `heroku.yml` for container deployment.

Steps:
1. Enable container stack: `heroku stack:set container -a <app-name>`
2. Push: `git push heroku main`
3. Heroku will build via Dockerfile and run: `gunicorn --bind 0.0.0.0:$PORT ...`

Ensure a Postgres addon if you want persistence:
```
heroku addons:create heroku-postgresql:mini -a <app-name>
```
Heroku sets `DATABASE_URL` automatically.

---
## 9. (Optional) Fly.io Notes
Code references Fly.io (comment about `DATABASE_URL`). To deploy to Fly:
```
fly launch        # generates fly.toml (if not present)
fly deploy
```
Attach Postgres: `fly postgres create` + `fly postgres attach` to set `DATABASE_URL`.

---
## 10. Database (PostgreSQL) Usage
- Connection pooling via `psycopg2.pool.SimpleConnectionPool(1, 20)`.
- Disabled gracefully if `DATABASE_URL` missing (feedback/events endpoints return fallback JSON or error status). 
- Ensure proper migrations / table creation (not included here). You must create tables manually (e.g., `feedback`, `events`). Example quick schema:
```
CREATE TABLE feedback (
  id SERIAL PRIMARY KEY,
  rating INT,
  comment TEXT,
  context JSONB,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE events (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  meta JSONB,
  created_at TIMESTAMPTZ DEFAULT now()
);
```

---
## 11. Security Considerations
| Risk | Mitigation Ideas (Not Implemented) |
|------|------------------------------------|
| Arbitrary code execution | Use container isolation per request, time & memory limits, seccomp, firejail, or remote sandbox. |
| Denial of service (infinite loops) | Execution timeouts (Python manual, R subprocess timeout). Add CPU quotas. |
| Data exfiltration | Block network egress in runtime container. |
| File system access | Run as non-root (`appuser`), restrict mounts, consider read-only FS. |
| Excessive memory (large figures) | Enforce max CSV size & code length pre-check. |

DO NOT expose this API publicly until hardened.

---
## 12. Troubleshooting
| Symptom | Possible Cause | Fix |
|---------|----------------|-----|
| R timeout | Long-running plot | Simplify code; adjust timeout in `subprocess.run(...)`. |
| Empty image | User code never created a figure (Python) | Auto-fallback creates blank; ensure `plt.plot(...)`. |
| "Missing R package" | R lib not installed inside container | Modify Dockerfile R install list. |
| DB errors | `DATABASE_URL` unset or wrong | Export correct connection string. |
| Heroku crash (memory) | R build size | Reduce R packages to essential subset. |

Logs (Python): execution timing prefixed with `[PYEXEC]` / `[REXEC]`.

---
## 13. Future Improvements
- Add unit tests & CI.
- Implement code sandboxing (Firecracker / gVisor).
- Stream image generation progress/events.
- Add SVG output option.
- Rate limiting & authentication (API key or OAuth). 
- Structured error codes for front-end mapping.

---
## 14. License
No explicit license file provided. Consider adding an open-source license (e.g., MIT, Apache-2.0) if you intend to share publicly.

---
## Quick Reference
| Item | Location |
|------|----------|
| Flask App | `app.py` |
| R Runner | `run_r_script.r` |
| Container Spec | `Dockerfile` |
| Heroku Config | `heroku.yml` |
| Python Deps | `requirements.txt` |

---
Feel free to adapt this README as the project evolves. Contributions and hardening steps are strongly encouraged before any public exposure.
