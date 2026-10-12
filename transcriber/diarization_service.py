"""
Acoustic Speaker Diarization Service
Powered by Alibaba FunASR FSMN-VAD (Voice Activity Detection) + CAM++ (Speaker Voiceprint Embedding & Clustering)
Runs locally on GPU (CUDA) with seamless CPU fallback.
"""
import os
import time
import logging
import threading
import torch
import numpy as np
from typing import List, Dict, Optional, Tuple

logger = logging.getLogger(__name__)


def format_seconds_to_timestamp(seconds: float) -> str:
    """Converts seconds into [MM:SS] or [HH:MM:SS] format"""
    total_sec = max(0, int(seconds))
    hrs = total_sec // 3600
    mins = (total_sec % 3600) // 60
    secs = total_sec % 60
    if hrs > 0:
        return f"{hrs:02d}:{mins:02d}:{secs:02d}"
    return f"{mins:02d}:{secs:02d}"


def load_audio_16k_mono(audio_path: str) -> Tuple[np.ndarray, int]:
    """Robustly load any audio format (MP3, WAV, M4A, etc.) as 16kHz mono numpy array"""
    if not audio_path or not os.path.exists(audio_path):
        return np.array([]), 16000

    try:
        import soundfile as sf
        audio_data, sr = sf.read(audio_path)
        if audio_data.ndim > 1:
            audio_data = np.mean(audio_data, axis=1)
        if sr != 16000:
            try:
                import torchaudio.transforms as T
                tensor_audio = torch.from_numpy(audio_data).float().unsqueeze(0)
                resampler = T.Resample(sr, 16000)
                tensor_16k = resampler(tensor_audio).squeeze(0)
                return tensor_16k.numpy(), 16000
            except Exception:
                from scipy.signal import resample
                num_samples = int(len(audio_data) * 16000 / sr)
                return resample(audio_data, num_samples).astype(np.float32), 16000
        return audio_data.astype(np.float32), sr
    except Exception as e:
        logger.debug(f"soundfile read error: {e}. Falling back to pydub...")

    try:
        from pydub import AudioSegment
        sound = AudioSegment.from_file(audio_path)
        sound = sound.set_frame_rate(16000).set_channels(1)
        samples = np.array(sound.get_array_of_samples()).astype(np.float32) / 32768.0
        return samples, 16000
    except Exception as e2:
        logger.error(f"Failed to load audio with pydub: {e2}")
        return np.array([]), 16000


