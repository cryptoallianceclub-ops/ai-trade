#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

INSTALL_DIR="${INSTALL_DIR:-/opt/crypto-alliance-ai-trade}"
IMAGE_REPO="${IMAGE_REPO:-ghcr.io/cryptoallianceclub-ops/crypto-alliance-ai-trade}"
PROJECT_NAME="crypto-alliance"
COMPOSE_FILE="${INSTALL_DIR}/data/runtime/docker-compose.prod.yml"
DATA_DIR="${INSTALL_DIR}/data"
LOGS_DIR="${INSTALL_DIR}/logs"
RELEASE_STATE_FILE="${DATA_DIR}/release-state.json"

ACTION="${1:-install}"
if [[ $# -gt 0 ]]; then
  shift
fi

TARGET_VERSION=""
NO_PULL=0
SKIP_BACKUP=0
SERVICE_NAME=""
COMPOSE_APP_VERSION_OVERRIDE=""

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() {
  printf "${GREEN}[%s] %s${NC}\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
  printf "${YELLOW}[%s] %s${NC}\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

err() {
  printf "${RED}[%s] %s${NC}\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "缺少命令: $1"
    exit 1
  fi
}

print_help() {
  cat <<'USAGE'
用法:
  ./install.sh install [--version vX.Y.Z|latest] [--no-pull]
  ./install.sh update  [--version vX.Y.Z|latest] [--no-pull] [--skip-backup]
  ./install.sh status
  ./install.sh logs [service]

参数:
  --version <ver>       指定目标版本（例如 v1.2.3 或 latest）
  --no-pull             跳过 docker compose pull
  --skip-backup         跳过数据库备份（默认会备份 data/*.db*）
USAGE
}

install_docker_if_needed() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker 已安装"
    return
  fi

  warn "未检测到 Docker，开始自动安装..."
  need_cmd curl
  curl -fsSL https://get.docker.com | sh

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker || true
  fi

  if ! command -v docker >/dev/null 2>&1; then
    err "Docker 安装失败，请手动安装后重试"
    exit 1
  fi
  log "Docker 安装完成"
}

install_jq_if_needed() {
  if command -v jq >/dev/null 2>&1; then
    log "jq 已安装"
    return
  fi

  warn "未检测到 jq，开始自动安装..."

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update && apt-get install -y jq
  elif command -v yum >/dev/null 2>&1; then
    yum install -y jq
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y jq
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache jq
  else
    err "无法自动安装 jq，请先手动安装 jq 再重试"
    exit 1
  fi

  log "jq 安装完成"
}

json_get() {
  local file="$1"
  local expr="$2"
  jq -r "$expr // empty" "$file"
}

normalize_version() {
  local v="$1"
  if [[ -z "$v" ]]; then
    echo ""
    return
  fi
  if [[ "${v,,}" == "latest" ]]; then
    echo "latest"
    return
  fi
  if [[ "$v" == v* ]]; then
    echo "$v"
  else
    echo "v$v"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        TARGET_VERSION="${2:-}"
        shift 2
        ;;
      --no-pull)
        NO_PULL=1
        shift
        ;;
      --skip-backup)
        SKIP_BACKUP=1
        shift
        ;;
      --help|-h)
        print_help
        exit 0
        ;;
      *)
        if [[ "$ACTION" == "logs" && -z "$SERVICE_NAME" ]]; then
          SERVICE_NAME="$1"
          shift
        else
          err "未知参数: $1"
          print_help
          exit 1
        fi
        ;;
    esac
  done
}

ensure_runtime_layout() {
  log "准备安装目录: ${INSTALL_DIR}"
  mkdir -p "${INSTALL_DIR}" "${DATA_DIR}" "${LOGS_DIR}"
}

is_valid_ipv4() {
  local ip="$1"
  local IFS='.'
  local -a octets=()
  local octet=""

  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  read -r -a octets <<< "$ip"
  [[ "${#octets[@]}" -eq 4 ]] || return 1

  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    ((10#$octet <= 255)) || return 1
  done

  return 0
}

detect_public_ip() {
  local ip_candidate=""
  local service=""
  local -a services=(
    "https://api.ipify.org"
    "https://ifconfig.me/ip"
    "https://icanhazip.com"
  )

  for service in "${services[@]}"; do
    ip_candidate="$(curl -4fsS --max-time 3 "$service" 2>/dev/null | tr -d '\r\n' || true)"
    if is_valid_ipv4 "$ip_candidate"; then
      echo "$ip_candidate"
      return 0
    fi
  done

  return 1
}

persist_self_script() {
  local self_path=""
  if [[ -f "${BASH_SOURCE[0]}" ]]; then
    self_path="${BASH_SOURCE[0]}"
  fi
  if [[ -n "$self_path" ]]; then
    cp -f "$self_path" "${INSTALL_DIR}/install.sh" || true
    chmod +x "${INSTALL_DIR}/install.sh" || true
  fi
}

write_compose_file() {
  mkdir -p "$(dirname "$COMPOSE_FILE")"
  cat > "$COMPOSE_FILE" <<EOF
name: ${PROJECT_NAME}

services:
  web:
    image: ${IMAGE_REPO}:\${APP_VERSION:-latest}
    restart: unless-stopped
    ports:
      - "3000:3000"
    volumes:
      - ./data:/app/data
      - ./logs:/app/logs
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:3000/login"]
      interval: 30s
      timeout: 10s
      retries: 5

  node-client:
    image: ${IMAGE_REPO}:\${APP_VERSION:-latest}
    restart: unless-stopped
    command: ["node", "--experimental-specifier-resolution=node", "node-client/dist/node-client/src/main.js"]
    volumes:
      - ./data:/app/data
      - ./logs:/app/logs
    depends_on:
      web:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:3100/health"]
      interval: 30s
      timeout: 10s
      retries: 5

  updater:
    image: ${IMAGE_REPO}:\${APP_VERSION:-latest}
    restart: unless-stopped
    command: ["node", "updater/server.mjs"]
    ports:
      - "127.0.0.1:3201:3201"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./:/workspace
      - ./data:/app/data
    depends_on:
      web:
        condition: service_healthy
      node-client:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:3201/health"]
      interval: 30s
      timeout: 10s
      retries: 5
EOF
}

init_release_state_if_needed() {
  if [[ -f "$RELEASE_STATE_FILE" ]]; then
    return
  fi

  local now
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  cat > "$RELEASE_STATE_FILE" <<EOF
{
  "appVersion": "latest",
  "buildCommit": "unknown",
  "buildTime": "unknown",
  "updatedAt": "$now"
}
EOF
  log "已生成版本文件: $RELEASE_STATE_FILE"
}

json_set_release_version() {
  local version="$1"
  local now
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  jq \
    --arg version "$version" \
    --arg now "$now" \
    '.appVersion = $version | .updatedAt = $now' \
    "$RELEASE_STATE_FILE" > "${RELEASE_STATE_FILE}.tmp"
  mv "${RELEASE_STATE_FILE}.tmp" "$RELEASE_STATE_FILE"
}

compose_cmd() {
  local app_version="$COMPOSE_APP_VERSION_OVERRIDE"
  if [[ -z "$app_version" && -f "$RELEASE_STATE_FILE" ]]; then
    app_version="$(json_get "$RELEASE_STATE_FILE" '.appVersion')"
  fi

  if [[ "${app_version,,}" == "latest" ]]; then
    app_version=""
  fi

  if [[ -n "$app_version" ]]; then
    APP_VERSION="$app_version" docker compose \
      --project-name "$PROJECT_NAME" \
      --project-directory "$INSTALL_DIR" \
      -f "$COMPOSE_FILE" "$@"
  else
    docker compose \
      --project-name "$PROJECT_NAME" \
      --project-directory "$INSTALL_DIR" \
      -f "$COMPOSE_FILE" "$@"
  fi
}

backup_databases() {
  if [[ "$SKIP_BACKUP" -eq 1 ]]; then
    log "已跳过数据库备份"
    return
  fi

  local db_files
  db_files=$(find "$DATA_DIR" -maxdepth 1 -type f \( -name '*.db' -o -name '*.db-wal' -o -name '*.db-shm' \) || true)
  if [[ -z "$db_files" ]]; then
    log "未发现数据库文件，跳过备份"
    return
  fi

  local backup_dir
  backup_dir="${DATA_DIR}/backups/manual-$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "$backup_dir"

  while IFS= read -r file; do
    cp "$file" "$backup_dir/"
  done <<< "$db_files"

  log "数据库备份完成: $backup_dir"
}

wait_service_healthy() {
  local service="$1"
  local max_retries=10
  local interval=10

  local container_id
  container_id="$(compose_cmd ps -q "$service")"
  if [[ -z "$container_id" ]]; then
    err "无法获取容器 ID: $service"
    return 1
  fi

  for ((i=1; i<=max_retries; i++)); do
    local status
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id" 2>/dev/null || true)"
    local has_healthcheck
    has_healthcheck="$(docker inspect -f '{{if .State.Health}}1{{else}}0{{end}}' "$container_id" 2>/dev/null || echo 0)"

    if [[ "$has_healthcheck" == "1" && "$status" == "healthy" ]]; then
      log "服务健康: $service ($status)"
      return 0
    fi

    if [[ "$has_healthcheck" == "0" && "$status" == "running" ]]; then
      log "服务健康: $service ($status)"
      return 0
    fi

    sleep "$interval"
  done

  err "服务未就绪: $service"
  dump_service_diagnostics "$service" "$container_id"
  return 1
}

dump_service_diagnostics() {
  local service="$1"
  local container_id="$2"

  if [[ -z "$container_id" ]]; then
    return
  fi

  local state_info
  state_info="$(docker inspect -f '{{.Name}} status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} restarts={{.RestartCount}} exitCode={{.State.ExitCode}} error={{.State.Error}}' "$container_id" 2>/dev/null || true)"
  if [[ -n "$state_info" ]]; then
    err "容器状态($service): $state_info"
  fi

  err "容器最近日志($service, tail=120)："
  docker logs --tail 120 "$container_id" 2>&1 || true
}

ensure_target_version() {
  if [[ -n "$TARGET_VERSION" ]]; then
    TARGET_VERSION="$(normalize_version "$TARGET_VERSION")"
    return
  fi

  TARGET_VERSION="latest"
}

perform_deploy() {
  if [[ "$NO_PULL" -eq 0 ]]; then
    log "拉取镜像..."
    compose_cmd pull web node-client updater
  else
    log "跳过 pull（--no-pull）"
  fi

  log "启动/更新 Web 服务..."
  compose_cmd up -d web
  wait_service_healthy web

  log "启动/更新 Node 服务..."
  compose_cmd up -d node-client
  wait_service_healthy node-client

  log "启动/确认 Updater 服务..."
  compose_cmd up -d --remove-orphans updater
  wait_service_healthy updater

  log "部署完成"
}

show_status() {
  local current_version=""
  if [[ -f "$RELEASE_STATE_FILE" ]]; then
    current_version="$(json_get "$RELEASE_STATE_FILE" '.appVersion')"
  fi
  log "当前版本: ${current_version:-unknown}"
  compose_cmd ps
}

show_logs() {
  if [[ -n "$SERVICE_NAME" ]]; then
    compose_cmd logs -f "$SERVICE_NAME"
  else
    compose_cmd logs -f
  fi
}

main() {
  printf "${GREEN}=== Crypto Alliance AI Trade 一键安装脚本 ===${NC}\n"
  printf "${GREEN}Install Dir: %s${NC}\n" "$INSTALL_DIR"
  printf "${GREEN}Image Repo : %s${NC}\n" "$IMAGE_REPO"

  if [[ "$ACTION" == "--help" || "$ACTION" == "-h" || "$ACTION" == "help" ]]; then
    print_help
    exit 0
  fi

  parse_args "$@"

  need_cmd curl
  install_docker_if_needed
  install_jq_if_needed
  need_cmd docker
  need_cmd jq

  ensure_runtime_layout
  persist_self_script
  write_compose_file
  init_release_state_if_needed

  case "$ACTION" in
    install|update)
      ensure_target_version
      log "目标版本: $TARGET_VERSION"
      COMPOSE_APP_VERSION_OVERRIDE=""
      if [[ "${TARGET_VERSION,,}" != "latest" ]]; then
        COMPOSE_APP_VERSION_OVERRIDE="$TARGET_VERSION"
      fi
      json_set_release_version "$TARGET_VERSION"
      backup_databases
      perform_deploy
      show_status
      ;;
    status)
      show_status
      ;;
    logs)
      show_logs
      ;;
    *)
      err "未知动作: $ACTION"
      print_help
      exit 1
      ;;
  esac

  printf "${GREEN}==============================================${NC}\n"
  printf "${GREEN}✅ 操作完成：%s${NC}\n" "$ACTION"
  printf "${GREEN}安装目录：%s${NC}\n" "$INSTALL_DIR"
  local web_public_ip=""
  if web_public_ip="$(detect_public_ip)"; then
    printf "${GREEN}Web访问地址：http://%s:3000${NC}\n" "$web_public_ip"
  else
    printf "${GREEN}Web访问地址：未获取到公网IP，请手动查询${NC}\n"
  fi
  printf "${GREEN}==============================================${NC}\n"
}

main "$@"
