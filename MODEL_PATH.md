# Shared Parakeet Model

EchoNote should reuse the model already downloaded for Lecture Transcriber. Do not reinstall or download another copy.

- **Lecture Transcriber project:** `C:\Users\ellih\Desktop\Personal\University Work Y1\Lecture Transcriber`
- **Current shared model storage root:** `C:\LectureTranscriberModel\SharedParakeet`
- **Model:** `nvidia/parakeet-tdt-0.6b-v2` (NVIDIA Parakeet TDT 0.6B v2)
- **Existing runtime pointer:** `D:\LectureTranscriber`
- **Storage setup:** `storage.py` reads `model_storage_path.txt`, prepares `huggingface`, `torch`, `nemo`, and `cache` directories, and sets the corresponding cache environment variables before importing NeMo.
- **Shared path rule:** Lecture Transcriber uses `model_storage_path.txt`; EchoNote now reads that same pointer and derives the Hugging Face cache path from it. Repointing the Lecture Transcriber pointer will therefore repoint both programs.

**Cache verification (2026-11-05): verified and used.** The old cache at `C:\LectureTranscriberModel` had a broken symbolic-link chain and was left untouched after automatic policy blocked deleting it. A clean copy of the official `nvidia/parakeet-tdt-0.6b-v2` artifact was downloaded to the current shared root above. Its size is 2,472,222,720 bytes and its SHA-256 is `d99e39955c9d3d0350d8fb7c75e40c64a2b2eaeb003883d7c941fd2e8747b28c`, matching the repository metadata. Lecture Transcriber's `model_storage_path.txt` now points to this shared root, and EchoNote reads that pointer. EchoNote loaded the local snapshot with NeMo `restore_from` on the RTX 5060 (8 GB, bfloat16). An end-to-end WebSocket test sent 4.9 seconds of synthesized speech in 100 ms PCM frames and received two ordered transcript segments plus `final: complete`; recognized text was “Echon Note server test, the quick brown fox jumps over the lazy dog.” No model weights were downloaded during server startup or inference.
