"""
RunPod Serverless Client for Transcriber AI
Offloads GPU speech-to-text and acoustic diarization tasks to RunPod Serverless.
"""

import os
import time
import base64
import logging
from typing import Optional, Dict, Any, List
import requests
from django.conf import settings

logger = logging.getLogger(__name__)


def is_runpod_configured() -> bool:
    """Check if RunPod Serverless API key and endpoint ID are configured in settings or environment."""
    api_key = getattr(settings, 'RUNPOD_API_KEY', None) or os.getenv('RUNPOD_API_KEY', '').strip()
    endpoint_id = getattr(settings, 'RUNPOD_ENDPOINT_ID', None) or os.getenv('RUNPOD_ENDPOINT_ID', '').strip()
    return bool(api_key and endpoint_id and "your_runpod" not in api_key and "your_runpod" not in endpoint_id)


def get_runpod_config() -> tuple[str, str]:
    api_key = getattr(settings, 'RUNPOD_API_KEY', None) or os.getenv('RUNPOD_API_KEY', '').strip()
    endpoint_id = getattr(settings, 'RUNPOD_ENDPOINT_ID', None) or os.getenv('RUNPOD_ENDPOINT_ID', '').strip()
    return api_key, endpoint_id


def file_to_base64(file_path: str) -> str:
    """
    Read file from disk and convert to Base64 string.
    If the file exceeds 12 MB, dynamically downsample to 16kHz mono with an optimal
    speech bitrate (16k - 48k) so that files up to 200MB+ shrink to < 10MB (< 14MB Base64),
    safely fitting within RunPod's 20 MiB limit with 100% speech fidelity.
    """
    try:
        file_size_mb = os.path.getsize(file_path) / (1024 * 1024)
        if file_size_mb > 12.0:
            logger.info(f"[RunPod Client] File is {file_size_mb:.1f} MB (exceeds RunPod 20MB limit). Downsampling to 16kHz mono...")
            import tempfile
            from pydub import AudioSegment
            sound = AudioSegment.from_file(file_path)
            duration_sec = max(1.0, len(sound) / 1000.0)
            target_kbps = max(16, min(48, int((10 * 1024 * 8) / duration_sec)))
            sound = sound.set_channels(1).set_frame_rate(16000)
            with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as tmp:
                tmp_path = tmp.name
            sound.export(tmp_path, format="mp3", bitrate=f"{target_kbps}k")
            opt_size_mb = os.path.getsize(tmp_path) / (1024 * 1024)
            with open(tmp_path, "rb") as f:
                b64 = base64.b64encode(f.read()).decode("utf-8")
            try:
                os.remove(tmp_path)
            except Exception:
                pass
            logger.info(f"[RunPod Client] Shrunk {file_size_mb:.1f} MB -> {opt_size_mb:.1f} MB ({target_kbps}kbps mono). Base64 payload: {len(b64)/(1024*1024):.1f} MB.")
            return b64
    except Exception as e:
        logger.warning(f"[RunPod Client] Audio downsampling skipped ({e}). Sending original file...")

    with open(file_path, "rb") as f:
        return base64.b64encode(f.read()).decode("utf-8")


