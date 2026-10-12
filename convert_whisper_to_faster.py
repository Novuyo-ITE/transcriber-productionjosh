import os
import sys
import subprocess
from huggingface_hub import HfApi, login

def convert_and_upload(model_id, target_repo_id=None, quantization="float16", token=None):
    """
    Converts a HuggingFace PyTorch Whisper model to Faster Whisper (CTranslate2) format
    and optionally uploads it to HuggingFace Hub.
    """
    output_dir = "faster_whisper_converted_model"
    print(f"=== Step 1: Converting [{model_id}] to Faster-Whisper (CTranslate2 {quantization}) ===")
    
    cmd = [
        "ct2-transformers-converter",
        "--model", model_id,
        "--output_dir", output_dir,
        "--quantization", quantization,
        "--copy_files", "tokenizer.json", "preprocessor_config.json", "generation_config.json",
        "--force"
    ]
    
    try:
        subprocess.run(cmd, check=True)
        print(f"✓ Conversion complete! Converted files saved in ./{output_dir}/")
    except subprocess.CalledProcessError as e:
        print(f"❌ Conversion failed: {e}")
        return

    if target_repo_id:
        print(f"\n=== Step 2: Uploading converted model to HuggingFace [{target_repo_id}] ===")
        if token:
            login(token=token)
        
        api = HfApi()
        api.create_repo(repo_id=target_repo_id, exist_ok=True)
        api.upload_folder(
            folder_path=output_dir,
            repo_id=target_repo_id,
            repo_type="model"
        )
        print(f"🎉 Successfully uploaded! View your Faster Whisper model at:\nhttps://huggingface.co/{target_repo_id}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python convert_whisper_to_faster.py <HF_SOURCE_MODEL> [YOUR_USERNAME/NEW_REPO_NAME] [HF_TOKEN]")
        print("Example: python convert_whisper_to_faster.py ElizabethMwangi/whisper-large-v3-luganda-nss-v22 myusername/faster-whisper-large-v3-luganda")
    else:
        source_model = sys.argv[1]
        target_repo = sys.argv[2] if len(sys.argv) > 2 else None
        hf_token = sys.argv[3] if len(sys.argv) > 3 else None
        convert_and_upload(source_model, target_repo, quantization="float16", token=hf_token)
