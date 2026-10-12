import logging

logging.basicConfig(level=logging.DEBUG, format='[%(levelname)s] %(asctime)s %(module)s: %(message)s')
import uuid
import json
import sqlite3
import os
import shutil
import time
import re
import threading
from django.shortcuts import render
from django.http import JsonResponse, HttpResponse
from django.views.decorators.csrf import csrf_exempt
from django.conf import settings
from django.contrib.auth import authenticate, login, logout
from django.contrib.auth.models import User
from .models import Transcription
from .runpod_client import (
    is_runpod_configured,
    runpod_transcribe,
    runpod_diarize,
    runpod_stream_chunk,
)

try:
    import torch
except ImportError:
    torch = None

try:
    from .stt_service import stt_service, streaming_speaker_tracker, filter_streaming_hallucinations
    from .diarization_service import acoustic_diarization_service, format_seconds_to_timestamp
except ImportError:
    stt_service = None
    streaming_speaker_tracker = None
    acoustic_diarization_service = None

    def format_seconds_to_timestamp(seconds: float) -> str:
        total_sec = max(0, int(seconds))
        hrs = total_sec // 3600
        mins = (total_sec % 3600) // 60
        secs = total_sec % 60
        if hrs > 0:
            return f"{hrs:02d}:{mins:02d}:{secs:02d}"
        return f"{mins:02d}:{secs:02d}"

    def filter_streaming_hallucinations(text: str) -> str:
        if not text:
            return ""
        return text.strip()

try:
    import moviepy as mp
except ImportError:
    mp = None

try:
    from pytube import YouTube
except ImportError:
    YouTube = None

try:
    from pydub import AudioSegment
except ImportError:
    AudioSegment = None

# ====== DIRECTORY CONFIGURATION ======
BASE_DIR = settings.BASE_DIR
AUDIO_DIR = os.path.join(BASE_DIR, 'audio')
VIDEO_DIR = os.path.join(BASE_DIR, 'video')

# Configurable Whisper model and diarization defaults
WHISPER_MODEL = os.getenv('WHISPER_MODEL', 'allandclive/whisper-medium-luganda')
DIARIZE_DEFAULT = os.getenv('DIARIZE_DEFAULT', 'false').lower() == 'true'

os.makedirs(AUDIO_DIR, exist_ok=True)
os.makedirs(VIDEO_DIR, exist_ok=True)

LANG_MAP = {
    'English': 'en',
    'French': 'fr',
    'Swahili': 'sw',
    'Luganda': 'lg',
    'Lingala': 'ln'
}

def capitalize_title(name):
    """Ensure audio recording name starts with a Capital letter."""
    if not name or not isinstance(name, str):
        return name or ""
    trimmed = name.strip()
    return (trimmed[0].upper() + trimmed[1:]) if len(trimmed) > 0 else trimmed


# ====== TRANSCRIPTION PIPELINE ======
transcription_pipeline = None

def get_transcription_pipeline():
    """Get or initialize the transcription pipeline matching working Streamlit configuration"""
    global transcription_pipeline
    if transcription_pipeline is not None:
        return transcription_pipeline

    if torch is None:
        raise RuntimeError("PyTorch is not available locally. Please configure RUNPOD_API_KEY and RUNPOD_ENDPOINT_ID to use RunPod Serverless GPU inference.")

    device = "cuda:0" if torch.cuda.is_available() else "cpu"
    torch_dtype = torch.float16 if torch.cuda.is_available() else torch.float32

    model_id = WHISPER_MODEL
    from transformers import AutoModelForSpeechSeq2Seq, AutoProcessor, pipeline

    hf_token = os.getenv("HF_TOKEN")
    load_kwargs = {
        "torch_dtype": torch_dtype,
        "use_safetensors": True,
    }
    if hf_token:
        load_kwargs["token"] = hf_token

    try:
        import accelerate
        load_kwargs["low_cpu_mem_usage"] = True
    except ImportError:
        pass

    model = AutoModelForSpeechSeq2Seq.from_pretrained(
        model_id,
        **load_kwargs
    )
    model.to(device)

    processor = AutoProcessor.from_pretrained(model_id, token=hf_token)

    transcription_pipeline = pipeline(
        "automatic-speech-recognition",
        model=model,
        tokenizer=processor.tokenizer,
        feature_extractor=processor.feature_extractor,
        max_new_tokens=256,
        chunk_length_s=30,
        stride_length_s=10,
        batch_size=4,
        return_timestamps=True,
        torch_dtype=torch_dtype,
        device=device,
    )
    return transcription_pipeline

os.environ["USE_TF"] = "0"
os.environ["TF_ENABLE_ONEDNN_OPTS"] = "0"

def run_whisper_transcription(audio_path, lang_code, return_timestamps=True):
    """Run Whisper for fine-tuned Luganda model using Swahili decoder token"""
    global transcription_pipeline
    if torch is None:
        raise RuntimeError("PyTorch is not available locally. Please configure RUNPOD_API_KEY and RUNPOD_ENDPOINT_ID.")
    with torch.inference_mode():
        generate_kwargs = {"task": "transcribe", "language": "<|sw|>"}
        try:
            return get_transcription_pipeline()(
                audio_path,
                return_timestamps=True,
                generate_kwargs=generate_kwargs,
            )
        except Exception as exc:
            if "client has been closed" not in str(exc).lower():
                raise
            logging.warning("Whisper pipeline client was closed; rebuilding pipeline")
            transcription_pipeline = None
            return get_transcription_pipeline()(
                audio_path,
                return_timestamps=True,
                generate_kwargs=generate_kwargs,
            )

# ====== HELPER FUNCTIONS ======
def extract_audio_from_video(video_path, audio_path):
    """Extract audio from video using direct ffmpeg with moviepy fallback"""
    import subprocess
    try:
        cmd = [
            "ffmpeg", "-y", "-i", video_path,
            "-vn", "-ar", "44100", "-ac", "2", "-b:a", "192k",
            audio_path
        ]
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if proc.returncode == 0 and os.path.exists(audio_path) and os.path.getsize(audio_path) > 0:
            return True
    except Exception as e:
        logging.warning(f"ffmpeg video audio extraction failed: {e}")

    try:
        video = mp.VideoFileClip(video_path)
        video.audio.write_audiofile(audio_path, logger=None)
        video.close()
        return True
    except Exception as e:
        logging.error(f"Error extracting audio from video: {e}")
        return False

def convert_to_mp3(file_path):
    """Robustly convert any audio format (m4a, wav, aac, ogg, webm, etc.) to MP3 with ffmpeg"""
    if not file_path or not os.path.exists(file_path):
        return None
        
    # If already an MP3, return immediately
    if file_path.lower().endswith('.mp3'):
        return file_path

    base_name = os.path.splitext(file_path)[0]
    mp3_path = f"{base_name}.mp3"
    
    try:
        # 1. Try direct ffmpeg command
        import subprocess
        cmd = [
            "ffmpeg", "-y", "-i", file_path,
            "-vn", "-ar", "44100", "-ac", "2", "-b:a", "192k",
            mp3_path
        ]
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if proc.returncode == 0 and os.path.exists(mp3_path) and os.path.getsize(mp3_path) > 0:
            return mp3_path
    except Exception as ff_err:
        logging.warning(f"ffmpeg conversion failed: {ff_err}")

    # 2. Fallback: Return original audio path directly (Faster-Whisper natively decodes all audio/video formats)
    if os.path.exists(file_path) and os.path.getsize(file_path) > 0:
        logging.info(f"Using original audio file directly without conversion: {file_path}")
        return file_path

    return None

def download_youtube_audio(url):
    """Download YouTube audio and convert to MP3 using yt-dlp with pytube fallback"""
    if not url or not url.strip():
        raise ValueError("No YouTube URL provided")

    url = url.strip()

    # 1. Primary Engine: yt-dlp (reliable, handles latest YouTube JS cipher updates)
    try:
        import yt_dlp
        output_template = os.path.join(AUDIO_DIR, '%(id)s.%(ext)s')
        ydl_opts = {
            'format': 'bestaudio/best',
            'outtmpl': output_template,
            'postprocessors': [{
                'key': 'FFmpegExtractAudio',
                'preferredcodec': 'mp3',
                'preferredquality': '192',
            }],
            'quiet': True,
            'no_warnings': True,
        }
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(url, download=True)
            video_id = info.get('id', 'youtube')
            title = info.get('title', 'YouTube_Audio')

            audio_path = os.path.join(AUDIO_DIR, f"{video_id}.mp3")
            if os.path.exists(audio_path) and os.path.getsize(audio_path) > 0:
                clean_title = re.sub(r'[^\w\s-]', '', title).strip() or "YouTube_Audio"
                return audio_path, f"{clean_title}.mp3"
    except Exception as yt_err:
        logging.warning(f"yt-dlp download attempt failed: {yt_err}. Trying pytube fallback...")

    # 2. Fallback Engine: pytube
    try:
        yt = YouTube(url)
        stream = yt.streams.filter(only_audio=True).first()
        if not stream:
            raise Exception("No audio stream found via pytube")

        video_path = os.path.join(VIDEO_DIR, f"{yt.video_id}.mp4")
        stream.download(output_path=VIDEO_DIR, filename=f"{yt.video_id}.mp4")

        audio_path = os.path.join(AUDIO_DIR, f"{yt.video_id}.mp3")
        if not extract_audio_from_video(video_path, audio_path):
            converted = convert_to_mp3(video_path)
            if converted:
                audio_path = converted

        if os.path.exists(video_path):
            try: os.remove(video_path)
            except: pass

        if os.path.exists(audio_path) and os.path.getsize(audio_path) > 0:
            clean_title = re.sub(r'[^\w\s-]', '', yt.title).strip() or "YouTube_Audio"
            return audio_path, f"{clean_title}.mp3"
    except Exception as py_err:
        logging.error(f"pytube download attempt failed: {py_err}")

    raise RuntimeError("Unable to download YouTube audio. Please check the URL or try uploading the audio file directly.")
