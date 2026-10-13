"""
Speech-to-Text service using Faster-Whisper (CTranslate2)
Optimized for high-speed, GPU-accelerated, robust multilingual transcription.
"""
import os
import gc
import re
import time
import logging
import threading
import torch
import numpy as np
from django.conf import settings

logger = logging.getLogger(__name__)


def _format_time_str(seconds: float) -> str:
    total_sec = max(0, int(seconds))
    hrs = total_sec // 3600
    mins = (total_sec % 3600) // 60
    secs = total_sec % 60
    if hrs > 0:
        return f"{hrs:02d}:{mins:02d}:{secs:02d}"
    return f"{mins:02d}:{secs:02d}"


def filter_streaming_hallucinations(text: str) -> str:
    """
    Strips musical notes (e.g. 🎼, ♪, ♫, 🎶, 🎵), subtitle artifacts ([Music], (Music)),
    and suppresses phantom noise hallucinations (e.g. '🎼Yeah. 🎼', 'yeha hello', 'thank you for watching').
    Returns cleaned text, or '' if the text is purely noise/hallucination.
    """
    if not text:
        return ""

    # 1. Strip musical note symbols and subtitle audio tags
    cleaned = re.sub(r'[\u2669-\u266f\U0001f3b5-\U0001f3bc♪♫♬♭♮♯🎼🎶🎵]', '', text)
    cleaned = re.sub(r'\[\s*["\'].*?["\']\s*\]', '', cleaned)
    cleaned = re.sub(r'\[(?:music|applause|laughter|bgm|silence|cheering|singing|audio|sound|noise)\]', '', cleaned, flags=re.IGNORECASE)
    cleaned = re.sub(r'\((?:music|applause|laughter|bgm|silence|cheering|singing|audio|sound|noise)\)', '', cleaned, flags=re.IGNORECASE)

    # 2. Check if the remaining text is purely a phantom hallucination
    norm = re.sub(r'[^a-zA-Z\s]', '', cleaned).lower().strip()
    words = norm.split()

    PHANTOM_PATTERNS = {
        "thanks for watching", "thank you for watching", "please subscribe",
        "like and subscribe", "subtitles", "transcript", "caption", "watching",
        "closed captions", "subtitles by"
    }

    phrase = " ".join(words)
    if phrase in PHANTOM_PATTERNS:
        return ""

    if len(words) <= 1 and (len(phrase) <= 1 or phrase in PHANTOM_PATTERNS):
        return ""

    # 3. Clean typos and disfluencies
    cleaned = re.sub(r'(?i)\byeha\b', 'yeah', cleaned)
    filler_pattern = r'(?i)\b(u+h+|u+m+|u+n+h+|e+h+|e+r+|a+h+|h+m+|m+h+m+|u+h+m+|u+m+h+)\b'
    cleaned = re.sub(filler_pattern, '', cleaned)
    cleaned = re.sub(r'\s+', ' ', cleaned).strip()

    return cleaned


