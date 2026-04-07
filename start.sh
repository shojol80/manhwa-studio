#!/bin/bash
set -e

echo "================================================="
echo " Manhwa Studio — Starting services"
echo "================================================="

# ──── 1. Ollama LLM ────
echo "[1/3] Starting Ollama..."
export OLLAMA_HOST=0.0.0.0:11434

# Use workspace models if available, otherwise copy from baked image
if [ ! -d /workspace/ollama/models ] || [ -z "$(ls -A /workspace/ollama/models 2>/dev/null)" ]; then
  echo "  Copying pre-baked Ollama models to /workspace..."
  mkdir -p /workspace/ollama/models
  cp -rn /opt/ollama/models/* /workspace/ollama/models/ 2>/dev/null || true
fi
export OLLAMA_MODELS=/workspace/ollama/models

# Copy ollama binary if not in PATH
which ollama > /dev/null 2>&1 || cp /usr/local/bin/ollama /workspace/ollama/bin/ollama 2>/dev/null || true

nohup ollama serve > /workspace/ollama/serve.log 2>&1 &
sleep 3

# Verify model is available
if ! ollama list 2>/dev/null | grep -q "qwen2.5:3b"; then
  echo "  Pulling qwen2.5:3b..."
  ollama pull qwen2.5:3b
fi
echo "  Ollama ready on port 11434"

# ──── 2. Download AI models if needed ────
echo "[2/3] Checking AI models..."
export HF_TOKEN="${HF_TOKEN:-}"

# Models live on the volume at /workspace/models
# download_models.sh skips existing files
bash /download_models.sh

# ──── 3. Symlink models into ComfyUI ────
echo "[3/3] Starting ComfyUI..."
COMFY="/ComfyUI"
VOL="/workspace/models"

symlink() {
  local src="$1" dst="$2"
  if [ -f "$src" ] && [ ! -e "$dst" ]; then
    mkdir -p "$(dirname "$dst")"
    ln -sf "$src" "$dst"
    echo "  LINK $(basename $dst)"
  fi
}

# FLUX models
symlink "$VOL/unet/flux1-schnell-fp8.safetensors"    "$COMFY/models/unet/flux1-schnell-fp8.safetensors"
symlink "$VOL/clip/t5xxl_fp8_e4m3fn.safetensors"     "$COMFY/models/clip/t5xxl_fp8_e4m3fn.safetensors"
symlink "$VOL/clip/clip_l.safetensors"                "$COMFY/models/clip/clip_l.safetensors"
symlink "$VOL/vae/ae.safetensors"                     "$COMFY/models/vae/ae.safetensors"

# Wan2.2 models
symlink "$VOL/diffusion_models/WanVideo/2_2/wan2.2_ti2v_5B_fp16.safetensors" \
        "$COMFY/models/diffusion_models/WanVideo/2_2/wan2.2_ti2v_5B_fp16.safetensors"
symlink "$VOL/vae/wanvideo/Wan2_2_VAE_bf16.safetensors" \
        "$COMFY/models/vae/wanvideo/Wan2_2_VAE_bf16.safetensors"
symlink "$VOL/text_encoders/umt5-xxl-enc-bf16.safetensors" \
        "$COMFY/models/text_encoders/umt5-xxl-enc-bf16.safetensors"
symlink "$VOL/text_encoders/open-clip-xlm-roberta-large-vit-huge-14_visual_fp16.safetensors" \
        "$COMFY/models/text_encoders/open-clip-xlm-roberta-large-vit-huge-14_visual_fp16.safetensors"

# ──── 4. Nginx reverse proxy ────
echo "[4/4] Starting nginx reverse proxy..."
cat > /etc/nginx/sites-available/default << 'NGINX'
server {
    listen 8188;
    client_max_body_size 500M;

    # ComfyUI
    location / {
        proxy_pass http://127.0.0.1:8190;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 86400;
    }

    # Ollama API
    location /ollama/ {
        rewrite ^/ollama/(.*) /$1 break;
        proxy_pass http://127.0.0.1:11434;
        proxy_set_header Host $host;
        proxy_read_timeout 300;
    }
}
NGINX
service nginx restart 2>/dev/null || nginx

echo "================================================="
echo " All services ready!"
echo "  ComfyUI  → port 8188 (via nginx)"
echo "  Ollama   → port 8188/ollama/ (via nginx)"
echo "  Ollama   → port 11434 (direct)"
echo "================================================="

# Start ComfyUI on 8190 (nginx proxies 8188 → 8190)
cd /ComfyUI
exec python main.py --listen 0.0.0.0 --port 8190 --disable-auto-launch