def format_seconds_to_timestamp(seconds: float) -> str:
    """Converts seconds into [MM:SS] or [HH:MM:SS] with exact audio alignment"""
    total_sec = max(0, int(seconds))
    hrs = total_sec // 3600
    mins = (total_sec % 3600) // 60
    secs = total_sec % 60
    if hrs > 0:
        return f"{hrs:02d}:{mins:02d}:{secs:02d}"
    return f"{mins:02d}:{secs:02d}"

def run_gemini_diarization(chunks, num_speakers=None):
    """
    Identifies distinct speakers and formats the transcript into dialogue portions
    using Gemini LLM, preserving 100% verbatim accuracy.
    """
    if not chunks:
        return None

    try:
        from .agent import invoke_llm_messages
        from langchain_core.messages import SystemMessage, HumanMessage

        # Build numbered/timestamped input lines from chunks
        input_lines = []
        for c in chunks:
            ts = c.get("timestamp", [0.0, 0.0])
            ts_str = format_seconds_to_timestamp(ts[0])
            text = c.get("text", "").strip()
            if text:
                input_lines.append(f"[{ts_str}] {text}")

        if not input_lines:
            return None

        speaker_hint = f"There are approximately {num_speakers} distinct speakers." if num_speakers else "Identify the distinct speakers based on conversational turn-taking and dialogue flow."

        system_prompt = (
            "You are an expert audio dialogue transcriber and speaker attribution specialist.\n"
            "Your task is to organize timestamped speech transcript segments into conversational dialogue turns with distinct speaker labels.\n\n"
            "STRICT RULES:\n"
            "1. FORMAT: Format every dialogue turn as:\n"
            "   [MM:SS] Speaker X: <exact transcribed text>\n"
            "2. VERBATIM ACCURACY: Keep every single transcribed word 100% intact. Do NOT summarize, rewrite, rephrase, omit, or alter any words.\n"
            "3. SPEAKER LABELS: Use Speaker 1, Speaker 2, Speaker 3, etc. (or natural names if explicitly stated).\n"
            "4. MERGING: When consecutive segments belong to the same speaker, merge them into a continuous natural paragraph under the starting timestamp.\n"
            "5. OUTPUT: Output ONLY the formatted dialogue lines. No conversational filler, no introductions, no markdown code block ticks."
        )

        batch_size = 75
        diarized_blocks = []

        for i in range(0, len(input_lines), batch_size):
            batch = input_lines[i:i + batch_size]
            batch_text = "\n".join(batch)
            user_msg = f"{speaker_hint}\n\n<TRANSCRIPT_SEGMENTS>\n{batch_text}\n</TRANSCRIPT_SEGMENTS>"

            response = invoke_llm_messages([
                SystemMessage(content=system_prompt),
                HumanMessage(content=user_msg)
            ])
            output = response.content.strip()
            output = re.sub(r'<think>.*?</think>', '', output, flags=re.DOTALL).strip()
            if output.startswith("```"):
                lines = output.split("\n")
                if lines[0].startswith("```"):
                    lines = lines[1:]
                if lines and lines[-1].strip() == "```":
                    lines = lines[:-1]
                output = "\n".join(lines).strip()

            if output:
                diarized_blocks.append(output)

        return "\n\n".join(diarized_blocks) if diarized_blocks else None

    except Exception as e:
        logging.error(f"Gemini diarization failed: {e}", exc_info=True)
        return None

def has_speaker_labels(text):
    """Return True when text already looks like a speaker-labelled transcript."""
    if not text:
        return False
    speaker_line = re.compile(
        r'^(?:\[?\d{1,2}:\d{2}(?::\d{2})?\]?\s+)?(?:speaker|person|participant|host|guest|interviewer|interviewee|moderator|respondent|narrator)\s*\d*\s*:',
        re.IGNORECASE
    )
    labelled_lines = [
        line for line in text.splitlines()
        if speaker_line.match(line.strip())
    ]
    return len(labelled_lines) > 0