class FasterWhisperSTTService:
    """Speech-to-Text service using Faster Whisper (CTranslate2) on GPU/CPU"""

    def __init__(self):
        self.model = None
        self.warmed_up = False
        self.device = None
        self.compute_type = None
        self.model_size = None
        self._lock = threading.Lock()

    def _init_model(self):
        """Lazy load Faster Whisper model with CUDA / float16 auto-fallback to CPU"""
        if self.model is None:
            with self._lock:
                if self.model is not None:
                    return
                try:
                    from faster_whisper import WhisperModel

                    model_size = os.getenv("FASTER_WHISPER_MODEL", "medium").strip()
                    self.model_size = model_size

                    try:
                        base_dir = settings.BASE_DIR
                    except Exception:
                        base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
                    cache_dir = os.path.join(base_dir, ".cache", "whisper")
                    os.makedirs(cache_dir, exist_ok=True)

                    device_pref = os.getenv("WHISPER_DEVICE", "cuda").strip().lower()
                    has_cuda = torch.cuda.is_available() and device_pref == "cuda"

                    if has_cuda:
                        try:
                            logger.info(f"[Faster-Whisper] Loading model '{model_size}' on CUDA (float16)...")
                            self.model = WhisperModel(
                                model_size,
                                device="cuda",
                                compute_type="float16",
                                download_root=cache_dir,
                            )
                            self.device = "cuda"
                            self.compute_type = "float16"
                            logger.info(f"[Faster-Whisper] Model '{model_size}' loaded on CUDA successfully.")
                        except Exception as cuda_err:
                            logger.warning(f"[Faster-Whisper] CUDA initialization failed: {cuda_err}. Falling back to CPU...")
                            has_cuda = False

                    if not has_cuda or self.model is None:
                        logger.info(f"[Faster-Whisper] Loading model '{model_size}' on CPU (int8)...")
                        self.model = WhisperModel(
                            model_size,
                            device="cpu",
                            compute_type="int8",
                            download_root=cache_dir,
                        )
                        self.device = "cpu"
                        self.compute_type = "int8"
                        logger.info(f"[Faster-Whisper] Model '{model_size}' loaded on CPU successfully.")

                except Exception as e:
                    logger.error(f"[Faster-Whisper] Error loading model: {e}", exc_info=True)
                    self.model = None

    def preload_model(self):
        """Pre-warm model in memory"""
        self._init_model()
        self.warmed_up = self.model is not None
        return self.warmed_up

    def _transcribe_segment(self, audio_data, target_lang, beam_size, vad_filter, time_offset=0.0, progress_callback=None, total_duration_sec=0.0, temperature=0.0):
        """Transcribe an in-memory numpy audio array or slice with Faster Whisper"""
        segments_gen, info = self.model.transcribe(
            audio_data,
            language=target_lang,
            beam_size=beam_size,
            vad_filter=vad_filter,
            vad_parameters=dict(
                min_silence_duration_ms=400,
                speech_pad_ms=250,
                threshold=0.35
            ),
            condition_on_previous_text=False,
            temperature=temperature,
            compression_ratio_threshold=2.4,
            no_speech_threshold=0.5,
            log_prob_threshold=-1.0
        )
        chunks = []
        text_parts = []
        for seg in segments_gen:
            # Skip if Whisper marks segment as high no-speech probability
            if hasattr(seg, 'no_speech_prob') and seg.no_speech_prob > 0.45:
                continue
            if hasattr(seg, 'avg_logprob') and seg.avg_logprob < -1.0:
                continue
            seg_text = filter_streaming_hallucinations(seg.text)
            if seg_text:
                text_parts.append(seg_text)
                chunks.append({
                    "timestamp": [round(seg.start + time_offset, 2), round(seg.end + time_offset, 2)],
                    "text": seg_text
                })
            current_audio_time = seg.end + time_offset
            if progress_callback and total_duration_sec > 0:
                try:
                    progress_callback(current_audio_time, total_duration_sec)
                except Exception as p_err:
                    logger.debug(f"Progress callback error: {p_err}")
        return chunks, text_parts, info

    def _transcribe_chunked(self, audio_array, target_lang, beam_size, vad_filter, chunk_sec=600.0, fallback_lang="en", progress_callback=None, total_duration_sec=0.0, temperature=0.0):
        """Slice long audio into memory-safe temporal windows and transcribe each window sequentially"""
        total_samples = len(audio_array)
        chunk_samples = int(chunk_sec * 16000)
        num_chunks = int(np.ceil(total_samples / chunk_samples))
        
        all_chunks = []
        all_text_parts = []
        detected_lang = fallback_lang

        logger.info(f"[Faster-Whisper Chunking] Slicing into {num_chunks} chunks ({chunk_sec/60:.1f} min each) to prevent memory allocation errors...")

        for i in range(num_chunks):
            start_idx = i * chunk_samples
            end_idx = min(start_idx + chunk_samples, total_samples)
            time_offset = start_idx / 16000.0
            
            chunk_data = audio_array[start_idx:end_idx]
            if len(chunk_data) < 1600:  # Less than 0.1s
                continue

            chunk_dur = len(chunk_data) / 16000.0
            logger.info(f"[Faster-Whisper Chunking] Processing chunk {i+1}/{num_chunks} [{_format_time_str(time_offset)} -> {_format_time_str(time_offset + chunk_dur)}]...")

            try:
                c_chunks, c_texts, info = self._transcribe_segment(
                    chunk_data,
                    target_lang,
                    beam_size,
                    vad_filter,
                    time_offset=time_offset,
                    progress_callback=progress_callback,
                    total_duration_sec=total_duration_sec or (total_samples / 16000.0),
                    temperature=temperature
                )
                if info and hasattr(info, 'language') and info.language:
                    detected_lang = info.language
                all_chunks.extend(c_chunks)
                all_text_parts.extend(c_texts)
            except Exception as chunk_exc:
                logger.error(f"[Faster-Whisper Chunking] Error processing chunk {i+1}: {chunk_exc}", exc_info=True)
            finally:
                gc.collect()
                if torch.cuda.is_available():
                    torch.cuda.empty_cache()

        full_text = " ".join(all_text_parts).strip()
        logger.info(f"[Faster-Whisper Chunking] Completed: {len(all_chunks)} total segments, {len(full_text)} characters.")
        return {
            "text": full_text,
            "chunks": all_chunks,
            "language": detected_lang
        }

    def transcribe_audio_file(self, file_path, language="en", beam_size=5, vad_filter=True, progress_callback=None, temperature=0.0):
        """
        Transcribe an audio file using Faster Whisper with automatic memory-safe chunking for long files.

        Args:
            file_path: Path to audio file (MP3, WAV, etc.)
            language: Language code ('en', 'sw', 'fr', etc. or None for auto-detect)
            beam_size: Beam search width (default 5)
            vad_filter: Whether to enable Silero VAD filtering
            progress_callback: Optional callable(current_sec, total_sec) for real-time progress & ETA calculation

        Returns:
            dict with:
                - text: Complete transcribed text
                - chunks: List of {"timestamp": [start, end], "text": segment_text}
                - language: Detected/specified language
        """
        if not file_path or not os.path.exists(file_path):
            return {"text": "", "chunks": [], "language": language}

        file_path = os.path.abspath(file_path)
        self._init_model()
        if not self.model:
            logger.error("[Faster-Whisper] Model is not loaded.")
            return {"text": "", "chunks": [], "language": language}

        target_lang = language if language and language != "auto" else None

        try:
            from faster_whisper.audio import decode_audio
            audio_array = decode_audio(file_path, sampling_rate=16000)
            total_samples = len(audio_array)
            total_duration_sec = total_samples / 16000.0
            logger.info(f"[Faster-Whisper] Loaded audio: {total_duration_sec:.1f}s ({total_duration_sec/60.0:.1f} min, {total_samples} samples)")

            # Files longer than 10 minutes (600s) are chunked to prevent huge contiguous NumPy FFT allocations
            CHUNK_DURATION_SEC = 600.0
            CHUNK_SAMPLES = int(CHUNK_DURATION_SEC * 16000)

            if total_samples <= CHUNK_SAMPLES:
                try:
                    chunks, text_parts, info = self._transcribe_segment(
                        audio_array,
                        target_lang,
                        beam_size,
                        vad_filter,
                        time_offset=0.0,
                        progress_callback=progress_callback,
                        total_duration_sec=total_duration_sec,
                        temperature=temperature
                    )
                    detected_lang = info.language if info else language
                    full_text = " ".join(text_parts).strip()
                    logger.info(f"[Faster-Whisper] Transcribed {len(chunks)} chunks, text length: {len(full_text)}")
                    return {
                        "text": full_text,
                        "chunks": chunks,
                        "language": detected_lang
                    }
                except (MemoryError, Exception) as mem_err:
                    logger.warning(f"[Faster-Whisper] Direct transcription error ({mem_err}). Retrying with 5-minute chunking...")
                    return self._transcribe_chunked(
                        audio_array,
                        target_lang,
                        beam_size,
                        vad_filter,
                        chunk_sec=300.0,
                        fallback_lang=language,
                        progress_callback=progress_callback,
                        total_duration_sec=total_duration_sec,
                        temperature=temperature
                    )
            else:
                logger.info(f"[Faster-Whisper] Long audio ({total_duration_sec/60:.1f} min). Running memory-safe chunked transcription...")
                return self._transcribe_chunked(
                    audio_array,
                    target_lang,
                    beam_size,
                    vad_filter,
                    chunk_sec=CHUNK_DURATION_SEC,
                    fallback_lang=language,
                    progress_callback=progress_callback,
                    total_duration_sec=total_duration_sec,
                    temperature=temperature
                )

        except Exception as e:
            logger.error(f"[Faster-Whisper] Transcription error: {e}", exc_info=True)
            return {"text": "", "chunks": [], "language": language}
        finally:
            if total_duration_sec > 60.0:
                gc.collect()
                if torch.cuda.is_available():
                    torch.cuda.empty_cache()


