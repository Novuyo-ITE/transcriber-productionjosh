import os
import threading
from django.apps import AppConfig


class TranscriberConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'transcriber'

    def ready(self):
        # If RunPod Serverless is configured, all model inference runs on RunPod cloud GPU.
        # Skip local model loading to save CPU/RAM.
        from .runpod_client import is_runpod_configured
        if is_runpod_configured():
            print("[STARTUP] RunPod Serverless configured. GPU transcription will run on RunPod.")
            return

        # Otherwise, if running locally, optionally pre-warm Faster Whisper Medium and CAM++ in background
        if os.environ.get('RUN_MAIN') == 'true' or not os.environ.get('DJANGO_SETTINGS_MODULE'):
            def preload_streaming_models():
                try:
                    import torch
                    from .stt_service import stt_service
                    from .diarization_service import acoustic_diarization_service
                    print("[STARTUP] Pre-warming local Faster Whisper STT model...")
                    stt_service.preload_model()
                    print("[STARTUP] Pre-warming local CAM++ Diarization model...")
                    acoustic_diarization_service._init_models()
                    print("[STARTUP] Local models are ready.")
                except ImportError:
                    print("[STARTUP] Local PyTorch/models not found. Operating in cloud/RunPod mode.")
                except Exception as e:
                    print(f"[STARTUP] Pre-warm note: {e}")

            threading.Thread(target=preload_streaming_models, daemon=True).start()

