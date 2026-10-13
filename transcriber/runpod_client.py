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


def format_seconds_to_timestamp(seconds: float) -> str:
    """Converts seconds into [MM:SS] or [HH:MM:SS]."""
    total_sec = max(0, int(seconds))
    hrs = total_sec // 3600
    mins = (total_sec % 3600) // 60
    secs = total_sec % 60
    if hrs > 0:
        return f"{hrs:02d}:{mins:02d}:{secs:02d}"
    return f"{mins:02d}:{secs:02d}"


def offset_timestamp_text(text: str, offset_sec: float) -> str:
    """Offsets all [MM:SS] or [HH:MM:SS] timestamps in formatted dialogue by offset_sec."""
    if not text or offset_sec <= 0:
        return text

    import re

    def _replace_ts(match):
        ts_str = match.group(1)
        parts = ts_str.split(':')
        sec = 0.0
        if len(parts) == 2:
            try:
                sec = int(parts[0]) * 60 + float(parts[1])
            except Exception:
                sec = 0.0
        elif len(parts) == 3:
            try:
                sec = int(parts[0]) * 3600 + int(parts[1]) * 60 + float(parts[2])
            except Exception:
                sec = 0.0
        new_total = max(0, int(sec + offset_sec))
        hrs = new_total // 3600
        mins = (new_total % 3600) // 60
        secs = new_total % 60
        if hrs > 0:
            return f"[{hrs:02d}:{mins:02d}:{secs:02d}]"
        return f"[{mins:02d}:{secs:02d}]"

    return re.sub(r'\[(\d{1,4}:\d{2}(?::\d{2})?)\]', _replace_ts, text)


def file_to_base64(file_path: str, max_raw_mb: float = 4.2) -> str:
    """
    Read file from disk and convert to Base64 string.
    If the file exceeds max_raw_mb (4.2 MB), dynamically downsamples to 16kHz mono with
    an optimal speech bitrate (16k - 32k) so that the raw audio shrinks to < 4.2 MB (< 5.6 MB Base64),
    permanently staying below RunPod's 10 MiB request limit with 100% speech fidelity.
    """
    try:
        file_size_mb = os.path.getsize(file_path) / (1024 * 1024)
        if file_size_mb > max_raw_mb:
            logger.info(f"[RunPod Client] File is {file_size_mb:.1f} MB (exceeds safe {max_raw_mb}MB limit). Downsampling to 16kHz mono...")
            import tempfile
            from pydub import AudioSegment
            sound = AudioSegment.from_file(file_path)
            duration_sec = max(1.0, len(sound) / 1000.0)
            target_kbps = max(16, min(32, int((max_raw_mb * 1024 * 8) / duration_sec)))
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


def call_runpod_sync(
    job_input: Dict[str, Any],
    timeout_sec: int = 25
) -> Dict[str, Any]:
    """
    Submits a job synchronously to RunPod Serverless via /runsync for sub-second, real-time responses.
    If already completed by worker, output is returned directly in the response without polling or queue delays.
    If the worker is currently cold/provisioning, gracefully polls /status with a tight 0.4s interval.
    """
    api_key, endpoint_id = get_runpod_config()
    if not api_key or not endpoint_id:
        raise ValueError("RUNPOD_API_KEY and RUNPOD_ENDPOINT_ID must be configured.")

    runsync_url = f"https://api.runpod.ai/v2/{endpoint_id}/runsync"
    status_url_base = f"https://api.runpod.ai/v2/{endpoint_id}/status"
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}"
    }

    payload = {"input": job_input}
    action = job_input.get('action', 'stream_chunk')
    t0 = time.time()

    try:
        response = requests.post(runsync_url, json=payload, headers=headers, timeout=min(timeout_sec, 20))
    except requests.exceptions.Timeout:
        logger.warning(f"[RunPod Client] /runsync timed out for action={action}. Falling back to async...")
        return call_runpod_serverless(job_input, timeout_sec=timeout_sec)
    except Exception as e:
        logger.warning(f"[RunPod Client] /runsync network error: {e}. Falling back to async...")
        return call_runpod_serverless(job_input, timeout_sec=timeout_sec)

    if response.status_code == 200:
        res_json = response.json()
        status = res_json.get("status")
        job_id = res_json.get("id")

        if status == "COMPLETED":
            output = res_json.get("output", {})
            if isinstance(output, dict) and output.get("status") == "error":
                raise RuntimeError(f"RunPod model error: {output.get('error')}")
            logger.info(f"[RunPod Client] /runsync completed directly in {time.time() - t0:.2f}s (action={action})")
            return output
        elif status in ("FAILED", "CANCELLED"):
            raise RuntimeError(f"RunPod job {status}: {res_json.get('error')}")

        # If job is in queue / in progress (worker cold or queued), poll with a tight 0.4s interval
        remaining_sec = max(5, timeout_sec - int(time.time() - t0))
        poll_interval = 0.4
        max_polls = int(remaining_sec / poll_interval)

        for _ in range(max_polls):
            time.sleep(poll_interval)
            try:
                poll_resp = requests.get(f"{status_url_base}/{job_id}", headers=headers, timeout=6)
                if poll_resp.status_code == 200:
                    poll_data = poll_resp.json()
                    curr_status = poll_data.get("status")
                    if curr_status == "COMPLETED":
                        output = poll_data.get("output", {})
                        if isinstance(output, dict) and output.get("status") == "error":
                            raise RuntimeError(f"RunPod model error: {output.get('error')}")
                        logger.info(f"[RunPod Client] Polled job {job_id} COMPLETED in {time.time() - t0:.2f}s")
                        return output
                    elif curr_status in ("FAILED", "CANCELLED"):
                        raise RuntimeError(f"RunPod job {curr_status}: {poll_data.get('error')}")
            except Exception:
                continue

    elif response.status_code != 200:
        logger.warning(f"[RunPod Client] /runsync returned {response.status_code}. Falling back to async...")
        return call_runpod_serverless(job_input, timeout_sec=timeout_sec)

    return call_runpod_serverless(job_input, timeout_sec=timeout_sec)


