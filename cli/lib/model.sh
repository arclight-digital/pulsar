# shellcheck shell=bash
# Part of pulsar (cli/pulsar reads it): pulsar agent model: a local model server.

# ---------------------------------------------------------------------------
# agent model -- a local model server, for an agent with no cloud account.
#
# llama.cpp's own server image, as a rootless podman quadlet: an
# OpenAI-compatible API on 127.0.0.1 only, the model fetched from Hugging Face
# by llama.cpp itself into ~/.local/share/pulsar/models. The image matches
# the hardware: CUDA on the nvidia image (the GPU through CDI), Vulkan where
# there is a /dev/dri, plain CPU otherwise.
#
# NOT started at login unless asked (--at-login): a loaded model holds
# gigabytes of VRAM, and this is also the machine the games run on.
#
# opencode and aider are the agents that take any provider. opencode gets a
# "Local (Pulsar)" provider added next to whatever it has, never replacing
# its default; aider gets the line to run. Nothing is installed on the host.
# ---------------------------------------------------------------------------
MODEL_UNIT_DIR=${PULSAR_QUADLET_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd}
MODEL_DIR=${PULSAR_MODEL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/pulsar/models}
MODEL_PORT=${PULSAR_MODEL_PORT:-8080}
MODEL_DEFAULT=${PULSAR_MODEL_DEFAULT:-bartowski/Qwen2.5-Coder-7B-Instruct-GGUF}
MODEL_UNIT=pulsar-model
# The server's key. llama.cpp's defaults are no key and CORS open to every
# origin, so any web page in the browser could have used the model on
# 127.0.0.1. With a key it cannot, and CORS names only the server itself.
MODEL_KEY=${PULSAR_MODEL_KEY:-${XDG_CONFIG_HOME:-$HOME/.config}/pulsar/model-key}

model_key() {
    if [ ! -s "$MODEL_KEY" ]; then
        mkdir -p "$(dirname "$MODEL_KEY")"
        ( umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$MODEL_KEY" )
    fi
    cat "$MODEL_KEY"
}

# cuda | vulkan | cpu, for this machine
model_backend() {
    case "$(mf variant)" in
        *nvidia*) printf 'cuda\n'; return ;;
    esac
    if [ -e "${PULSAR_DRI:-/dev/dri}" ]; then printf 'vulkan\n'; else printf 'cpu\n'; fi
}

model_quadlet() {
    local model=$1 backend=$2 at_login=$3 image device=""
    case "$backend" in
        cuda)   image=ghcr.io/ggml-org/llama.cpp:server-cuda;   device="AddDevice=nvidia.com/gpu=all" ;;
        vulkan) image=ghcr.io/ggml-org/llama.cpp:server-vulkan; device="AddDevice=/dev/dri" ;;
        *)      image=ghcr.io/ggml-org/llama.cpp:server ;;
    esac
    cat <<EOF
# Written by \`pulsar agent model on\`; \`pulsar agent model off\` removes it.
# llama.cpp's server on 127.0.0.1:${MODEL_PORT} (OpenAI-compatible), ${backend}.
[Unit]
Description=Local model server for coding agents (${model})
After=network-online.target

[Container]
Image=${image}
${device}
PublishPort=127.0.0.1:${MODEL_PORT}:8080
Volume=${MODEL_DIR}:/models:Z
Volume=${MODEL_KEY}:/run/model-key:ro,Z
Environment=LLAMA_CACHE=/models
# --jinja: the model's own chat template, which is what makes tool calls work.
# The key, and CORS for the server's own origin only: see MODEL_KEY.
Exec=--host 0.0.0.0 --port 8080 -hf ${model} --jinja -ngl 999 -c 32768 --api-key-file /run/model-key --cors-origins http://127.0.0.1:${MODEL_PORT}
AutoUpdate=registry

[Service]
# the first start pulls the image and downloads the model
TimeoutStartSec=1800
Restart=on-failure
EOF
    if [ "$at_login" = 1 ]; then
        printf '\n[Install]\nWantedBy=default.target\n'
    fi
}

