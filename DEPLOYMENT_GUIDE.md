# Transcriber AI: Production Railway Deployment Guide

This guide details how to deploy the **Transcriber AI** full-stack web application to **Railway** and connect it to your live **RunPod Serverless GPU worker**.

---

## 🏗️ Architecture

```
                      +-----------------------------+
                      |       User / Browser        |
                      +--------------+--------------+
                                     |
                                     v HTTPS
                      +-----------------------------+
                      |       Railway (Django)      |
                      | - Authentication & History  |
                      | - PostgreSQL Database       |
                      | - Audio Ingestion & UI      |
                      | - Gemini AI Co-Pilot        |
                      +--------------+--------------+
                                     |
                                     v HTTPS REST API (RunPod SDK)
                      +-----------------------------+
                      |   RunPod Serverless (GPU)   |
                      | - allandclive Luganda Whisper|
                      | - Faster-Whisper (Medium)   |
                      | - Alibaba CAM++ Diarization |
                      +-----------------------------+
```

- **Frontend & Backend (Railway)**: GitHub repo: [kyangwi/transcriber-production](https://github.com/kyangwi/transcriber-production)
- **Model Worker (RunPod Serverless)**: GitHub repo: [kyangwi/transcriber-luganda-worker](https://github.com/kyangwi/transcriber-luganda-worker)

---

## 🚀 Step-by-Step Railway Deployment

### Step 1: Push Code to GitHub Production Repo

From your project directory:

```bash
git add .
git commit -m "Production release: Wire frontend and backend with RunPod Serverless GPU and Railway"
git push -u origin main
```

*(Repository: `https://github.com/kyangwi/transcriber-production`)*

---

### Step 2: Create a New Project on Railway

1. Go to [Railway.app](https://railway.app/) and sign in with your GitHub account.
2. Click **+ New Project**.
3. Select **Deploy from GitHub repo**.
4. Choose `kyangwi/transcriber-production`.
5. Railway will automatically detect `railway.json` and `nixpacks.toml`, setting up Python 3.12, `ffmpeg`, and `libsndfile`.

---

### Step 3: Add PostgreSQL Database

1. In your Railway project canvas, click **+ Create** or **+ New** (top-right or canvas empty area).
2. Select **Database** -> **Add PostgreSQL**.
3. Railway will provision a managed PostgreSQL database.
4. **Zero Configuration Needed**: Railway automatically sets the `DATABASE_URL` variable in your project, which `settings.py` (via `dj-database-url`) instantly uses for migrations and user data!

---

### Step 4: Configure Environment Variables on Railway

In Railway, click your web service card -> navigate to the **Variables** tab -> click **New Variable** (or **Raw Editor**) and add:

| Variable | Value | Purpose |
| :--- | :--- | :--- |
| `RUNPOD_API_KEY` | `rpa_...` | Your RunPod API Key |
| `RUNPOD_ENDPOINT_ID` | `ufzh2q6pwxjbbr` | Your verified RunPod Serverless Endpoint ID |
| `GEMINI_API_KEY` | `AIza...` | Google Gemini API Key (for AI Co-Pilot and Q&A) |
| `SECRET_KEY` | `(generate any random 50-character string)` | Django security key |
| `DEBUG` | `False` | Production mode |
| `ALLOWED_HOSTS` | `*` | Allows traffic through Railway domains |
| `CSRF_TRUSTED_ORIGINS` | `https://*.railway.app,https://*.up.railway.app` | Prevents CSRF errors on form submissions |

> **Note**: `DATABASE_URL` is already automatically injected by the PostgreSQL service.

---

### Step 5: Generate a Public Domain

1. In Railway, click your web service card -> go to the **Settings** tab.
2. Scroll down to the **Networking** section.
3. Click **Generate Domain** (e.g. `transcriber-production.up.railway.app`).
4. Click the generated link once deployment finishes (typically 1–2 minutes).

---

## ⚙️ How the Automated Build & Run Works

- **Build Phase**: Railway runs `pip install -r requirements.txt` and `python manage.py collectstatic --noinput` via WhiteNoise.
- **Start Phase**: Railway executes `python manage.py migrate --noinput` and launches Gunicorn on `$PORT` with 2 workers and a 300-second timeout.
- **Audio Handling (Strategy 1)**: For files up to 200MB+, `runpod_client.py` uses dynamic 16kHz speech downsampling to ensure the payload stays under RunPod's 20 MiB API Gateway limit with 100% speech fidelity.
- **Models**:
  - **Luganda**: `allandclive/whisper-medium-luganda` with Swahili tokenizer (`<|sw|>`).
  - **English / Other Languages**: Faster-Whisper `medium`.
  - **Diarization**: Alibaba CAM++ (`cam++`) sentence-level speaker embedding clustering.