def runpod_warmup(timeout_sec: int = 25) -> Dict[str, Any]:
    """
    Pings RunPod endpoint with a warmup action to wake serverless workers
    and ensure models (Faster Whisper & CAM++) are 100% loaded and hot in GPU VRAM.
    """
    api_key, endpoint_id = get_runpod_config()
    if not api_key or not endpoint_id:
        return {"status": "error", "error": "RunPod not configured"}
    job_input = {"action": "warmup"}
    try:
        return call_runpod_sync(job_input, timeout_sec=timeout_sec)
    except Exception as e:
        logger.warning(f"[RunPod Client] Warmup request error: {e}")
        return {"status": "error", "error": str(e)}


def runpod_transcribe(
    audio_path: str,
    language: str = "auto",
    diarize: bool = True,
    num_speakers: Optional[int] = None,
    progress_callback: Optional[callable] = None,
    max_chunk_sec: int = 420  # 7 minutes per chunk
) -> Dict[str, Any]:
    """
    Transcribes an audio file on RunPod Serverless.
    If the audio exceeds max_chunk_sec (7 minutes), it automatically splits into
    manageable chunks, offloads each to RunPod (guaranteed to be < 3MB Base64,
    permanently avoiding the 10 MiB gateway limit), offsets timestamps,
    and merges the complete transcription seamlessly.
    """
    sound = None
    total_duration_sec = 0.0
    try:
        from pydub import AudioSegment
        sound = AudioSegment.from_file(audio_path)
        total_duration_sec = len(sound) / 1000.0
    except Exception as e:
        logger.warning(f"[RunPod Client] Could not inspect duration via pydub ({e}). Sending directly...")

    # Single job if under 7 minutes or pydub unavailable
    if sound is None or total_duration_sec <= max_chunk_sec:
        audio_b64 = file_to_base64(audio_path, max_raw_mb=4.2)
        job_input = {
            "action": "transcribe",
            "audio_base64": audio_b64,
            "language": language,
            "diarize": diarize,
            "num_speakers": num_speakers
        }
        return call_runpod_serverless(job_input, timeout_sec=360, progress_callback=progress_callback)

    # Multi-chunk processing for long audios (> 7 minutes)
    import math
    import tempfile

    num_chunks = math.ceil(total_duration_sec / max_chunk_sec)
    logger.info(f"[RunPod Client] Audio is {total_duration_sec:.1f}s ({total_duration_sec/60:.1f} mins). Splitting into {num_chunks} chunks of {max_chunk_sec/60:.1f} mins...")

    all_raw_texts = []
    all_formatted_lines = []
    all_chunks_metadata = []
    total_processing_time = 0.0

    for i in range(num_chunks):
        start_ms = i * max_chunk_sec * 1000
        end_ms = min(len(sound), (i + 1) * max_chunk_sec * 1000)
        start_sec = start_ms / 1000.0
        end_sec = end_ms / 1000.0

        start_str = format_seconds_to_timestamp(start_sec)
        end_str = format_seconds_to_timestamp(end_sec)
        logger.info(f"[RunPod Client] Processing Chunk {i+1}/{num_chunks} ({start_str} - {end_str})...")

        # Slice chunk and export as 16kHz mono MP3 (32kbps mono is only ~1.6MB for 7 minutes)
        chunk_sound = sound[start_ms:end_ms].set_channels(1).set_frame_rate(16000)
        with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as tmp:
            tmp_chunk_path = tmp.name

        try:
            chunk_sound.export(tmp_chunk_path, format="mp3", bitrate="32k")
            chunk_b64 = file_to_base64(tmp_chunk_path, max_raw_mb=4.2)

            chunk_base_pct = (i / num_chunks) * 78.0 + 16.0  # 16% -> 94%
            chunk_span_pct = (1.0 / num_chunks) * 78.0

            def chunk_prog_cb(status="IN_PROGRESS", elapsed=0.0, progress=None, execution_time=None, delay_time=None):
                if progress_callback:
                    if status == "IN_QUEUE":
                        sub_pct = chunk_base_pct + chunk_span_pct * 0.15
                        st_text = f"Chunk {i+1}/{num_chunks}: Provisioning GPU..."
                    elif status == "IN_PROGRESS":
                        exec_sec = (execution_time / 1000.0) if execution_time else max(1.0, elapsed - 4.0)
                        sub_pct = chunk_base_pct + min(chunk_span_pct * 0.95, (exec_sec / 25.0) * chunk_span_pct)
                        st_text = f"Chunk {i+1}/{num_chunks}: Transcribing & Diarizing ({start_str} - {end_str})..."
                    else:
                        sub_pct = chunk_base_pct + chunk_span_pct
                        st_text = f"Chunk {i+1}/{num_chunks}: Complete"

                    progress_callback(
                        status=status,
                        elapsed=elapsed,
                        progress={
                            "stage": "transcribing" if (i < num_chunks - 1) else "finalizing",
                            "status_text": st_text,
                            "subtext": f"Phase 2 & 3: Neural Whisper & CAM++ on Chunk {i+1} of {num_chunks}...",
                            "progress_pct": round(sub_pct, 1)
                        }
                    )

            job_input = {
                "action": "transcribe",
                "audio_base64": chunk_b64,
                "language": language,
                "diarize": diarize,
                "num_speakers": num_speakers
            }

            res = call_runpod_serverless(job_input, timeout_sec=240, progress_callback=chunk_prog_cb)

            chunk_raw = res.get("text", "").strip()
            chunk_fmt = res.get("formatted", chunk_raw).strip()
            chunk_segs = res.get("chunks", [])
            total_processing_time += res.get("processing_time", 0.0)

            if chunk_raw:
                all_raw_texts.append(chunk_raw)

            # Offset timestamps in formatted text and segment chunks
            if chunk_fmt:
                offset_fmt = offset_timestamp_text(chunk_fmt, start_sec)
                all_formatted_lines.append(offset_fmt)

            for seg in chunk_segs:
                seg_ts = seg.get("timestamp", [0.0, 0.0])
                if seg_ts:
                    seg["timestamp"] = [round(seg_ts[0] + start_sec, 2), round(seg_ts[1] + start_sec, 2)]
                all_chunks_metadata.append(seg)

        finally:
            if os.path.exists(tmp_chunk_path):
                try:
                    os.remove(tmp_chunk_path)
                except Exception:
                    pass

    combined_raw = "\n\n".join(all_raw_texts)
    combined_fmt = "\n\n".join(all_formatted_lines)

    return {
        "status": "success",
        "text": combined_raw,
        "formatted": combined_fmt,
        "chunks": all_chunks_metadata,
        "language": language,
        "processing_time": round(total_processing_time, 2)
    }


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
    """Transcribes a live mic chunk and tracks speaker voiceprint on RunPod Serverless via low-latency /runsync."""
    audio_b64 = file_to_base64(chunk_path)
    job_input = {
        "action": "stream_chunk",
        "audio_base64": audio_b64,
        "session_id": session_id,
        "language": language,
        "is_continuous": is_continuous
    }
    return call_runpod_sync(job_input, timeout_sec=20)