# Global STT instance
stt_service = FasterWhisperSTTService()


class SenseVoiceSTTService:
    """Speech-to-Text service using FunASR SenseVoiceSmall for ultra-fast live audio and streaming transcription"""

    def __init__(self):
        self.model = None
        self.device = None
        self._lock = threading.Lock()

    def _init_model(self):
        if self.model is None:
            with self._lock:
                if self.model is not None:
                    return
                try:
                    from funasr import AutoModel
                    pref_device = "cuda:0" if torch.cuda.is_available() else "cpu"
                    logger.info(f"[SenseVoice] Loading SenseVoiceSmall model on {pref_device}...")
                    self.model = AutoModel(
                        model="iic/SenseVoiceSmall",
                        vad_model="fsmn-vad",
                        vad_kwargs={"max_single_segment_time": 30000},
                        device=pref_device,
                        disable_update=True,
                        disable_pbar=True,
                    )
                    self.device = pref_device
                    logger.info(f"[SenseVoice] SenseVoiceSmall model loaded successfully on {pref_device}.")
                except Exception as e:
                    logger.error(f"[SenseVoice] Error loading SenseVoiceSmall: {e}", exc_info=True)
                    self.model = None

    def normalize_language(self, language: str) -> str:
        """Map language codes to SenseVoice valid codes ('auto', 'en', 'zh', 'yue', 'ja', 'ko')"""
        if not language:
            return "auto"
        lang_lower = str(language).lower().strip()
        if lang_lower in ("en", "english"):
            return "en"
        elif lang_lower in ("zh", "chinese", "mandarin"):
            return "zh"
        elif lang_lower in ("yue", "cantonese"):
            return "yue"
        elif lang_lower in ("ja", "japanese"):
            return "ja"
        elif lang_lower in ("ko", "korean"):
            return "ko"
        return "auto"

    def clean_transcript(self, raw_text: str, filter_disfluencies: bool = True, language: str = "auto") -> str:
        """
        Clean and format SenseVoice raw text by removing acoustic/emotion tags,
        filtering vocal disfluencies (e.g. 'unhh', 'um', 'uh', 'er'),
        and normalizing punctuation and spacing.
        """
        if not raw_text:
            return ""

        try:
            from funasr.utils.postprocess_utils import rich_transcription_postprocess
            cleaned = rich_transcription_postprocess(raw_text)
        except Exception:
            cleaned = raw_text

        # 1. Clean any leftover special tokens like <|...|> and musical note / noise hallucinations
        cleaned = re.sub(r'<\|[^|>]+\|>', '', cleaned)
        cleaned = filter_streaming_hallucinations(cleaned)

        # 2. Filter vocal hesitation & disfluency sounds
        if filter_disfluencies:
            filler_pattern = r'(?i)\b(u+h+|u+m+|u+n+h+|e+h+|e+r+|a+h+|h+m+|m+h+m+|u+h+m+|u+m+h+)\b'
            cleaned = re.sub(filler_pattern, '', cleaned)
            cleaned = re.sub(r'(?i)\b(et|eh)\b(?=[\s\.,!\?]+)', '', cleaned)

        # 3. Clean and normalize punctuation artifacts
        cleaned = re.sub(r'\s*,\s*,+', ', ', cleaned)
        cleaned = re.sub(r'\s*\.{2,}', '...', cleaned)
        cleaned = re.sub(r'^[,\.\?!;:\s\-]+', '', cleaned)
        cleaned = re.sub(r'\s*,\s*([\.!\?])', r'\1', cleaned)
        cleaned = re.sub(r'\s*,\s*', ', ', cleaned)
        cleaned = re.sub(r'\s+', ' ', cleaned).strip()

        if cleaned and cleaned[0].islower():
            cleaned = cleaned[0].upper() + cleaned[1:]

        return cleaned

    def transcribe_audio_file(self, file_path, language="auto"):
        if not file_path or not os.path.exists(file_path):
            return {"text": "", "chunks": [], "language": language}

        self._init_model()
        if not self.model:
            logger.warning("[SenseVoice] SenseVoice model not available, falling back to Faster-Whisper.")
            return stt_service.transcribe_audio_file(file_path, language=language)

        try:
            target_lang = self.normalize_language(language)
            res = self.model.generate(
                input=file_path,
                cache={},
                language=target_lang,
                use_itn=True,
                batch_size_s=60,
                merge_vad=True,
                merge_length_s=15,
            )
            raw_text = ""
            if res and isinstance(res, list) and len(res) > 0:
                raw_item = res[0]
                if isinstance(raw_item, dict):
                    raw_text = raw_item.get("text", "")
                elif isinstance(raw_item, str):
                    raw_text = raw_item
            elif isinstance(res, dict):
                raw_text = res.get("text", "")

            clean_text = self.clean_transcript(raw_text, language=target_lang)
            chunks = []
            if clean_text:
                chunks.append({"timestamp": [0.0, 0.0], "text": clean_text})

            logger.info(f"[SenseVoice] Audio transcribed successfully: {clean_text[:60]}...")
            return {
                "text": clean_text,
                "chunks": chunks,
                "language": language
            }
        except Exception as e:
            logger.error(f"[SenseVoice] Transcription error: {e}. Falling back to Faster-Whisper...", exc_info=True)
            return stt_service.transcribe_audio_file(file_path, language=language)