# The provider opencode shows as "Local (Pulsar)", next to its others.
model_opencode() {
    local action=$1 model=$2 f tmp id
    f="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json"
    [ -d "$(dirname "$f")" ] || return 0
    have jq || return 0
    [ -s "$f" ] || printf '{}\n' > "$f"
    jq -e . "$f" >/dev/null 2>&1 || { printf '%s is not JSON; add the local provider yourself\n' "$f"; return 0; }
    tmp=$(mktemp "${f}.XXXXXX")
    if [ "$action" = add ]; then
        id=$(basename "$model")
        jq --arg url "http://127.0.0.1:${MODEL_PORT}/v1" --arg id "$id" --arg key "$(model_key)" \
            '.provider["pulsar-local"] = {npm: "@ai-sdk/openai-compatible", name: "Local (Pulsar)",
               options: {baseURL: $url, apiKey: $key}, models: {($id): {name: $id, tool_call: true}}}' "$f" > "$tmp"
        printf 'opencode: added the "Local (Pulsar)" provider (pick it with /models)\n'
    else
        jq 'del(.provider["pulsar-local"]) | if .provider == {} then del(.provider) else . end' "$f" > "$tmp"
    fi
    chmod --reference="$f" "$tmp" && mv "$tmp" "$f"
}

agent_model() {
    local sub=${1:-} model="" at_login=0 purge=0 a
    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --model) [ $# -ge 2 ] || die "--model wants a Hugging Face repo[:quant]"; model=$2; shift ;;
            --model=*) model=${1#--model=} ;;
            --at-login) at_login=1 ;;
            --purge) purge=1 ;;
            *) die "unknown option: $1 (see: pulsar agent --help)" ;;
        esac
        shift
    done
    local unit="${MODEL_UNIT_DIR}/${MODEL_UNIT}.container"
    case "$sub" in
        ""|status)
            if [ ! -f "$unit" ]; then
                printf 'model    off  (pulsar agent model on [--model <hf-repo[:quant]>])\n'
                return 0
            fi
            local state m
            state=$(systemctl --user is-active "${MODEL_UNIT}.service" 2>/dev/null) || true
            m=$(sed -n 's/^Exec=.* -hf \([^ ]*\) .*/\1/p' "$unit")
            printf 'model    %s  %s\n' "${state:-inactive}" "$m"
            printf 'endpoint http://127.0.0.1:%s/v1  (OpenAI-compatible)\n' "$MODEL_PORT"
            printf 'key      %s  (every request needs it)\n' "$MODEL_KEY"
            # shellcheck disable=SC2016  # the $(cat) is for the user to run
            printf 'aider    aider --openai-api-base http://127.0.0.1:%s/v1 --openai-api-key "$(cat %s)" --model openai/%s\n' \
                "$MODEL_PORT" "$MODEL_KEY" "$(basename "${m%%:*}")"
            ;;
        on)
            need podman
            [ -n "$model" ] || model=$MODEL_DEFAULT
            case "$model" in
                */*) ;;
                *) die "--model wants a Hugging Face repo, owner/name[:quant] (got: ${model})" ;;
            esac
            case "$model" in *[!A-Za-z0-9._:/-]*) die "not a model reference: ${model}" ;; esac
            local backend; backend=$(model_backend)
            mkdir -p "$MODEL_UNIT_DIR" "$MODEL_DIR"
            model_key >/dev/null
            model_quadlet "$model" "$backend" "$at_login" > "$unit"
            systemctl --user daemon-reload
            printf 'starting %s (%s); the first start downloads the image and the model\n' "$model" "$backend"
            systemctl --user restart "${MODEL_UNIT}.service" \
                || die "the model server did not start: journalctl --user -u ${MODEL_UNIT}"
            model_opencode add "$model"
            printf 'endpoint http://127.0.0.1:%s/v1  (OpenAI-compatible)\n' "$MODEL_PORT"
            printf 'key      %s  (every request needs it)\n' "$MODEL_KEY"
            # shellcheck disable=SC2016  # the $(cat) is for the user to run
            printf 'aider    aider --openai-api-base http://127.0.0.1:%s/v1 --openai-api-key "$(cat %s)" --model openai/%s\n' \
                "$MODEL_PORT" "$MODEL_KEY" "$(basename "${model%%:*}")"
            [ "$at_login" = 1 ] || printf 'to start it at each login: pulsar agent model on --at-login\n'
            ;;
        off)
            if [ -f "$unit" ]; then
                systemctl --user stop "${MODEL_UNIT}.service" 2>/dev/null || true
                rm -f "$unit"
                systemctl --user daemon-reload
                printf 'stopped and removed the local model server\n'
            else
                printf 'the local model server is not set up\n'
            fi
            model_opencode remove ""
            if [ "$purge" = 1 ]; then
                rm -rf "${MODEL_DIR:?}"
                printf 'deleted the downloaded models in %s\n' "$MODEL_DIR"
            elif [ -d "$MODEL_DIR" ]; then
                printf 'the downloaded models stay in %s (%s); --purge deletes them\n' \
                    "$MODEL_DIR" "$(du -sh "$MODEL_DIR" 2>/dev/null | cut -f1)"
            fi
            ;;
        *) die "unknown model command: ${sub} (see: pulsar agent --help)" ;;
    esac
}