def build_conversation_fallback(raw_text, chunks=None):
    """Arrange raw ASR output into editable conversation blocks when diarization is unavailable."""
    cleaned_raw = (raw_text or "").strip()
    if not cleaned_raw:
        cleaned_raw = "[No speech detected or transcription failed]"

    blocks = []
    if chunks:
        for chunk in chunks:
            text = chunk.get("text", "").strip()
            if not text:
                continue
            ts = chunk.get("timestamp", [0.0, 0.0]) or [0.0, 0.0]
            start = ts[0] or 0
            start_min = int(start // 60)
            start_sec = int(start % 60)
            blocks.append(f"[{start_min:02d}:{start_sec:02d}] Speaker 1: {text}")

    if not blocks:
        paragraphs = [
            paragraph.strip()
            for paragraph in re.split(r'\n\s*\n+', cleaned_raw)
            if paragraph.strip()
        ]
        if len(paragraphs) == 1:
            sentences = re.split(r'(?<=[.!?])\s+', paragraphs[0])
            paragraphs = []
            buffer = []
            for sentence in sentences:
                if sentence.strip():
                    buffer.append(sentence.strip())
                if len(buffer) >= 2:
                    paragraphs.append(" ".join(buffer))
                    buffer = []
            if buffer:
                paragraphs.append(" ".join(buffer))
        blocks = [f"[00:00] Speaker 1: {paragraph}" for paragraph in paragraphs]

    return "\n\n".join(blocks)

# ====== DJANGO VIEWS ======

def landing_view(request):
    """Render the modern marketing & product landing page"""
    return render(request, 'transcriber/landing.html', {
        'user': request.user
    })

def index_view(request):
    """Render the main transcription workspace UI"""
    if request.user.is_authenticated:
        history = Transcription.objects.filter(user=request.user).order_by('-created_at')
    else:
        history = Transcription.objects.filter(user__isnull=True).order_by('-created_at')
    return render(request, 'transcriber/index.html', {'history': history})

def stream_page_view(request):
    """Render the dedicated, standalone Real-Time Streaming Conversation interface (Faster Whisper Medium)"""
    if request.user.is_authenticated:
        history = Transcription.objects.filter(user=request.user).order_by('-created_at')
    else:
        history = Transcription.objects.filter(user__isnull=True).order_by('-created_at')
    return render(request, 'transcriber/streaming.html', {'history': history})

def get_history_view(request):
    """API endpoint to get transcription list"""
    if request.user.is_authenticated:
        transcriptions = Transcription.objects.filter(user=request.user).order_by('-created_at')
    else:
        transcriptions = Transcription.objects.filter(user__isnull=True).order_by('-created_at')
    data = []
    for t in transcriptions:
        data.append({
            'id': str(t.id),
            'original_name': capitalize_title(t.original_name),
            'language': t.language,
            'created_at': t.created_at.strftime('%Y-%m-%d %H:%M')
        })
    return JsonResponse({'history': data})

def get_transcription_view(request, tid):
    """API endpoint to get details of a specific transcription"""
    try:
        t = Transcription.objects.get(id=tid)
        return JsonResponse({
            'id': str(t.id),
            'original_name': capitalize_title(t.original_name),
            'audio_path': t.audio_path,
            'language': t.language,
            'transcription': t.transcription,
            'formatted': t.formatted or t.transcription,
            'created_at': t.created_at.strftime('%Y-%m-%d %H:%M')
        })
    except Transcription.DoesNotExist:
        return JsonResponse({'error': 'Transcription not found'}, status=404)

# ====== REAL-TIME PROGRESS & ETA TRACKING ======
PROGRESS_TRACKER = {}
_PROGRESS_LOCK = threading.Lock()
PROGRESS_DIR = os.path.join(getattr(settings, 'TEMP_DIR', os.path.join(BASE_DIR, '.cache', 'temp')), 'job_progress')
try:
    os.makedirs(PROGRESS_DIR, exist_ok=True)
except Exception:
    pass

def update_job_progress(job_id, stage, status_text, subtext="", progress_pct=0.0, current_sec=0.0, total_sec=0.0, speed_ratio=0.0, eta_sec=None):
    if not job_id:
        return
    with _PROGRESS_LOCK:
        now = time.time()
        # Clean up stale jobs older than 1 hour
        stale_keys = [k for k, v in PROGRESS_TRACKER.items() if now - v.get('updated_at', now) > 3600]
        for k in stale_keys:
            PROGRESS_TRACKER.pop(k, None)

        eta_str = ""
        if eta_sec is not None and eta_sec > 0:
            if eta_sec < 60:
                eta_str = f"~{int(eta_sec)}s"
            elif eta_sec < 3600:
                mins = int(eta_sec // 60)
                secs = int(eta_sec % 60)
                eta_str = f"~{mins}m {secs:02d}s"
            else:
                hrs = int(eta_sec // 3600)
                mins = int((eta_sec % 3600) // 60)
                eta_str = f"~{hrs}h {mins:02d}m"

        payload = {
            'stage': stage,
            'status_text': status_text,
            'subtext': subtext,
            'progress_pct': round(max(0.0, min(100.0, progress_pct)), 1),
            'current_sec': round(current_sec, 2),
            'total_sec': round(total_sec, 2),
            'speed_ratio': round(speed_ratio, 1),
            'eta_sec': round(eta_sec, 1) if eta_sec is not None else None,
            'eta_str': eta_str,
            'updated_at': now
        }
        PROGRESS_TRACKER[job_id] = payload

        # Persist to disk so all multi-process workers (e.g. Gunicorn on Railway) share exact progress
        try:
            prog_file = os.path.join(PROGRESS_DIR, f"{job_id}.json")
            with open(prog_file, "w", encoding="utf-8") as pf:
                json.dump(payload, pf)
        except Exception:
            pass


def get_progress_view(request, job_id):
    """API endpoint to poll job progress and estimated remaining time during transcription"""
    with _PROGRESS_LOCK:
        data = PROGRESS_TRACKER.get(job_id)
        if not data:
            # Check shared filesystem cache for multi-worker setups
            try:
                prog_file = os.path.join(PROGRESS_DIR, f"{job_id}.json")
                if os.path.exists(prog_file):
                    with open(prog_file, "r", encoding="utf-8") as pf:
                        data = json.load(pf)
                        PROGRESS_TRACKER[job_id] = data
            except Exception:
                data = None

        if not data:
            return JsonResponse({'stage': 'processing', 'progress_pct': 8.0, 'status_text': 'Processing media...', 'subtext': ''})
        return JsonResponse(data)


@csrf_exempt
def transcribe_view(request):
    """Handles speech-to-text transcription requests"""
    if request.method != 'POST':
        return JsonResponse({'error': 'Invalid method'}, status=405)

    job_id = request.POST.get('job_id')
    source_type = request.POST.get('source_type')
    language = request.POST.get('language')
    # Diarization flag – enabled by default or checkbox ('on', 'true', '1')
    diarize_param = request.POST.get('diarize')
    skip_diarize_param = request.POST.get('skip_diarize')
    if diarize_param is not None:
        diarize = diarize_param.lower() in ('true', 'on', '1', 'yes')
    else:
        diarize = True
    if skip_diarize_param and skip_diarize_param.lower() in ('true', 'on', '1', 'yes'):
        diarize = False

    num_speakers = request.POST.get('num_speakers')
    if num_speakers and num_speakers.isdigit():
        num_speakers = int(num_speakers)
    else:
        num_speakers = None

    lang_code = LANG_MAP.get(language, 'en')
    audio_path = None
    original_name = None
    temp_path = None

    overall_start = time.time()
    update_job_progress(
        job_id,
        stage='ingest',
        status_text='Acquiring Audio Stream...',
        subtext='Phase 1: Ingesting & preparing audio stream...',
        progress_pct=8.0
    )

    try:
        # 1. Handle File Upload or Youtube URL
        if source_type == 'audio_file':
            file = request.FILES.get('audio_file')
            if not file:
                return JsonResponse({'error': 'No audio file uploaded'}, status=400)
            original_name = file.name
            file_ext = os.path.splitext(original_name)[1].lower()[1:]
            temp_path = os.path.join(AUDIO_DIR, original_name)
            
            with open(temp_path, 'wb+') as destination:
                for chunk in file.chunks():
                    destination.write(chunk)

            if file_ext != 'mp3':
                converted_path = convert_to_mp3(temp_path)
                if converted_path:
                    if converted_path != temp_path and os.path.exists(temp_path):
                        try: os.remove(temp_path)
                        except: pass
                    audio_path = converted_path
                    original_name = os.path.basename(audio_path)
                else:
                    audio_path = temp_path
            else:
                audio_path = temp_path

        elif source_type == 'video_file':
            file = request.FILES.get('video_file')
            if not file:
                return JsonResponse({'error': 'No video file uploaded'}, status=400)
            original_name = file.name
            video_path = os.path.join(VIDEO_DIR, original_name)
            
            with open(video_path, 'wb+') as destination:
                for chunk in file.chunks():
                    destination.write(chunk)

            audio_filename = f"{os.path.splitext(original_name)[0]}.mp3"
            audio_path = os.path.join(AUDIO_DIR, audio_filename)

            if not extract_audio_from_video(video_path, audio_path):
                if os.path.exists(video_path):
                    os.remove(video_path)
                return JsonResponse({'error': 'Failed to extract audio from video'}, status=500)

            if os.path.exists(video_path):
                os.remove(video_path)
            original_name = audio_filename

        elif source_type == 'youtube_url':
            url = request.POST.get('youtube_url')
            if not url:
                return JsonResponse({'error': 'No URL provided'}, status=400)
            try:
                audio_path, original_name = download_youtube_audio(url)
            except Exception as yt_exc:
                logging.error(f"YouTube download error: {yt_exc}")
                return JsonResponse({'error': f'YouTube download failed: {str(yt_exc)}'}, status=500)
        else:
            return JsonResponse({'error': 'Invalid source type'}, status=400)

        # 2. Run STT Transcription Engine
        start_ts = time.time()
        
        is_luganda = (language and language.lower() == 'luganda') or lang_code in ('lg', 'luganda')
        is_live_recording = request.POST.get('is_live_rec') == 'true' or (original_name and 'live_recording' in original_name.lower())
        
        update_job_progress(
            job_id,
            stage='transcribing',
            status_text='Transcribing Speech to Text...',
            subtext='Phase 2: Initializing Neural Speech Recognition Model...',
            progress_pct=15.0
        )

        stt_start_wall = time.time()
        def stt_progress_cb(curr_audio_sec, total_audio_sec):
            wall_elapsed = max(0.001, time.time() - stt_start_wall)
            speed = (curr_audio_sec / wall_elapsed) if curr_audio_sec > 0 else 0.0
            rem_audio = max(0.0, total_audio_sec - curr_audio_sec)
            eta = (rem_audio / max(speed, 0.1)) if speed > 0.1 else None
            
            trans_pct = (curr_audio_sec / max(total_audio_sec, 1.0)) * 100.0
            overall_pct = 15.0 + (trans_pct * 0.65)  # 15% -> 80%
            
            curr_ts = format_seconds_to_timestamp(curr_audio_sec)
            tot_ts = format_seconds_to_timestamp(total_audio_sec)
            
            status_msg = f"Transcribing Speech to Text ({trans_pct:.0f}%)"
            sub_msg = f"Processed {curr_ts} / {tot_ts} ({speed:.1f}x speed)"
            if eta is not None:
                eta_chip = f"~{int(eta//60)}m {int(eta%60):02d}s" if eta >= 60 else f"~{int(eta)}s"
                sub_msg += f" • Est. Remaining: {eta_chip}"
                
            update_job_progress(
                job_id,
                stage='transcribing',
                status_text=status_msg,
                subtext=sub_msg,
                progress_pct=overall_pct,
                current_sec=curr_audio_sec,
                total_sec=total_audio_sec,
                speed_ratio=speed,
                eta_sec=eta
            )

        if is_runpod_configured():
            update_job_progress(
                job_id,
                stage='transcribing',
                status_text='Dispatching to RunPod Cloud GPU...',
                subtext=f'Preparing & offloading [{language}] audio to GPU worker...',
                progress_pct=18.0
            )
            logging.info(f'[RUNPOD ROUTING] Running RunPod Serverless transcription for [{language}] (diarize={diarize})')

            def runpod_prog_cb(status="IN_PROGRESS", elapsed=0.0, progress=None, execution_time=None, delay_time=None):
                # 1. Custom progress payload from worker (if available)
                if isinstance(progress, dict):
                    stage = progress.get('stage', 'transcribing')
                    status_text = progress.get('status_text') or progress.get('message', 'Processing on Cloud GPU...')
                    subtext = progress.get('subtext', f'Active GPU computation ({int(elapsed)}s elapsed)')
                    pct = float(progress.get('progress_pct', progress.get('pct', 50.0)))
                    update_job_progress(
                        job_id,
                        stage=stage,
                        status_text=status_text,
                        subtext=subtext,
                        progress_pct=pct
                    )
                    return

                # 2. Dynamic progress calculation based on RunPod worker lifecycle
                if status == 'IN_QUEUE':
                    q_sec = int(elapsed)
                    update_job_progress(
                        job_id,
                        stage='transcribing',
                        status_text='RunPod Cloud GPU: Provisioning Worker...',
                        subtext=f'Phase 1: Booting NVIDIA GPU worker & loading weights ({q_sec}s elapsed)...',
                        progress_pct=min(32.0, 18.0 + elapsed * 1.2)
                    )
                elif status == 'IN_PROGRESS':
                    # Calculate active GPU time
                    exec_sec = (execution_time / 1000.0) if execution_time else max(1.0, elapsed - 6.0)
                    
                    if diarize:
                        # With diarization: 32% -> 65% STT, 65% -> 88% VAD & Diarization, 88% -> 95% formatting
                        if exec_sec < 18.0:
                            trans_pct = min(65.0, 32.0 + exec_sec * 1.8)
                            update_job_progress(
                                job_id,
                                stage='transcribing',
                                status_text=f'Neural Speech Recognition ({int(trans_pct)}%)',
                                subtext=f'Phase 2: Whisper inference for [{language}] on GPU ({int(exec_sec)}s)...',
                                progress_pct=trans_pct
                            )
                        elif exec_sec < 38.0:
                            diar_pct = min(88.0, 65.0 + (exec_sec - 18.0) * 1.2)
                            update_job_progress(
                                job_id,
                                stage='diarizing',
                                status_text=f'Acoustic Speaker Diarization ({int(diar_pct)}%)',
                                subtext=f'Phase 3: FSMN-VAD voice detection & CAM++ speaker voiceprints ({int(exec_sec)}s)...',
                                progress_pct=diar_pct
                            )
                        else:
                            fin_pct = min(94.0, 88.0 + (exec_sec - 38.0) * 0.4)
                            update_job_progress(
                                job_id,
                                stage='finalizing',
                                status_text='Structuring Concise Portions...',
                                subtext=f'Phase 4: Merging dialogue turns & timeline synchronization ({int(exec_sec)}s)...',
                                progress_pct=fin_pct
                            )
                    else:
                        # Transcription only (no diarization): 32% -> 92%
                        trans_pct = min(92.0, 32.0 + exec_sec * 2.5)
                        update_job_progress(
                            job_id,
                            stage='transcribing',
                            status_text=f'Neural Speech Recognition ({int(trans_pct)}%)',
                            subtext=f'Phase 2: Whisper model inference on GPU ({int(exec_sec)}s)...',
                            progress_pct=trans_pct
                        )
                elif status == 'COMPLETED':
                    update_job_progress(
                        job_id,
                        stage='finalizing',
                        status_text='Finalizing Transcription...',
                        subtext='Phase 4: Structuring concise portions and timeline sync...',
                        progress_pct=96.0
                    )

            runpod_out = runpod_transcribe(
                audio_path,
                language=language,
                diarize=diarize,
                num_speakers=num_speakers,
                progress_callback=runpod_prog_cb
            )
            raw_text = runpod_out.get("text", "").strip()
            formatted_text = runpod_out.get("formatted", raw_text).strip()
            chunks = runpod_out.get("chunks", [])
            transcription_time = time.time() - start_ts
            logging.info(f'[RUNPOD ROUTING] RunPod transcription completed in {transcription_time:.2f}s')

        elif not is_luganda and lang_code in ('en', 'fr', 'sw', 'ln'):
            # ------------------- Faster Whisper (CTranslate2 Medium / GPU) -------------------
            if not stt_service:
                raise RuntimeError("Local STT service unavailable. Please configure RUNPOD_API_KEY and RUNPOD_ENDPOINT_ID.")
            target_whisper_lang = lang_code if lang_code in ('en', 'fr', 'sw', 'ln') else 'en'
            source_desc = "Live Recording" if is_live_recording else "Audio"
            logging.info(f'[STT ROUTING] Running Faster Whisper for [{language}/{target_whisper_lang}] {source_desc}: {audio_path}')
            result = stt_service.transcribe_audio_file(audio_path, language=target_whisper_lang, progress_callback=stt_progress_cb)
            transcription_time = time.time() - start_ts
            logging.info(f'[STT ROUTING] Faster Whisper transcription for [{target_whisper_lang}] completed in {transcription_time:.2f}s')
            raw_text = result.get("text", "").strip()
            chunks = result.get("chunks", [])
        else:
            # ------------------- Fine-Tuned Luganda Whisper Model -------------------
            logging.info(f'[STT ROUTING] Running Luganda Model ({WHISPER_MODEL}) for language [{language}]: {audio_path}')
            result = run_whisper_transcription(audio_path, 'lg', return_timestamps=True)
            transcription_time = time.time() - start_ts
            logging.info(f'[STT ROUTING] Luganda Model transcription completed in {transcription_time:.2f}s')
            chunks = result.get("chunks", [])
            if chunks:
                raw_text = "\n".join(chunk["text"].strip() for chunk in chunks if chunk.get("text"))
            else:
                raw_text = result.get("text", "").strip()

        if not is_runpod_configured():
            if chunks:
                timestamped_lines = []
                for chunk in chunks:
                    ts = chunk.get("timestamp", [0.0, 0.0])
                    ts_str = format_seconds_to_timestamp(ts[0])
                    chunk_text = chunk.get("text", "").strip()
                    if chunk_text:
                        timestamped_lines.append(f"[{ts_str}] {chunk_text}")
                timestamped_formatted_text = "\n".join(timestamped_lines)
            else:
                timestamped_formatted_text = raw_text

            if not timestamped_formatted_text:
                timestamped_formatted_text = "[No speech detected or transcription failed]"

            # Format with local GPU Acoustic Diarization (CAM++) if requested
            formatted_text = timestamped_formatted_text
            if diarize and chunks and audio_path and os.path.exists(audio_path) and acoustic_diarization_service:
                update_job_progress(
                    job_id,
                    stage='diarizing',
                    status_text='Acoustic Speaker Diarization...',
                    subtext='Phase 3: Extracting voiceprints with FSMN-VAD & CAM++...',
                    progress_pct=82.0
                )
                logging.info("Running local GPU CAM++ sentence-level speaker diarization")
                acoustic_formatted, _ = acoustic_diarization_service.diarize_and_align_whisper_chunks(
                    audio_path,
                    chunks,
                    num_speakers=num_speakers
                )
                if acoustic_formatted:
                    formatted_text = acoustic_formatted

        else:
            timestamped_formatted_text = formatted_text

        if not formatted_text:
            formatted_text = "[No speech detected or transcription failed]"

        # Pure raw text: strictly no speaker prefixes or timestamps
        clean_raw_text = raw_text.strip() if raw_text else re.sub(r'\[\d{1,4}:\d{2}(?::\d{2})?\]\s*(?:Speaker\s*\d+|Person\s*\d+|[a-zA-Z0-9_-]+)?\s*:\s*', '', timestamped_formatted_text).strip()
        clean_raw_text = re.sub(r'\[\d{1,4}:\d{2}(?::\d{2})?\]\s*', '', clean_raw_text).strip()

        if not clean_raw_text:
            clean_raw_text = "[No speech detected or transcription failed]"

        update_job_progress(
            job_id,
            stage='finalizing',
            status_text='Finalizing Transcription...',
            subtext='Phase 4: Structuring concise portions and timeline sync...',
            progress_pct=96.0
        )

        # 4. Save to Database with exact timeline mapping
        user_obj = request.user if request.user.is_authenticated else None
        original_name = capitalize_title(original_name)
        t = Transcription.objects.create(
            user=user_obj,
            original_name=original_name,
            audio_path=audio_path,
            language=language,
            transcription=clean_raw_text,
            formatted=formatted_text
        )

        update_job_progress(
            job_id,
            stage='complete',
            status_text='Complete!',
            subtext='Loading workspace...',
            progress_pct=100.0
        )

        total_duration = round(time.time() - overall_start, 2)
        return JsonResponse({
            'success': True,
            'id': str(t.id),
            'transcription': clean_raw_text,
            'formatted': formatted_text,
            'processing_time': total_duration
        })

    except Exception as e:
        update_job_progress(
            job_id,
            stage='error',
            status_text='Transcription Failed',
            subtext=str(e),
            progress_pct=0.0
        )
        logging.exception('Transcription pipeline error')
        # Preserve original traceback for debugging
        import traceback
        traceback.print_exc()
        if temp_path and os.path.exists(temp_path):
            try: os.remove(temp_path)
            except: pass
        return JsonResponse({'error': f'Transcription failed: {str(e)}'}, status=500)

@csrf_exempt
def update_transcription_view(request, tid):
    """Allows manual editing of transcription from the UI editor"""
    if request.method != 'POST':
        return JsonResponse({'error': 'Invalid method'}, status=405)
    try:
        t = Transcription.objects.get(id=tid)
        body = json.loads(request.body)
        if 'formatted' in body:
            t.formatted = body.get('formatted', t.formatted)
        if 'transcription' in body:
            t.transcription = body.get('transcription', t.transcription)
        t.save()
        return JsonResponse({'success': True})
    except Transcription.DoesNotExist:
        return JsonResponse({'error': 'Not found'}, status=404)
    except Exception as e:
        return JsonResponse({'error': str(e)}, status=500)

@csrf_exempt
def chat_co_pilot_view(request):
    """Sends transcription snippets and instruction to LangGraph Agent co-pilot"""
    if request.method != 'POST':
        return JsonResponse({'error': 'Invalid method'}, status=405)
    try:
        if not request.body:
            return JsonResponse({'error': 'Empty request body'}, status=400)
        try:
            body = json.loads(request.body)
        except json.JSONDecodeError as e:
            return JsonResponse({'error': f'Invalid JSON: {str(e)}'}, status=400)
        
        tid = body.get('id')
        user_prompt = body.get('prompt')
        selected_text = body.get('selected_text', '').strip()
        
        t = Transcription.objects.get(id=tid)
        full_text = t.formatted or t.transcription

        from .agent import run_co_pilot_agent
        result = run_co_pilot_agent(
            prompt=user_prompt,
            selected_text=selected_text,
            full_transcription=full_text
        )
        
        return JsonResponse({
            'success': True,
            'reply': result['output'],
            'intent': result.get('intent', 'QA')
        })
    except Transcription.DoesNotExist:
        return JsonResponse({'error': 'Transcription not found'}, status=404)
    except Exception as e:
        logging.exception('Agent error in chat_co_pilot_view')
        return JsonResponse({'error': f"Agent error: {str(e)}"}, status=500)

def download_raw_text_view(request, tid):
    """Download raw (un-edited) transcription text file without speaker tags or timestamps"""
    try:
        t = Transcription.objects.get(id=tid)
        text = t.transcription or t.formatted or ""
        clean_text = re.sub(r'\[\d{1,4}:\d{2}(?::\d{2})?\]\s*(?:Speaker\s*\d+|Person\s*\d+|Transcript|Raw Transcript|[a-zA-Z0-9_-]+)?\s*:\s*', '', text)
        clean_text = re.sub(r'\[\d{1,4}:\d{2}(?::\d{2})?\]\s*', '', clean_text)
        clean_text = re.sub(r'^(?:Speaker\s*\d+|Person\s*\d+|Transcript|Raw Transcript)\s*:\s*', '', clean_text, flags=re.MULTILINE).strip()
        response = HttpResponse(clean_text, content_type='text/plain; charset=utf-8')
        response['Content-Disposition'] = f'attachment; filename="raw_transcription_{str(t.id)[:8]}.txt"'
        return response
    except Transcription.DoesNotExist:
        return HttpResponse("Transcription not found", status=404)

def download_edited_text_view(request, tid):
    """Download formatted/edited transcription text file"""
    try:
        t = Transcription.objects.get(id=tid)
        text = t.formatted or t.transcription or ""
        response = HttpResponse(text, content_type='text/plain; charset=utf-8')
        response['Content-Disposition'] = f'attachment; filename="edited_transcription_{str(t.id)[:8]}.txt"'
        return response
    except Transcription.DoesNotExist:
        return HttpResponse("Transcription not found", status=404)

def download_text_view(request, tid):
    """Alias for downloading edited transcription text file"""
    return download_edited_text_view(request, tid)

def download_audio_view(request, tid):
    """Download source audio file as attachment"""
    try:
        t = Transcription.objects.get(id=tid)
        if t.audio_path and os.path.exists(t.audio_path):
            ext = os.path.splitext(t.audio_path)[1].lower()
            mime_type = 'audio/mpeg'
            if ext in ['.wav']: mime_type = 'audio/wav'
            elif ext in ['.m4a', '.mp4']: mime_type = 'audio/mp4'
            elif ext in ['.ogg']: mime_type = 'audio/ogg'
            elif ext in ['.flac']: mime_type = 'audio/flac'

            with open(t.audio_path, 'rb') as f:
                response = HttpResponse(f.read(), content_type=mime_type)
                response['Content-Disposition'] = f'attachment; filename="{os.path.basename(t.audio_path)}"'
                return response
        return HttpResponse("Audio file not found", status=404)
    except Transcription.DoesNotExist:
        return HttpResponse("Not found", status=404)

def stream_audio_view(request, tid):
    """Serve source audio file inline with full HTTP Range request support for audio seeking"""
    try:
        t = Transcription.objects.get(id=tid)
        if not t.audio_path or not os.path.exists(t.audio_path):
            return HttpResponse("Audio file not found", status=404)

        file_path = t.audio_path
        file_size = os.path.getsize(file_path)

        ext = os.path.splitext(file_path)[1].lower()
        mime_type = 'audio/mpeg'
        if ext in ['.wav']: mime_type = 'audio/wav'
        elif ext in ['.m4a', '.mp4']: mime_type = 'audio/mp4'
        elif ext in ['.ogg']: mime_type = 'audio/ogg'
        elif ext in ['.flac']: mime_type = 'audio/flac'

        range_header = request.META.get('HTTP_RANGE', '').strip()
        
        if range_header and range_header.startswith('bytes='):
            try:
                byte_range = range_header.split('=')[1].strip()
                start_str, end_str = byte_range.split('-')
                start_byte = int(start_str) if start_str else 0
                end_byte = int(end_str) if end_str else file_size - 1
                
                if start_byte >= file_size:
                    return HttpResponse(status=416)  # Range Not Satisfiable

                end_byte = min(end_byte, file_size - 1)
                length = end_byte - start_byte + 1

                with open(file_path, 'rb') as f:
                    f.seek(start_byte)
                    content = f.read(length)

                response = HttpResponse(content, status=206, content_type=mime_type)
                response['Content-Range'] = f'bytes {start_byte}-{end_byte}/{file_size}'
                response['Accept-Ranges'] = 'bytes'
                response['Content-Length'] = str(length)
                return response
            except Exception as exc:
                logging.warning(f"Range header parsing error in stream_audio_view: {exc}")

        # Full file response if no Range header present
        with open(file_path, 'rb') as f:
            content = f.read()

        response = HttpResponse(content, content_type=mime_type)
        response['Accept-Ranges'] = 'bytes'
        response['Content-Length'] = str(file_size)
        return response

    except Transcription.DoesNotExist:
        return HttpResponse("Not found", status=404)

@csrf_exempt
def diarize_transcription_view(request, tid):
    """Run GPU acoustic diarization (FSMN-VAD + CAM++) on an existing transcription's audio"""
    if request.method != 'POST':
        return JsonResponse({'error': 'Invalid method'}, status=405)
    try:
        try:
            t = Transcription.objects.get(id=tid)
        except Exception:
            return JsonResponse({'error': f'Transcription {tid} not found'}, status=404)

        if not t.audio_path or not os.path.exists(t.audio_path):
            return JsonResponse({'error': 'Source audio file not found on disk'}, status=404)

        body_data = {}
        if request.body:
            try:
                body_data = json.loads(request.body)
            except Exception:
                body_data = {}

        num_speakers = body_data.get('num_speakers') or request.POST.get('num_speakers')
        if num_speakers and str(num_speakers).isdigit():
            num_speakers = int(num_speakers)
        else:
            num_speakers = None

        # 1. Check if portions are passed directly from the editor
        portions = body_data.get('portions')
        if not portions:
            # Parse portions from t.formatted or t.transcription
            raw_source = t.formatted or t.transcription or ""
            portions = []
            for line in raw_source.splitlines():
                line = line.strip()
                if not line:
                    continue
                match = re.match(r'^(?:\[?(\d{1,4}:\d{2}(?::\d{2})?)\]?\s+)?(?:(?:Speaker\s*\d+|Person\s*\d+|[a-zA-Z0-9_-]+)?\s*:\s*)?(.*)$', line)
                if match:
                    ts_str = match.group(1) or "00:00"
                    content = match.group(2).strip()
                    if content:
                        portions.append({
                            'time': ts_str,
                            'speaker': 'Speaker 1',
                            'content': content
                        })

        if not portions:
            return JsonResponse({'error': 'No text portions available to diarize'}, status=400)

        # Diarize existing portions without modifying any text
        if is_runpod_configured():
            logging.info(f"[RUNPOD ROUTING] Running RunPod Serverless diarization for transcription {tid}...")
            runpod_res = runpod_diarize(
                audio_path=t.audio_path,
                portions=portions,
                num_speakers=num_speakers
            )
            formatted_text = runpod_res.get("formatted", "")
            updated_portions = runpod_res.get("portions", portions)
        elif acoustic_diarization_service:
            formatted_text, updated_portions = acoustic_diarization_service.diarize_existing_portions(
                t.audio_path,
                portions,
                num_speakers=num_speakers
            )
        else:
            return JsonResponse({'error': 'Local Diarization engine unavailable and RunPod is not configured.'}, status=500)


        if formatted_text:
            t.formatted = formatted_text
            t.save()
            return JsonResponse({
                'success': True,
                'formatted': formatted_text,
                'portions': updated_portions
            })
        else:
            return JsonResponse({'error': 'Acoustic diarization produced empty output'}, status=500)
    except Exception as e:
        logging.exception('Diarization endpoint error')
        return JsonResponse({'error': f'Acoustic Diarization failed: {str(e)}'}, status=500)

@csrf_exempt
def delete_transcription_view(request, tid):
    """Deletes transcription from database and wipes local audio files safely"""
    try:
        clean_tid = str(tid).strip().strip('"\'')
        t = None
        try:
            t = Transcription.objects.get(id=clean_tid)
        except (Transcription.DoesNotExist, Exception):
            t = Transcription.objects.filter(id=clean_tid).first()

        if not t:
            return JsonResponse({'error': 'Transcription not found', 'success': False}, status=404)

        if t.audio_path:
            try:
                if os.path.exists(t.audio_path):
                    os.remove(t.audio_path)
            except Exception as e:
                logging.warning(f"Could not remove audio file {t.audio_path}: {e}")

        t.delete()
        return JsonResponse({'success': True})
    except Exception as e:
        logging.error(f"Error deleting transcription {tid}: {e}", exc_info=True)
        return JsonResponse({'error': str(e), 'success': False}, status=500)


@csrf_exempt
def rename_transcription_view(request, tid):
    """Renames transcription title in database"""
    if request.method != 'POST':
        return JsonResponse({'error': 'POST method required'}, status=405)
    try:
        data = json.loads(request.body.decode('utf-8')) if request.body else request.POST
        new_name = data.get('new_name') or data.get('name') or ''
        new_name = capitalize_title(new_name)
        if not new_name:
            return JsonResponse({'error': 'Name cannot be empty'}, status=400)
        
        t = Transcription.objects.get(id=tid)
        t.original_name = new_name
        t.save()
        return JsonResponse({'success': True, 'new_name': new_name})
    except Transcription.DoesNotExist:
        return JsonResponse({'error': 'Transcription not found'}, status=404)
    except Exception as e:
        return JsonResponse({'error': str(e)}, status=500)



@csrf_exempt
def login_view(request):
    """API endpoint for User Authentication (Login)"""
    if request.method != 'POST':
        return JsonResponse({'error': 'POST method required'}, status=405)
    try:
        data = json.loads(request.body.decode('utf-8'))
    except Exception:
        data = request.POST

    username = data.get('username', '').strip()
    password = data.get('password', '').strip()

    if not username or not password:
        return JsonResponse({'success': False, 'error': 'Username and password are required'}, status=400)

    user = authenticate(request, username=username, password=password)
    if user is not None:
        login(request, user)
        return JsonResponse({
            'success': True,
            'username': user.username,
            'email': user.email
        })
    return JsonResponse({'success': False, 'error': 'Invalid username or password'}, status=401)


@csrf_exempt
def register_view(request):
    """API endpoint for User Registration"""
    if request.method != 'POST':
        return JsonResponse({'error': 'POST method required'}, status=405)
    try:
        data = json.loads(request.body.decode('utf-8'))
    except Exception:
        data = request.POST

    username = data.get('username', '').strip()
    email = data.get('email', '').strip()
    password = data.get('password', '').strip()

    if not username or not password:
        return JsonResponse({'success': False, 'error': 'Username and password are required'}, status=400)

    if User.objects.filter(username=username).exists():
        return JsonResponse({'success': False, 'error': 'Username already registered'}, status=400)

    try:
        user = User.objects.create_user(username=username, email=email, password=password)
        login(request, user)
        return JsonResponse({
            'success': True,
            'username': user.username,
            'email': user.email
        })
    except Exception as e:
        return JsonResponse({'success': False, 'error': str(e)}, status=500)


@csrf_exempt
def logout_view(request):
    """API endpoint for User Logout"""
    logout(request)
    return JsonResponse({'success': True})


@csrf_exempt
def stream_warmup_view(request):
    """
    API: Ensures Faster Whisper Medium and CAM++ models are 100% warmed up and hot in GPU memory.
    Called immediately when entering or hovering over the Real-Time Streaming mode so there is zero cold start.
    """
    if is_runpod_configured():
        return JsonResponse({
            'success': True,
            'ready': True,
            'device': 'RunPod Cloud GPU',
            'model': 'RunPod Serverless Whisper'
        })

    def _warmup():
        try:
            if stt_service:
                stt_service.preload_model()
            if acoustic_diarization_service:
                acoustic_diarization_service._init_models()
        except Exception as e:
            logging.warning(f"Streaming warmup warning: {e}")

    threading.Thread(target=_warmup, daemon=True).start()
    is_ready = bool(stt_service and stt_service.model is not None)
    device_name = getattr(stt_service, 'device', 'cuda' if (torch and torch.cuda.is_available()) else 'cpu')
    model_name = f"Faster Whisper {stt_service.model_size.capitalize() if (stt_service and getattr(stt_service, 'model_size', None)) else 'Medium'}"
    return JsonResponse({
        'success': True,
        'ready': is_ready,
        'device': device_name,
        'model': model_name
    })


@csrf_exempt
def stream_transcribe_chunk_view(request):
    """
    API: Real-time streaming conversation audio transcription powered by Faster Whisper Medium & CAM++ speaker tracking.
    Receives small audio chunks/utterances from the browser, returns speaker attribution and transcribed text.
    Uses Faster Whisper Medium for high-accuracy stream inference.
    """
    if request.method != 'POST':
        return JsonResponse({'error': 'POST method required', 'success': False}, status=405)

    audio_file = request.FILES.get('audio_chunk') or request.FILES.get('audio_file') or request.FILES.get('audio')
    if not audio_file:
        return JsonResponse({'success': True, 'text': '', 'speaker': '', 'is_speech': False})

    session_id = request.POST.get('session_id', 'stream_default').strip()
    lang = request.POST.get('language', 'auto').strip()

    # Temporary directory for chunk processing
    temp_dir = os.path.join(AUDIO_DIR, 'streaming_temp')
    os.makedirs(temp_dir, exist_ok=True)
    ext = os.path.splitext(audio_file.name)[1] or '.wav'
    temp_path = os.path.join(temp_dir, f"chunk_{session_id}_{int(time.time() * 1000)}_{uuid.uuid4().hex[:6]}{ext}")

    try:
        with open(temp_path, 'wb+') as dest:
            for chunk in audio_file.chunks():
                dest.write(chunk)

        if is_runpod_configured():
            is_cont = request.POST.get('is_continuous') == 'true'
            runpod_res = runpod_stream_chunk(
                chunk_path=temp_path,
                session_id=session_id,
                language=lang,
                is_continuous=is_cont
            )
            if os.path.exists(temp_path):
                try: os.remove(temp_path)
                except Exception: pass
            return JsonResponse({
                'success': runpod_res.get("status") == "success",
                'text': runpod_res.get("text", ""),
                'speaker': runpod_res.get("speaker", "Speaker 1"),
                'is_speech': runpod_res.get("is_speech", False),
                'latency_ms': runpod_res.get("latency_ms", 0)
            })

        t0 = time.time()
        lang_lower = (lang or 'auto').lower().strip()
        target_lang = 'en' if (not lang_lower or lang_lower == 'auto') else lang_lower

        if not stt_service:
            return JsonResponse({'error': 'Local STT service unavailable and RunPod is not configured.', 'success': False}, status=500)

        # 1. Transcribe: Faster Whisper Medium
        text = ""
        try:
            whisper_res = stt_service.transcribe_audio_file(
                temp_path,
                language=target_lang,
                beam_size=1,
                vad_filter=False,
                temperature=0.0
            )
            text = whisper_res.get("text", "").strip()
        except Exception as fw_err:
            logger.error(f"[Streaming] Faster Whisper Medium transcription error: {fw_err}", exc_info=True)

        elapsed = time.time() - t0

        # Filter musical notes, subtitle artifacts, and phantom noise hallucinations
        text = filter_streaming_hallucinations(text)

        if not text:
            return JsonResponse({
                'success': True,
                'text': '',
                'speaker': '',
                'is_speech': False,
                'latency_ms': int(elapsed * 1000)
            })

        # Filter out common hallucinated single-word or two-word noise blips caused by mic noises, breath, or room rumble
        words = [w for w in re.split(r'\s+', text.strip()) if w]
        clean_norm = text.lower().strip().strip('.,!?:;"\'-')

        NOISE_WORDS = {
            "you", "thank you", "thanks", "yeah", "yeha", "so", "bye", "uh", "um", "ah", "oh",
            "huh", "mhm", "the", "a", "an", "ok", "okay", "right", "subtitles",
            "transcript", "caption", "watching", "subscribe", "bye bye", "am", "is", "it",
            "hello", "hello hello", "hi", "hey", "yeah hello", "yeha hello", "hello yeah"
        }

        # Check audio duration to detect transient noise bursts
        duration_sec = 0.0
        try:
            import soundfile as sf
            info = sf.info(temp_path)
            duration_sec = info.duration
        except Exception:
            pass

        # If it's a single word or 2-word phantom noise blip, discard as noise (unless part of continuous streaming speech)
        is_continuous = request.POST.get('is_continuous') == 'true'
        if not is_continuous and len(words) <= 2:
            if clean_norm in NOISE_WORDS or len(clean_norm) <= 2 or duration_sec < 0.70:
                logging.info(f"[STREAM-STT] Ignored noise artifact / phantom hallucination: '{text}' ({duration_sec:.2f}s)")
                return JsonResponse({
                    'success': True,
                    'text': '',
                    'speaker': '',
                    'is_speech': False,
                    'latency_ms': int(elapsed * 1000)
                })

        # 2. Identify speaker via CAM++ voiceprint embedding (passing text so 1-word utterances never switch speakers)
        spk_info = streaming_speaker_tracker.identify_speaker(session_id, temp_path, text=text)
        speaker_name = spk_info.get("speaker", "Speaker 1")
        speaker_id = spk_info.get("speaker_id", 1)

        return JsonResponse({
            'success': True,
            'text': text,
            'speaker': speaker_name,
            'speaker_id': speaker_id,
            'is_speech': True,
            'is_new_speaker': spk_info.get("is_new_speaker", False),
            'similarity': round(spk_info.get("similarity", 1.0), 3),
            'latency_ms': int(elapsed * 1000)
        })

    except Exception as e:
        logging.error(f"[STREAM-STT] Error processing streaming chunk: {e}", exc_info=True)
        return JsonResponse({'success': False, 'error': str(e)}, status=500)
    finally:
        if os.path.exists(temp_path):
            try:
                os.remove(temp_path)
            except Exception:
                pass



@csrf_exempt
def save_stream_session_view(request):
    """
    API: Saves a completed real-time streaming conversation session into the database as a Transcription record.
    """
    if request.method != 'POST':
        return JsonResponse({'error': 'POST method required', 'success': False}, status=405)

    try:
        data = json.loads(request.body.decode('utf-8'))
    except Exception:
        data = request.POST

    messages = data.get('messages', [])
    session_title = data.get('title', f"Stream_Conversation_{time.strftime('%Y%m%d_%H%M%S')}").strip()
    language = data.get('language', 'Luganda').strip()

    if not messages:
        return JsonResponse({'error': 'No conversation messages to save', 'success': False}, status=400)

    formatted_lines = []
    portions = []
    plain_lines = []

    for msg in messages:
        spk = msg.get('speaker', 'Speaker 1')
        txt = msg.get('text', '').strip()
        ts = msg.get('timestamp', '00:00')
        if txt:
            formatted_lines.append(f"[{ts}] {spk}: {txt}")
            plain_lines.append(f"{spk}: {txt}")
            portions.append({
                "time": ts,
                "speaker": spk,
                "content": txt
            })

    raw_text = "\n\n".join(plain_lines)
    formatted_text = "\n\n".join(formatted_lines)

    tid = str(uuid.uuid4())
    user_obj = request.user if getattr(request, 'user', None) and request.user.is_authenticated else None
    session_title = capitalize_title(session_title)

    transcription = Transcription.objects.create(
        user=user_obj,
        original_name=session_title,
        audio_path="",
        language=language,
        transcription=raw_text,
        formatted=formatted_text
    )

    return JsonResponse({
        'success': True,
        'id': transcription.id,
        'title': transcription.original_name,
        'message': 'Streaming conversation saved successfully to workspace'
    })


# =========================================================================
# DASHBOARD, ANALYTICS & USER MANAGEMENT
# =========================================================================

def _extract_audio_duration_seconds(formatted_text, raw_text):
    """
    Extracts duration from timestamps [MM:SS] or [HH:MM:SS] in formatted_text,
    or falls back to word count calculation (~130 words per minute).
    """
    if formatted_text:
        matches = re.findall(r'\[(\d{1,2}):(\d{2})(?::(\d{2}))?\]', formatted_text)
        if matches:
            last_m = matches[-1]
            if last_m[2]:
                return int(last_m[0]) * 3600 + int(last_m[1]) * 60 + int(last_m[2]) + 5
            else:
                return int(last_m[0]) * 60 + int(last_m[1]) + 5
    if raw_text:
        words = len(raw_text.split())
        if words > 0:
            return max(15.0, (words / 130.0) * 60.0)
    return 15.0


def _categorize_transcription_file(original_name, audio_path):
    """
    Categorizes a transcription into:
    1. Source Mode: 'Live Recording', 'Real-Time Stream', 'YouTube / Web Media', 'Video Extraction', 'Audio Upload'
    2. File Extension: '.mp3', '.wav', '.m4a', '.mp4', '.stream', '.webm', etc.
    """
    name_l = (original_name or '').lower()
    path_l = (audio_path or '').lower()

    if name_l.startswith('live_recording') or 'live_rec' in name_l:
        source_mode = 'Live Recording'
    elif name_l.startswith('stream_') or 'streaming' in name_l:
        source_mode = 'Real-Time Stream'
    elif name_l.startswith('youtube') or 'youtube' in path_l:
        source_mode = 'YouTube / Web Media'
    elif any(name_l.endswith(ext) or path_l.endswith(ext) for ext in ['.mp4', '.mov', '.avi', '.mkv', '.webm']):
        source_mode = 'Video Extraction'
    else:
        source_mode = 'Audio Upload'

    ext = os.path.splitext(original_name or '')[1].lower()
    if not ext:
        ext = os.path.splitext(audio_path or '')[1].lower()
    if not ext:
        if source_mode == 'Real-Time Stream':
            ext = '.stream'
        elif source_mode == 'Live Recording':
            ext = '.wav'
        else:
            ext = '.mp3'

    return source_mode, ext


def _format_seconds_to_human(seconds):
    """Formats raw seconds into human-readable duration like '8h 04m' or '2m 15s'"""
    sec = int(round(seconds))
    if sec < 60:
        return f"{sec}s"
    mins = sec // 60
    rem_sec = sec % 60
    if mins < 60:
        return f"{mins}m {rem_sec:02d}s" if rem_sec else f"{mins}m"
    hrs = mins // 60
    rem_mins = mins % 60
    return f"{hrs}h {rem_mins:02d}m"


def dashboard_view(request):
    """
    Renders the modern Executive & Admin Analytics Dashboard.
    Provides software evaluation, audio duration analytics, file taxonomy breakdown,
    and comprehensive user tracking & management.
    """
    return render(request, 'transcriber/dashboard.html', {
        'page_title': 'NOVUscribe Analytics & User Intelligence',
        'user': request.user
    })


def dashboard_stats_api_view(request):
    """
    API: Returns aggregated analytics on:
    1. Overall KPIs (audio duration volume, total jobs, user counts, avg length)
    2. Audio Volume Evolution Timeline (daily audio time & jobs)
    3. User Growth & Activity Evolution
    4. Category Analytics:
       - Ingestion modes (Audio upload, Live mic, Real-time stream, Video extraction, YouTube)
       - File extensions (.mp3, .wav, .m4a, .mp4, .stream, etc.)
       - Duration length tiers (<2m, 2-10m, 10-30m, 30m+)
       - Language distribution (Luganda, English, Swahili, French, Lingala)
    """
    from collections import defaultdict
    from datetime import datetime, timedelta
    from django.utils import timezone

    time_range = request.GET.get('range', 'all').lower()
    now = timezone.now()

    qs = Transcription.objects.all().order_by('created_at')
    if time_range == '7d':
        cutoff = now - timedelta(days=7)
        qs = qs.filter(created_at__gte=cutoff)
    elif time_range == '30d':
        cutoff = now - timedelta(days=30)
        qs = qs.filter(created_at__gte=cutoff)

    all_transcriptions = list(qs)
    all_users = list(User.objects.all().order_by('date_joined'))

    total_seconds = 0.0
    timeline = defaultdict(lambda: {'count': 0, 'seconds': 0.0})
    source_modes = defaultdict(lambda: {'count': 0, 'seconds': 0.0})
    file_formats = defaultdict(lambda: {'count': 0, 'seconds': 0.0})
    length_tiers = {
        '<2m': {'label': 'Quick (< 2m)', 'count': 0, 'seconds': 0.0},
        '2-10m': {'label': 'Short (2 - 10m)', 'count': 0, 'seconds': 0.0},
        '10-30m': {'label': 'Medium (10 - 30m)', 'count': 0, 'seconds': 0.0},
        '30m+': {'label': 'Extended (30m+)', 'count': 0, 'seconds': 0.0},
    }
    languages = defaultdict(lambda: {'count': 0, 'seconds': 0.0})
    user_activity_counts = defaultdict(int)

    for t in all_transcriptions:
        sec = _extract_audio_duration_seconds(t.formatted, t.transcription)
        total_seconds += sec

        d_str = t.created_at.strftime('%Y-%m-%d')
        timeline[d_str]['count'] += 1
        timeline[d_str]['seconds'] += sec

        # Source mode & format
        mode, ext = _categorize_transcription_file(t.original_name, t.audio_path)
        source_modes[mode]['count'] += 1
        source_modes[mode]['seconds'] += sec

        file_formats[ext]['count'] += 1
        file_formats[ext]['seconds'] += sec

        # Duration tier
        if sec < 120:
            tier_k = '<2m'
        elif sec < 600:
            tier_k = '2-10m'
        elif sec < 1800:
            tier_k = '10-30m'
        else:
            tier_k = '30m+'
        length_tiers[tier_k]['count'] += 1
        length_tiers[tier_k]['seconds'] += sec

        # Language normalization
        raw_lang = (t.language or 'Other').strip()
        l_low = raw_lang.lower()
        if l_low in ('en', 'english'):
            norm_lang = 'English'
        elif l_low in ('lg', 'luganda'):
            norm_lang = 'Luganda'
        elif l_low in ('sw', 'swahili'):
            norm_lang = 'Swahili'
        elif l_low in ('fr', 'french'):
            norm_lang = 'French'
        elif l_low in ('ln', 'lingala'):
            norm_lang = 'Lingala'
        else:
            norm_lang = raw_lang.capitalize()
        languages[norm_lang]['count'] += 1
        languages[norm_lang]['seconds'] += sec

        if t.user_id:
            user_activity_counts[t.user_id] += 1

    total_jobs = len(all_transcriptions)
    avg_sec = (total_seconds / total_jobs) if total_jobs > 0 else 0.0

    # User timeline & growth
    user_reg_by_date = defaultdict(int)
    for u in all_users:
        u_d = u.date_joined.strftime('%Y-%m-%d')
        user_reg_by_date[u_d] += 1

    # Build chronological timeline
    all_dates = sorted(set(list(timeline.keys()) + list(user_reg_by_date.keys())))
    timeline_records = []
    user_evolution_records = []
    cum_hours = 0.0
    cum_users = 0

    for d in all_dates:
        t_data = timeline.get(d, {'count': 0, 'seconds': 0.0})
        mins = round(t_data['seconds'] / 60.0, 1)
        hrs = round(t_data['seconds'] / 3600.0, 2)
        cum_hours = round(cum_hours + hrs, 2)

        try:
            d_obj = datetime.strptime(d, '%Y-%m-%d')
            label = d_obj.strftime('%b %d')
        except Exception:
            label = d

        timeline_records.append({
            'date': d,
            'label': label,
            'minutes': mins,
            'hours': hrs,
            'jobs': t_data['count'],
            'cumulative_hours': cum_hours
        })

        new_u = user_reg_by_date.get(d, 0)
        cum_users += new_u
        user_evolution_records.append({
            'date': d,
            'label': label,
            'new_users': new_u,
            'cumulative_users': cum_users,
            'active_jobs': t_data['count']
        })

    # Prepare categories lists sorted by count
    def _to_sorted_list(d_dict):
        res = []
        for name, data in d_dict.items():
            cnt = data['count']
            s = data['seconds']
            pct = round((cnt / total_jobs * 100), 1) if total_jobs > 0 else 0
            time_pct = round((s / total_seconds * 100), 1) if total_seconds > 0 else 0
            res.append({
                'name': name,
                'count': cnt,
                'seconds': round(s, 1),
                'minutes': round(s / 60.0, 1),
                'hours': round(s / 3600.0, 2),
                'formatted': _format_seconds_to_human(s),
                'percentage': pct,
                'time_percentage': time_pct
            })
        res.sort(key=lambda x: x['count'], reverse=True)
        return res

    sources_list = _to_sorted_list(source_modes)
    formats_list = _to_sorted_list(file_formats)
    langs_list = _to_sorted_list(languages)

    tiers_list = []
    for k in ['<2m', '2-10m', '10-30m', '30m+']:
        data = length_tiers[k]
        cnt = data['count']
        s = data['seconds']
        pct = round((cnt / total_jobs * 100), 1) if total_jobs > 0 else 0
        time_pct = round((s / total_seconds * 100), 1) if total_seconds > 0 else 0
        tiers_list.append({
            'key': k,
            'label': data['label'],
            'count': cnt,
            'seconds': round(s, 1),
            'minutes': round(s / 60.0, 1),
            'hours': round(s / 3600.0, 2),
            'formatted': _format_seconds_to_human(s),
            'percentage': pct,
            'time_percentage': time_pct
        })

    active_reg_users = len(user_activity_counts)
    guest_jobs = qs.filter(user__isnull=True).count()

    response_data = {
        'success': True,
        'kpi': {
            'total_jobs': total_jobs,
            'total_seconds': round(total_seconds, 1),
            'total_minutes': round(total_seconds / 60.0, 1),
            'total_hours': round(total_seconds / 3600.0, 2),
            'total_formatted': _format_seconds_to_human(total_seconds),
            'avg_duration_seconds': round(avg_sec, 1),
            'avg_duration_formatted': _format_seconds_to_human(avg_sec),
            'total_users': len(all_users),
            'active_users': active_reg_users + (1 if guest_jobs > 0 else 0),
            'registered_users_count': len(all_users),
            'guest_jobs': guest_jobs,
        },
        'audio_volume_timeline': timeline_records,
        'user_evolution': user_evolution_records,
        'categories': {
            'source_modes': sources_list,
            'file_formats': formats_list,
            'length_tiers': tiers_list,
            'languages': langs_list
        }
    }
    return JsonResponse(response_data)


def dashboard_users_api_view(request):
    """
    API: Returns list of all registered users with transcription volume statistics,
    plus a summarized entry for Guest contributors.
    Supports ?search= parameter.
    """
    from django.db.models import Q

    search_q = request.GET.get('search', '').strip().lower()

    users_qs = User.objects.all().order_by('-date_joined')
    if search_q:
        users_qs = users_qs.filter(
            Q(username__icontains=search_q) | Q(email__icontains=search_q)
        )

    users_data = []
    for u in users_qs:
        user_transcriptions = list(u.transcriptions.all().order_by('-created_at'))
        u_sec = sum(_extract_audio_duration_seconds(t.formatted, t.transcription) for t in user_transcriptions)
        last_t = user_transcriptions[0].created_at if user_transcriptions else None

        users_data.append({
            'id': u.id,
            'username': u.username,
            'email': u.email or '—',
            'is_active': u.is_active,
            'is_staff': u.is_staff,
            'is_superuser': u.is_superuser,
            'date_joined': u.date_joined.strftime('%Y-%m-%d %H:%M'),
            'last_login': u.last_login.strftime('%Y-%m-%d %H:%M') if u.last_login else 'Never',
            'transcriptions_count': len(user_transcriptions),
            'total_seconds': round(u_sec, 1),
            'total_formatted': _format_seconds_to_human(u_sec),
            'last_active': last_t.strftime('%Y-%m-%d %H:%M') if last_t else (u.last_login.strftime('%Y-%m-%d %H:%M') if u.last_login else '—'),
            'is_guest': False
        })

    # Summary entry for Guest sessions
    if not search_q or 'guest' in search_q or 'incognito' in search_q:
        guest_transcriptions = list(Transcription.objects.filter(user__isnull=True).order_by('-created_at'))
        if guest_transcriptions:
            g_sec = sum(_extract_audio_duration_seconds(t.formatted, t.transcription) for t in guest_transcriptions)
            last_gt = guest_transcriptions[0].created_at if guest_transcriptions else None
            users_data.insert(0, {
                'id': 'guest',
                'username': 'Guest / Incognito Sessions',
                'email': 'guest-anonymous@session.local',
                'is_active': True,
                'is_staff': False,
                'is_superuser': False,
                'date_joined': guest_transcriptions[-1].created_at.strftime('%Y-%m-%d %H:%M') if guest_transcriptions else '—',
                'last_login': last_gt.strftime('%Y-%m-%d %H:%M') if last_gt else '—',
                'transcriptions_count': len(guest_transcriptions),
                'total_seconds': round(g_sec, 1),
                'total_formatted': _format_seconds_to_human(g_sec),
                'last_active': last_gt.strftime('%Y-%m-%d %H:%M') if last_gt else '—',
                'is_guest': True
            })

    return JsonResponse({'success': True, 'users': users_data})


def dashboard_user_transcriptions_api_view(request, user_id):
    """
    API: Returns transcription portfolio for a specific user (or 'guest').
    """
    if str(user_id).lower() == 'guest':
        qs = Transcription.objects.filter(user__isnull=True).order_by('-created_at')
        user_name = "Guest / Incognito Sessions"
    else:
        try:
            target_user = User.objects.get(id=user_id)
            user_name = target_user.username
            qs = Transcription.objects.filter(user=target_user).order_by('-created_at')
        except User.DoesNotExist:
            return JsonResponse({'success': False, 'error': 'User not found'}, status=404)

    items = []
    for t in qs:
        sec = _extract_audio_duration_seconds(t.formatted, t.transcription)
        mode, ext = _categorize_transcription_file(t.original_name, t.audio_path)
        preview = (t.transcription or '')[:140].strip()
        if len(t.transcription or '') > 140:
            preview += '...'

        items.append({
            'id': str(t.id),
            'original_name': t.original_name,
            'language': t.language or 'auto',
            'source_mode': mode,
            'file_format': ext,
            'duration_seconds': round(sec, 1),
            'duration_formatted': _format_seconds_to_human(sec),
            'created_at': t.created_at.strftime('%Y-%m-%d %H:%M'),
            'preview': preview
        })

    return JsonResponse({
        'success': True,
        'user_name': user_name,
        'total_count': len(items),
        'transcriptions': items
    })


@csrf_exempt
def dashboard_user_create_view(request):
    """API: Creates a new user directly from the dashboard"""
    if request.method != 'POST':
        return JsonResponse({'error': 'POST method required', 'success': False}, status=405)

    try:
        data = json.loads(request.body.decode('utf-8'))
    except Exception:
        data = request.POST

    username = data.get('username', '').strip()
    email = data.get('email', '').strip()
    password = data.get('password', '').strip()
    is_staff = bool(data.get('is_staff', False))

    if not username or not password:
        return JsonResponse({'success': False, 'error': 'Username and password are required'}, status=400)

    if User.objects.filter(username__iexact=username).exists():
        return JsonResponse({'success': False, 'error': f"Username '{username}' already exists"}, status=400)

    try:
        user = User.objects.create_user(username=username, email=email, password=password)
        if is_staff:
            user.is_staff = True
            user.save()
        return JsonResponse({
            'success': True,
            'message': f"User '{username}' created successfully",
            'user': {
                'id': user.id,
                'username': user.username,
                'email': user.email,
                'is_staff': user.is_staff
            }
        })
    except Exception as e:
        return JsonResponse({'success': False, 'error': str(e)}, status=500)


@csrf_exempt
def dashboard_user_toggle_status_view(request, user_id):
    """API: Toggles a user's active/suspended status"""
    if request.method != 'POST':
        return JsonResponse({'error': 'POST method required', 'success': False}, status=405)

    try:
        user = User.objects.get(id=user_id)
        user.is_active = not user.is_active
        user.save()
        status_text = "Activated" if user.is_active else "Suspended / Deactivated"
        return JsonResponse({
            'success': True,
            'is_active': user.is_active,
            'message': f"User '{user.username}' is now {status_text}"
        })
    except User.DoesNotExist:
        return JsonResponse({'success': False, 'error': 'User not found'}, status=404)
    except Exception as e:
        return JsonResponse({'success': False, 'error': str(e)}, status=500)


@csrf_exempt
def dashboard_user_toggle_role_view(request, user_id):
    """API: Toggles a user's staff/admin role"""
    if request.method != 'POST':
        return JsonResponse({'error': 'POST method required', 'success': False}, status=405)

    try:
        user = User.objects.get(id=user_id)
        user.is_staff = not user.is_staff
        user.save()
        role_text = "Staff / Admin" if user.is_staff else "Standard User"
        return JsonResponse({
            'success': True,
            'is_staff': user.is_staff,
            'message': f"User '{user.username}' is now assigned {role_text}"
        })
    except User.DoesNotExist:
        return JsonResponse({'success': False, 'error': 'User not found'}, status=404)
    except Exception as e:
        return JsonResponse({'success': False, 'error': str(e)}, status=500)


@csrf_exempt
def dashboard_user_delete_view(request, user_id):
    """
    API: Deletes a user.
    Preserves all of the user's transcriptions by unlinking them (setting user=None),
    so historical audio transcriptions remain safely in the system.
    """
    if request.method not in ('POST', 'DELETE'):
        return JsonResponse({'error': 'POST or DELETE method required', 'success': False}, status=405)

    try:
        user = User.objects.get(id=user_id)
        u_name = user.username
        # Preserve transcriptions by setting user to None
        Transcription.objects.filter(user=user).update(user=None)
        user.delete()
        return JsonResponse({
            'success': True,
            'message': f"User '{u_name}' removed. Their audio transcriptions have been preserved as archival records."
        })
    except User.DoesNotExist:
        return JsonResponse({'success': False, 'error': 'User not found'}, status=404)
    except Exception as e:
        return JsonResponse({'success': False, 'error': str(e)}, status=500)