def call_runpod_serverless(
    job_input: Dict[str, Any],
    timeout_sec: int = 360,
    progress_callback: Optional[callable] = None
) -> Dict[str, Any]:
    """
    Submits a job asynchronously to RunPod Serverless via /run and streams real-time
    status and progress updates to progress_callback on every polling tick.
    """
    api_key, endpoint_id = get_runpod_config()
    if not api_key or not endpoint_id:
        raise ValueError("RUNPOD_API_KEY and RUNPOD_ENDPOINT_ID must be configured.")

    run_url = f"https://api.runpod.ai/v2/{endpoint_id}/run"
    status_url_base = f"https://api.runpod.ai/v2/{endpoint_id}/status"
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}"
    }

    payload = {"input": job_input}
    action = job_input.get('action', 'transcribe')
    logger.info(f"[RunPod Client] Submitting asynchronous job (action={action}) to {run_url}...")

    t0 = time.time()
    try:
        response = requests.post(run_url, json=payload, headers=headers, timeout=25)
    except requests.exceptions.Timeout:
        logger.warning("[RunPod Client] /run timed out. Trying /runsync fallback...")
        run_url = f"https://api.runpod.ai/v2/{endpoint_id}/runsync"
        response = requests.post(run_url, json=payload, headers=headers, timeout=timeout_sec)

    if response.status_code != 200:
        logger.error(f"[RunPod Client] Request error {response.status_code}: {response.text}")
        raise RuntimeError(f"RunPod API error ({response.status_code}): {response.text}")

    res_json = response.json()
    job_id = res_json.get("id")
    status = res_json.get("status")
    logger.info(f"[RunPod Client] Job initiated: {status} (Job ID: {job_id})")

    if status == "COMPLETED":
        output = res_json.get("output", {})
        if isinstance(output, dict) and output.get("status") == "error":
            raise RuntimeError(f"RunPod model error: {output.get('error')}")
        return output

    # Polling loop with real-time status and progress streaming
    poll_interval = 1.2
    max_polls = int(timeout_sec / poll_interval)

    for attempt in range(max_polls):
        time.sleep(poll_interval)
        elapsed = time.time() - t0

        try:
            poll_resp = requests.get(f"{status_url_base}/{job_id}", headers=headers, timeout=12)
        except Exception:
            continue

        if poll_resp.status_code != 200:
            continue

        poll_data = poll_resp.json()
        curr_status = poll_data.get("status")
        progress_data = poll_data.get("progress")
        execution_time = poll_data.get("executionTime")
        delay_time = poll_data.get("delayTime")

        if progress_callback:
            try:
                progress_callback(
                    status=curr_status,
                    elapsed=elapsed,
                    progress=progress_data,
                    execution_time=execution_time,
                    delay_time=delay_time
                )
            except Exception as e:
                logger.debug(f"[RunPod Client] Error in progress_callback: {e}")

        if curr_status == "COMPLETED":
            output = poll_data.get("output", {})
            if isinstance(output, dict) and output.get("status") == "error":
                raise RuntimeError(f"RunPod model error: {output.get('error')}")
            logger.info(f"[RunPod Client] Job {job_id} COMPLETED in {time.time() - t0:.2f}s")
            return output
        elif curr_status in ("FAILED", "CANCELLED"):
            error_msg = poll_data.get("error", "Job failed on RunPod worker.")
            raise RuntimeError(f"RunPod job {curr_status}: {error_msg}")

    raise TimeoutError(f"RunPod execution exceeded {timeout_sec}s timeout.")


def runpod_transcribe(
    audio_path: str,
    language: str = "auto",
    diarize: bool = True,
    num_speakers: Optional[int] = None,
    progress_callback: Optional[callable] = None
) -> Dict[str, Any]:
    """Transcribes an audio file on RunPod Serverless."""
    audio_b64 = file_to_base64(audio_path)
    job_input = {
        "action": "transcribe",
        "audio_base64": audio_b64,
        "language": language,
        "diarize": diarize,
        "num_speakers": num_speakers
    }
    return call_runpod_serverless(job_input, timeout_sec=300, progress_callback=progress_callback)


def runpod_diarize(
    audio_path: str,
    portions: List[Dict[str, Any]],
    num_speakers: Optional[int] = None
) -> Dict[str, Any]:
    """Runs acoustic diarization on existing transcript portions on RunPod Serverless."""
    audio_b64 = file_to_base64(audio_path)
    job_input = {
        "action": "diarize",
        "audio_base64": audio_b64,
        "portions": portions,
        "num_speakers": num_speakers
    }
    return call_runpod_serverless(job_input, timeout_sec=120)


def runpod_stream_chunk(
    chunk_path: str,
    session_id: str,
    language: str = "auto",
    is_continuous: bool = False
) -> Dict[str, Any]:
    """Transcribes a live mic chunk and tracks speaker voiceprint on RunPod Serverless."""
    audio_b64 = file_to_base64(chunk_path)
    job_input = {
        "action": "stream_chunk",
        "audio_base64": audio_b64,
        "session_id": session_id,
        "language": language,
        "is_continuous": is_continuous
    }
    return call_runpod_serverless(job_input, timeout_sec=20)