class StreamingSessionSpeakerTracker:
    """
    Tracks and clusters active speakers in real-time streaming conversations using CAM++ voiceprints.
    Associates incoming audio chunks with the most probable speaker (Speaker 1, Speaker 2, ...)
    or identifies when a new speaker begins talking.
    """

    def __init__(self, similarity_threshold: float = 0.62):
        self.similarity_threshold = similarity_threshold
        self.sessions = {}  # session_id -> { "speakers": [ { "id": 1, "name": "Speaker 1", "centroid": emb, "count": 1 } ], "last_speaker": 1, "last_active": time.time() }
        self._lock = threading.Lock()

    def get_or_create_session(self, session_id: str) -> dict:
        now = time.time()
        with self._lock:
            stale_keys = [k for k, v in self.sessions.items() if now - v.get("last_active", 0) > 7200]
            for k in stale_keys:
                self.sessions.pop(k, None)

            if session_id not in self.sessions:
                self.sessions[session_id] = {
                    "speakers": [],
                    "last_speaker": 1,
                    "last_active": now
                }
            else:
                self.sessions[session_id]["last_active"] = now
            return self.sessions[session_id]

    def reset_session(self, session_id: str):
        with self._lock:
            self.sessions.pop(session_id, None)

    def identify_speaker(self, session_id: str, audio_path: str, text: str = "") -> dict:
        """
        Extract speaker embedding from audio chunk and match against known speakers in this session.
        Returns dict: {"speaker": "Speaker 1", "speaker_id": 1, "is_new_speaker": bool, "similarity": float}
        Guards strictly against single-word noise blips creating new speaker identities.
        """
        sess = self.get_or_create_session(session_id)
        from .diarization_service import acoustic_diarization_service, load_audio_16k_mono

        words = [w for w in re.split(r'\s+', (text or "").strip()) if w]
        is_single_word = len(words) <= 1

        try:
            acoustic_diarization_service._init_models()
            cam_model = acoustic_diarization_service.cam_model
            if not cam_model or not os.path.exists(audio_path):
                spk_id = sess.get("last_speaker", 1)
                return {"speaker": f"Speaker {spk_id}", "speaker_id": spk_id, "is_new_speaker": False, "similarity": 1.0}

            audio_data, sr = load_audio_16k_mono(audio_path)
            duration_sec = len(audio_data) / float(sr) if sr > 0 else 0.0

            if len(audio_data) < int(0.35 * sr):
                spk_id = sess.get("last_speaker", 1)
                return {"speaker": f"Speaker {spk_id}", "speaker_id": spk_id, "is_new_speaker": False, "similarity": 0.5}

            cam_out = cam_model.generate(input=audio_data, fs=sr)
            emb = None
            if isinstance(cam_out, list) and len(cam_out) > 0:
                elem = cam_out[0]
                if isinstance(elem, dict):
                    emb = elem.get("spk_embedding", elem.get("embedding"))
                elif isinstance(elem, (np.ndarray, torch.Tensor)):
                    emb = elem
            elif isinstance(cam_out, dict):
                emb = cam_out.get("spk_embedding", cam_out.get("embedding"))

            if emb is None:
                spk_id = sess.get("last_speaker", 1)
                return {"speaker": f"Speaker {spk_id}", "speaker_id": spk_id, "is_new_speaker": False, "similarity": 0.5}

            if isinstance(emb, torch.Tensor):
                emb = emb.detach().cpu().numpy()
            emb = np.squeeze(emb).astype(np.float32)
            norm = np.linalg.norm(emb)
            if norm > 0:
                emb = emb / norm

            with self._lock:
                speakers = sess["speakers"]
                if not speakers:
                    new_spk = {
                        "id": 1,
                        "name": "Speaker 1",
                        "centroid": emb,
                        "count": 1
                    }
                    speakers.append(new_spk)
                    sess["last_speaker"] = 1
                    return {"speaker": "Speaker 1", "speaker_id": 1, "is_new_speaker": True, "similarity": 1.0}

                best_sim = -1.0
                best_spk = None
                for spk in speakers:
                    sim = float(np.dot(emb, spk["centroid"]))
                    if sim > best_sim:
                        best_sim = sim
                        best_spk = spk

                # CRITICAL RULE: If the utterance is only 1 word or short noise (< 0.75s),
                # NEVER create a new speaker! Retain the active speaker or closest existing speaker.
                if is_single_word or duration_sec < 0.75:
                    target_spk = best_spk if (best_spk and best_sim >= 0.45) else None
                    if not target_spk:
                        last_id = sess.get("last_speaker", 1)
                        target_spk = next((s for s in speakers if s["id"] == last_id), speakers[0])
                    
                    return {
                        "speaker": target_spk["name"],
                        "speaker_id": target_spk["id"],
                        "is_new_speaker": False,
                        "similarity": best_sim if best_sim > 0 else 0.8
                    }

                if best_sim >= self.similarity_threshold and best_spk is not None:
                    alpha = 0.2
                    updated = (1.0 - alpha) * best_spk["centroid"] + alpha * emb
                    updated_norm = np.linalg.norm(updated)
                    if updated_norm > 0:
                        best_spk["centroid"] = updated / updated_norm
                    best_spk["count"] += 1
                    sess["last_speaker"] = best_spk["id"]
                    return {
                        "speaker": best_spk["name"],
                        "speaker_id": best_spk["id"],
                        "is_new_speaker": False,
                        "similarity": best_sim
                    }
                else:
                    # New speaker identity is only permitted when speaker is speaking at least 2 words
                    # with adequate acoustic duration (>= 0.75s)
                    new_id = len(speakers) + 1
                    new_spk = {
                        "id": new_id,
                        "name": f"Speaker {new_id}",
                        "centroid": emb,
                        "count": 1
                    }
                    speakers.append(new_spk)
                    sess["last_speaker"] = new_id
                    return {
                        "speaker": f"Speaker {new_id}",
                        "speaker_id": new_id,
                        "is_new_speaker": True,
                        "similarity": best_sim
                    }

        except Exception as e:
            logger.warning(f"[StreamingSessionSpeakerTracker] Speaker identification error: {e}")
            spk_id = sess.get("last_speaker", 1)
            return {"speaker": f"Speaker {spk_id}", "speaker_id": spk_id, "is_new_speaker": False, "similarity": 0.5}


# Global Singletons
sensevoice_service = SenseVoiceSTTService()
streaming_speaker_tracker = StreamingSessionSpeakerTracker()