class AcousticDiarizationService:
    """
    Local GPU-accelerated Speaker Diarization Service
    Combines FSMN-VAD for millisecond boundary detection and CAM++ for acoustic voiceprints.
    """

    def __init__(self):
        self.vad_model = None
        self.cam_model = None
        self.device = None
        self._lock = threading.Lock()
        self._initialized = False

    def _init_models(self):
        """Lazy load FSMN-VAD and CAM++ models on CUDA (GPU) or CPU"""
        if self._initialized:
            return

        with self._lock:
            if self._initialized:
                return

            try:
                from funasr import AutoModel

                pref_device = "cuda:0" if torch.cuda.is_available() else "cpu"
                logger.info(f"[AcousticDiarization] Initializing FSMN-VAD and CAM++ on {pref_device}...")

                # 1. Initialize FSMN-VAD
                try:
                    self.vad_model = AutoModel(
                        model="fsmn-vad",
                        device=pref_device,
                        disable_update=True
                    )
                except Exception as vad_err:
                    logger.warning(f"[AcousticDiarization] VAD CUDA load failed: {vad_err}. Retrying CPU...")
                    self.vad_model = AutoModel(
                        model="fsmn-vad",
                        device="cpu",
                        disable_update=True
                    )

                # 2. Initialize CAM++ (Speaker Verification / Diarization Embedding)
                try:
                    self.cam_model = AutoModel(
                        model="cam++",
                        device=pref_device,
                        disable_update=True
                    )
                except Exception as cam_err:
                    logger.warning(f"[AcousticDiarization] CAM++ CUDA load failed: {cam_err}. Retrying CPU...")
                    self.cam_model = AutoModel(
                        model="cam++",
                        device="cpu",
                        disable_update=True
                    )

                self.device = pref_device
                self._initialized = True
                logger.info(f"[AcousticDiarization] FSMN-VAD + CAM++ successfully initialized on {self.device}.")

            except Exception as e:
                logger.error(f"[AcousticDiarization] Failed to load diarization models: {e}", exc_info=True)
                self.vad_model = None
                self.cam_model = None
                self._initialized = False

    def extract_voiceprint_segments(self, audio_path: str) -> List[Dict]:
        """
        Run FSMN-VAD to detect speech segments and extract CAM++ embeddings for each segment.
        Returns a list of dicts: [{'start': float, 'end': float, 'embedding': np.ndarray}]
        """
        if not audio_path or not os.path.exists(audio_path):
            return []

        self._init_models()
        if not self.vad_model or not self.cam_model:
            logger.error("[AcousticDiarization] Models are not ready.")
            return []

        try:
            # 1. Load audio data as 16kHz mono
            audio_data, sr = load_audio_16k_mono(audio_path)
            if len(audio_data) == 0:
                logger.error(f"[AcousticDiarization] Could not read audio from {audio_path}")
                return []

            # 2. Run FSMN-VAD
            vad_res = self.vad_model.generate(input=audio_path)
            raw_segments = []
            if isinstance(vad_res, list) and len(vad_res) > 0:
                item = vad_res[0]
                if isinstance(item, dict) and "value" in item:
                    raw_segments = item["value"]
                elif isinstance(item, (list, tuple)):
                    raw_segments = item
            elif isinstance(vad_res, dict) and "value" in vad_res:
                raw_segments = vad_res["value"]

            if not raw_segments:
                logger.info("[AcousticDiarization] VAD detected no segments; using full audio segment.")
                raw_segments = [[0, len(audio_data) / sr * 1000]]

            voiceprint_segments = []

            for seg in raw_segments:
                if len(seg) < 2:
                    continue
                start_sec = float(seg[0]) / 1000.0 if seg[0] > 100 else float(seg[0])
                end_sec = float(seg[1]) / 1000.0 if seg[1] > 100 else float(seg[1])
                duration = end_sec - start_sec

                if duration < 0.4:
                    # Ignore tiny sub-half-second clicks or noise bursts
                    continue

                start_idx = int(start_sec * sr)
                end_idx = min(len(audio_data), int(end_sec * sr))
                chunk_wave = audio_data[start_idx:end_idx]

                if len(chunk_wave) < int(0.3 * sr):
                    continue

                try:
                    cam_out = self.cam_model.generate(input=chunk_wave, fs=sr)
                    # cam_out format in FunASR: [{'spk_embedding': tensor/ndarray}]
                    emb = None
                    if isinstance(cam_out, list) and len(cam_out) > 0:
                        elem = cam_out[0]
                        if isinstance(elem, dict):
                            emb = elem.get("spk_embedding", elem.get("embedding"))
                        elif isinstance(elem, (np.ndarray, torch.Tensor)):
                            emb = elem
                    elif isinstance(cam_out, dict):
                        emb = cam_out.get("spk_embedding", cam_out.get("embedding"))

                    if emb is not None:
                        if isinstance(emb, torch.Tensor):
                            emb = emb.detach().cpu().numpy()
                        emb = np.squeeze(emb)
                        if emb.ndim == 1:
                            # Normalize embedding
                            norm = np.linalg.norm(emb)
                            if norm > 0:
                                emb = emb / norm
                            voiceprint_segments.append({
                                "start": start_sec,
                                "end": end_sec,
                                "embedding": emb
                            })
                except Exception as cam_chunk_err:
                    logger.debug(f"CAM++ chunk embedding error: {cam_chunk_err}")

            logger.info(f"[AcousticDiarization] Extracted {len(voiceprint_segments)} voiceprint segments.")
            return voiceprint_segments

        except Exception as e:
            logger.error(f"[AcousticDiarization] Voiceprint extraction error: {e}", exc_info=True)
            return []

    def cluster_speakers(self, voiceprint_segments: List[Dict], num_speakers: Optional[int] = None) -> List[Dict]:
        """
        Cluster voiceprint embeddings into distinct speaker labels (Speaker 1, Speaker 2, ...)
        """
        if not voiceprint_segments:
            return []

        if len(voiceprint_segments) == 1:
            voiceprint_segments[0]["speaker"] = "Speaker 1"
            return voiceprint_segments

        embeddings = np.array([s["embedding"] for s in voiceprint_segments])

        try:
            from sklearn.cluster import AgglomerativeClustering

            if num_speakers is not None and num_speakers > 0:
                n_clusters = min(num_speakers, len(voiceprint_segments))
                clusterer = AgglomerativeClustering(
                    n_clusters=n_clusters,
                    metric="cosine",
                    linkage="average"
                )
                labels = clusterer.fit_predict(embeddings)
            else:
                # Auto-determine number of clusters using distance threshold
                clusterer = AgglomerativeClustering(
                    n_clusters=None,
                    distance_threshold=0.68,
                    metric="cosine",
                    linkage="average"
                )
                labels = clusterer.fit_predict(embeddings)

            # Map cluster IDs to Speaker 1, Speaker 2... in order of first appearance
            speaker_map = {}
            speaker_count = 1
            for idx, label in enumerate(labels):
                if label not in speaker_map:
                    speaker_map[label] = f"Speaker {speaker_count}"
                    speaker_count += 1
                voiceprint_segments[idx]["speaker"] = speaker_map[label]

            return voiceprint_segments

        except Exception as cluster_err:
            logger.error(f"[AcousticDiarization] Clustering error: {cluster_err}", exc_info=True)
            for seg in voiceprint_segments:
                seg["speaker"] = "Speaker 1"
            return voiceprint_segments

    def diarize_and_align_whisper_chunks(
        self,
        audio_path: str,
        whisper_chunks: List[Dict],
        num_speakers: Optional[int] = None
    ) -> Tuple[str, List[Dict]]:
        """
        Extracts CAM++ 192D acoustic voiceprints directly for every Whisper sentence/chunk on GPU
        and clusters them into distinct speakers without mixing up any words or sentences.
        """
        if not whisper_chunks or not audio_path or not os.path.exists(audio_path):
            return "", []

        self._init_models()
        if not self.cam_model:
            logger.error("[AcousticDiarization] CAM++ model not ready.")
            return "", []

        # 1. Load 16kHz mono audio into memory
        audio_data, sr = load_audio_16k_mono(audio_path)
        if len(audio_data) == 0:
            return "", []

        total_audio_sec = len(audio_data) / sr

        # 2. Extract CAM++ embedding directly for each Whisper sentence
        chunk_embeddings = []
        valid_chunk_indices = []

        for idx, chunk in enumerate(whisper_chunks):
            chunk_text = chunk.get("text", "").strip()
            if not chunk_text:
                continue

            ts = chunk.get("timestamp", [0.0, 0.0]) or [0.0, 0.0]
            start_sec = max(0.0, float(ts[0]) if ts[0] is not None else 0.0)
            end_sec = min(total_audio_sec, float(ts[1]) if len(ts) > 1 and ts[1] is not None else start_sec + 2.0)

            # Extract window with 0.1s context buffer
            s_idx = max(0, int((start_sec - 0.1) * sr))
            e_idx = min(len(audio_data), int((end_sec + 0.1) * sr))
            chunk_wave = audio_data[s_idx:e_idx]

            # Minimum duration padding (0.5s) if chunk is very short
            if len(chunk_wave) < int(0.5 * sr):
                pad_len = int(0.5 * sr) - len(chunk_wave)
                chunk_wave = np.pad(chunk_wave, (0, pad_len))

            try:
                cam_out = self.cam_model.generate(input=chunk_wave, fs=sr)
                emb = None
                if isinstance(cam_out, list) and len(cam_out) > 0:
                    elem = cam_out[0]
                    if isinstance(elem, dict):
                        emb = elem.get("spk_embedding", elem.get("embedding"))
                    elif isinstance(elem, (np.ndarray, torch.Tensor)):
                        emb = elem
                elif isinstance(cam_out, dict):
                    emb = cam_out.get("spk_embedding", cam_out.get("embedding"))

                if emb is not None:
                    if isinstance(emb, torch.Tensor):
                        emb = emb.detach().cpu().numpy()
                    emb = np.squeeze(emb)
                    if emb.ndim == 1:
                        norm = np.linalg.norm(emb)
                        if norm > 0:
                            emb = emb / norm
                        chunk_embeddings.append(emb)
                        valid_chunk_indices.append(idx)
            except Exception as e:
                logger.debug(f"Chunk embedding extraction error: {e}")

        if not chunk_embeddings:
            portions = []
            for chunk in whisper_chunks:
                text = chunk.get("text", "").strip()
                if not text:
                    continue
                ts = chunk.get("timestamp", [0.0, 0.0]) or [0.0, 0.0]
                t_str = format_seconds_to_timestamp(ts[0] if ts[0] is not None else 0.0)
                portions.append({"time": t_str, "speaker": "Speaker 1", "content": text})
            formatted = "\n\n".join([f"[{p['time']}] {p['speaker']}: {p['content']}" for p in portions])
            return formatted, portions

        # 3. Cluster the sentence embeddings into distinct speakers
        emb_matrix = np.array(chunk_embeddings)
        n_samples = len(emb_matrix)

        if n_samples == 1:
            cluster_labels = [0]
        else:
            from sklearn.cluster import AgglomerativeClustering
            from sklearn.metrics import silhouette_score
            try:
                if num_speakers is not None and num_speakers > 0:
                    n_clusters = min(num_speakers, n_samples)
                    clusterer = AgglomerativeClustering(
                        n_clusters=n_clusters,
                        metric="cosine",
                        linkage="average"
                    )
                    cluster_labels = clusterer.fit_predict(emb_matrix)
                else:
                    dist_matrix = 1.0 - np.dot(emb_matrix, emb_matrix.T)
                    max_dist = float(np.max(dist_matrix))

                    if max_dist < 0.25 or n_samples < 2:
                        cluster_labels = [0] * n_samples
                    else:
                        best_k = 2
                        best_score = -1.0
                        max_k = min(5, n_samples - 1)
                        for k in range(2, max_k + 1):
                            test_clusterer = AgglomerativeClustering(
                                n_clusters=k,
                                metric="cosine",
                                linkage="average"
                            )
                            test_labels = test_clusterer.fit_predict(emb_matrix)
                            if len(set(test_labels)) > 1:
                                try:
                                    score = silhouette_score(emb_matrix, test_labels, metric="cosine")
                                    if score > best_score:
                                        best_score = score
                                        best_k = k
                                except Exception:
                                    pass

                        clusterer = AgglomerativeClustering(
                            n_clusters=best_k,
                            metric="cosine",
                            linkage="average"
                        )
                        cluster_labels = clusterer.fit_predict(emb_matrix)
            except Exception as e:
                logger.error(f"Clustering error: {e}")
                cluster_labels = [0] * n_samples

        # Map cluster IDs to Speaker 1, Speaker 2... in order of first appearance
        label_to_spk_map = {}
        speaker_counter = 1
        for label in cluster_labels:
            if label not in label_to_spk_map:
                label_to_spk_map[label] = f"Speaker {speaker_counter}"
                speaker_counter += 1

        # 4. Construct clean portions and formatted transcript
        portions = []
        for i, chunk_idx in enumerate(valid_chunk_indices):
            chunk = whisper_chunks[chunk_idx]
            chunk_text = chunk.get("text", "").strip()
            ts = chunk.get("timestamp", [0.0, 0.0]) or [0.0, 0.0]
            start_sec = float(ts[0]) if ts[0] is not None else 0.0
            time_str = format_seconds_to_timestamp(start_sec)
            assigned_speaker = label_to_spk_map[cluster_labels[i]]

            portions.append({
                "time": time_str,
                "speaker": assigned_speaker,
                "content": chunk_text
            })

        formatted_lines = [
            f"[{p['time']}] {p['speaker']}: {p['content']}"
            for p in portions
        ]
        formatted_text = "\n\n".join(formatted_lines)

        return formatted_text, portions

    def diarize_existing_portions(
        self,
        audio_path: str,
        portions: List[Dict],
        num_speakers: Optional[int] = None
    ) -> Tuple[str, List[Dict]]:
        """
        Updates ONLY the speaker attribute of existing portions based on CAM++ acoustic voiceprints on GPU.
        The text content, timestamps, and order of portions remain 100% untouched.
        """
        if not portions or not audio_path or not os.path.exists(audio_path):
            return "", portions or []

        self._init_models()
        if not self.cam_model:
            logger.error("[AcousticDiarization] CAM++ model not ready.")
            return "", portions

        # Load audio data
        audio_data, sr = load_audio_16k_mono(audio_path)
        if len(audio_data) == 0:
            return "", portions

        total_audio_sec = len(audio_data) / sr

        # Parse timestamps for each portion
        timestamps = []
        for p in portions:
            time_str = p.get("time", "00:00").replace("[", "").replace("]", "").strip()
            parts = time_str.split(":")
            sec = 0.0
            if len(parts) == 2:
                try: sec = int(parts[0]) * 60 + float(parts[1])
                except: sec = 0.0
            elif len(parts) == 3:
                try: sec = int(parts[0]) * 3600 + int(parts[1]) * 60 + float(parts[2])
                except: sec = 0.0
            timestamps.append(sec)

        embeddings = []
        for i, p in enumerate(portions):
            start_sec = timestamps[i]
            if i + 1 < len(portions):
                end_sec = max(start_sec + 0.8, timestamps[i + 1])
            else:
                end_sec = min(total_audio_sec, start_sec + 5.0)

            s_idx = max(0, int(start_sec * sr))
            e_idx = min(len(audio_data), int(end_sec * sr))
            chunk_wave = audio_data[s_idx:e_idx]

            if len(chunk_wave) < int(0.5 * sr):
                pad_len = int(0.5 * sr) - len(chunk_wave)
                chunk_wave = np.pad(chunk_wave, (0, pad_len))

            try:
                cam_out = self.cam_model.generate(input=chunk_wave, fs=sr)
                emb = None
                if isinstance(cam_out, list) and len(cam_out) > 0:
                    elem = cam_out[0]
                    if isinstance(elem, dict):
                        emb = elem.get("spk_embedding", elem.get("embedding"))
                    elif isinstance(elem, (np.ndarray, torch.Tensor)):
                        emb = elem
                elif isinstance(cam_out, dict):
                    emb = cam_out.get("spk_embedding", cam_out.get("embedding"))

                if emb is not None:
                    if isinstance(emb, torch.Tensor):
                        emb = emb.detach().cpu().numpy()
                    emb = np.squeeze(emb)
                    if emb.ndim == 1:
                        norm = np.linalg.norm(emb)
                        if norm > 0:
                            emb = emb / norm
                        embeddings.append(emb)
                    else:
                        embeddings.append(np.zeros(192))
                else:
                    embeddings.append(np.zeros(192))
            except Exception as e:
                logger.debug(f"Portion embedding extraction error: {e}")
                embeddings.append(np.zeros(192))

        # Cluster embeddings
        emb_matrix = np.array(embeddings)
        n_samples = len(emb_matrix)

        if n_samples == 1:
            cluster_labels = [0]
        else:
            from sklearn.cluster import AgglomerativeClustering
            from sklearn.metrics import silhouette_score
            try:
                if num_speakers is not None and num_speakers > 0:
                    n_clusters = min(num_speakers, n_samples)
                    clusterer = AgglomerativeClustering(
                        n_clusters=n_clusters,
                        metric="cosine",
                        linkage="average"
                    )
                    cluster_labels = clusterer.fit_predict(emb_matrix)
                else:
                    dist_matrix = 1.0 - np.dot(emb_matrix, emb_matrix.T)
                    max_dist = float(np.max(dist_matrix))

                    if max_dist < 0.25 or n_samples < 2:
                        cluster_labels = [0] * n_samples
                    else:
                        best_k = 2
                        best_score = -1.0
                        max_k = min(5, n_samples - 1)
                        for k in range(2, max_k + 1):
                            test_clusterer = AgglomerativeClustering(
                                n_clusters=k,
                                metric="cosine",
                                linkage="average"
                            )
                            test_labels = test_clusterer.fit_predict(emb_matrix)
                            if len(set(test_labels)) > 1:
                                try:
                                    score = silhouette_score(emb_matrix, test_labels, metric="cosine")
                                    if score > best_score:
                                        best_score = score
                                        best_k = k
                                except Exception:
                                    pass

                        clusterer = AgglomerativeClustering(
                            n_clusters=best_k,
                            metric="cosine",
                            linkage="average"
                        )
                        cluster_labels = clusterer.fit_predict(emb_matrix)
            except Exception as e:
                logger.error(f"Clustering error: {e}")
                cluster_labels = [0] * n_samples

        # Map cluster labels to Speaker 1, Speaker 2... in order of first appearance
        label_to_spk_map = {}
        speaker_counter = 1
        for label in cluster_labels:
            if label not in label_to_spk_map:
                label_to_spk_map[label] = f"Speaker {speaker_counter}"
                speaker_counter += 1

        # Update speaker field on portions without changing any text or timestamps
        for i, p in enumerate(portions):
            p["speaker"] = label_to_spk_map[cluster_labels[i]]

        formatted_lines = [
            f"[{p['time']}] {p['speaker']}: {p['content']}"
            for p in portions
        ]
        formatted_text = "\n\n".join(formatted_lines)

        return formatted_text, portions


# Global singleton instance
acoustic_diarization_service = AcousticDiarizationService()
