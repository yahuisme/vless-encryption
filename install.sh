#!/usr/bin/env bash
# ==============================================================================
# Xray VLESS Encryption 极简一键安装脚本
# 系统支持: Debian 10+ / Ubuntu 20.04+
# 版本: v26.09.11
# ==============================================================================

set -euo pipefail

SCRIPT_VERSION="v26.09.11"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_INSTALL_URL="https://raw.githubusercontent.com/XTLS/Xray-install/e741a4f56d368afbb9e5be3361b40c4552d3710d/install-release.sh"
XRAY_INSTALL_SHA256="7f70c95f6b418da8b4f4883343d602964915e28748993870fd554383afdbe555"
ENCRYPTION_INFO="/root/xray_encryption_info.txt"
REALITY_INFO="/root/xray_reality_info.txt"       # public_key|sni|short_id
SUBSCRIPTION_INFO="/root/xray_vless_link.txt"
AUTH_MODE="mlkem768"
TRAFFIC_MODE="native"
INSTALL_MODE=""
REALITY_SHORT_ID_SET=false
ROLLBACK_DIR=""
INSTALL_ROLLBACK_DIR=""

C_RESET='\033[0m'; C_BOLD='\033[1m'
C_RED='\033[91m'; C_GREEN='\033[92m'; C_YELLOW='\033[93m'
C_BLUE='\033[94m'; C_CYAN='\033[96m'; C_MAGENTA='\033[95m'

color_enabled() {
    local fd="${1:-1}"
    [ -n "${NO_COLOR:-}" ] && return 1
    [ "${TERM:-}" = dumb ] && return 1
    [ "$fd" = 2 ] && [ -t 2 ] && return 0
    [ "$fd" = 1 ] && [ -t 1 ]
}
cecho() {
    local color="$1" message="$2" fd="${3:-1}"
    if color_enabled "$fd"; then
        printf '%b%s%b\n' "$color" "$message" "$C_RESET" >&"$fd"
    else
        printf '%s\n' "$message" >&"$fd"
    fi
}
info() { cecho "$C_YELLOW" "[!] $1" 2; }
success() { cecho "$C_GREEN" "[✔] $1" 2; }
warning() { cecho "$C_YELLOW" "[⚠] $1" 2; }
error() {
    cecho "$C_RED" "[✖] $1" 2
    # xray-dual 同款：根据错误内容给出简单建议
    case "$1" in
        *"网络"*|*"下载"*) cecho "$C_YELLOW" "提示: 检查网络连接或更换DNS" 2 ;;
        *"权限"*|*"root"*) cecho "$C_YELLOW" "提示: 请使用 sudo 运行脚本" 2 ;;
        *"端口"*) cecho "$C_YELLOW" "提示: 尝试使用其他端口号" 2 ;;
    esac
}
section_title() { cecho "$C_MAGENTA$C_BOLD" "◆ $1" 1; }

require_root_and_dependencies() {
    [ "$(id -u)" = 0 ] || { error "必须以 root 用户运行此脚本。"; exit 1; }
    local pm=""
    if command -v apt-get >/dev/null 2>&1; then pm=apt
    elif command -v dnf >/dev/null 2>&1; then pm=dnf
    elif command -v yum >/dev/null 2>&1; then pm=yum
    else error "仅支持 apt、dnf 或 yum 系统。"; exit 1; fi
    if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v sha256sum >/dev/null 2>&1; then
        info "正在安装缺失依赖（curl、jq、coreutils）..."
        case "$pm" in
            apt) apt-get -o DPkg::Lock::Timeout=600 update && apt-get -o DPkg::Lock::Timeout=600 install -y curl jq coreutils ;;
            dnf|yum) "$pm" install -y curl jq coreutils ;;
        esac
    fi
    if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v sha256sum >/dev/null 2>&1; then
        error "依赖安装失败，请手动安装 curl、jq、coreutils 后重试。"
        exit 1
    fi
}

# 端口占用预检查（无 ss 且无 netstat 时跳过，由 restart 失败兜底）
port_in_use() {
    local port=$1 port_in_use=false
    if command -v ss >/dev/null 2>&1; then
        if ss -H -ltn "sport = :$port" 2>/dev/null | grep -q . || \
           ss -H -lun "sport = :$port" 2>/dev/null | grep -q .; then
            port_in_use=true
        fi
    fi
    # ss 不可用或版本过旧（iproute2 < 4.9 无 -H，调用失败）时回退 netstat，避免静默跳过检查
    if [ "$port_in_use" = false ] && command -v netstat >/dev/null 2>&1; then
        if netstat -tuln 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" || $4 ~ p" " {found=1} END {exit !found}'; then
            port_in_use=true
        fi
    fi
    [ "$port_in_use" = true ]
}

# 当前配置端口（用于同端口重装/修改时豁免占用检查）
current_port() {
    [ -f "$XRAY_CONFIG" ] || return 0
    jq -r '.inbounds[0].port // empty' "$XRAY_CONFIG" 2>/dev/null || true
}

valid_port() { [ "${#1}" -le 5 ] && [[ "$1" =~ ^([1-9][0-9]*|0)$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
valid_sni() {
    local label
    local -a sni_labels
    [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    [ "${#1}" -le 253 ] || return 1
    [[ "$1" != .* && "$1" != *. && "$1" != *..* ]] || return 1
    IFS='.' read -r -a sni_labels <<< "$1"
    for label in "${sni_labels[@]}"; do
        [ "${#label}" -ge 1 ] && [ "${#label}" -le 63 ] || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
    done
    [ "${#sni_labels[@]}" -ge 2 ]
}
valid_short_id() { [[ "$1" =~ ^([0-9A-Fa-f]{2}){1,8}$ ]]; }
valid_uuid() { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
valid_auth() { [ "$1" = mlkem768 ] || [ "$1" = x25519 ]; }
valid_appearance() { [ "$1" = native ] || [ "$1" = xorpub ] || [ "$1" = random ]; }

xray_supports() {
    local output
    [ -x "$XRAY_BIN" ] || return 1
    output=$("$XRAY_BIN" vlessenc 2>/dev/null) || return 1
    grep -q 'Authentication: X25519, not Post-Quantum' <<< "$output" &&
        grep -q 'Authentication: ML-KEM-768, Post-Quantum' <<< "$output"
}
service_account() {
    local user group
    user=$(systemctl show -p User --value xray 2>/dev/null || true)
    group=$(systemctl show -p Group --value xray 2>/dev/null || true)
    for service_file in /etc/systemd/system/xray.service /lib/systemd/system/xray.service /usr/lib/systemd/system/xray.service; do
        [ -f "$service_file" ] || continue
        [ -n "$user" ] || user=$(awk -F= '/^[[:space:]]*User=/{print $2; exit}' "$service_file")
        [ -n "$group" ] || group=$(awk -F= '/^[[:space:]]*Group=/{print $2; exit}' "$service_file")
    done
    user=${user:-root}; group=${group:-$(id -gn "$user")}
    id "$user" >/dev/null 2>&1 && getent group "$group" >/dev/null 2>&1 || return 1
    printf '%s:%s\n' "$user" "$group"
}

run_official_installer() {
    local script_file log_file rc=0
    script_file=$(mktemp)
    log_file=$(mktemp)
    trap 'rm -f -- "${script_file:-}" "${log_file:-}"' RETURN
    if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 120 "$XRAY_INSTALL_URL" > "$script_file"; then
        error "下载官方 Xray 安装脚本失败。"; return 1
    fi
    if ! printf '%s  %s\n' "$XRAY_INSTALL_SHA256" "$script_file" | sha256sum -c --status; then
        error "官方安装脚本校验失败，已拒绝执行。"; return 1
    fi
    # 摘要校验后，仅改写固定源码末尾的停止状态判断；其他 return/exit 原样保留。
    local source_text stopped_tail
    source_text=$(<"$script_file")
    stopped_tail=$'    [[ "$XRAY_RUNNING" -eq \'1\' ]] && start_xray\n  else\n'
    if [[ $source_text != *"$stopped_tail"* || ${source_text#*"$stopped_tail"} == *"$stopped_tail"* ]]; then
        error "官方安装脚本末尾语义不匹配，已拒绝执行。"; return 1
    fi
    printf '%s\n' "${source_text/"$stopped_tail"/$'    if [[ "$XRAY_RUNNING" -eq \'1\' ]]; then start_xray; fi\n  else\n'}" > "$script_file" || return 1
    bash "$script_file" "$@" >"$log_file" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        error "官方 Xray 安装程序执行失败，以下为末尾日志："
        tail -n 30 "$log_file" >&2 || true
        return "$rc"
    fi
}

latest_xray_version() {
    local tag
    tag=$(curl --fail --silent --show-error --location \
        --connect-timeout 10 --max-time 30 \
        -H 'Accept: application/vnd.github+json' \
        -H 'User-Agent: vless-encryption-installer' \
        https://api.github.com/repos/XTLS/Xray-core/releases/latest \
        | jq -r '.tag_name // empty') || return 1
    tag=${tag#v}
    [[ "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || return 1
    printf '%s\n' "$tag"
}

current_xray_version() {
    [ -x "$XRAY_BIN" ] || return 1
    "$XRAY_BIN" version 2>/dev/null | awk 'NR==1 {gsub(/^v/, "", $2); print $2; exit}'
}

extract_vlessenc_value() {
    local output="$1" section="$2" field="$3"
    awk -v section="$section" -v field="$field" '
        $0 == section { inside=1; next }
        inside && /^Authentication:/ { exit }
        inside && $0 ~ ("\\\"" field "\\\":[[:space:]]*\\\"") {
            value=$0; sub(/^[^\"]*\"[^\"]*\":[[:space:]]*\"/, "", value); sub(/\".*$/, "", value); print value; exit
        }
    ' <<< "$output"
}

validate_encryption_token() {
    local token="$1" expected_rtt="$2" prefix mode rtt segment normalized padding bytes valid_key=false
    local -a fields

    IFS='.' read -r -a fields <<< "$token"
    [ "${#fields[@]}" -ge 4 ] || return 1
    prefix=${fields[0]}; mode=${fields[1]}; rtt=${fields[2]}
    [ "$prefix" = mlkem768x25519plus ] && valid_appearance "$mode" && [ "$rtt" = "$expected_rtt" ] || return 1

    # Xray accepts optional short dot-separated padding fields. All segments
    # (padding or key) must be URL-safe Base64 characters; key fields differ
    # by direction/authentication mode.
    for segment in "${fields[@]:3}"; do
        [ -n "$segment" ] || return 1
        [[ "$segment" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
        if [ "${#segment}" -lt 20 ]; then
            continue
        fi
        normalized=$(printf '%s' "$segment" | tr '_-' '/+')
        padding=$(( (4 - ${#normalized} % 4) % 4 ))
        normalized+=$(printf '%*s' "$padding" '' | tr ' ' '=')
        bytes=$(printf '%s' "$normalized" | base64 -d 2>/dev/null | wc -c) || return 1
        if [ "$expected_rtt" = 600s ]; then
            [[ "$bytes" = 32 || "$bytes" = 64 ]] || return 1
        else
            [[ "$bytes" = 32 || "$bytes" = 1184 ]] || return 1
        fi
        valid_key=true
    done
    [ "$valid_key" = true ]
}

generate_encryption_pair() {
    local out section decryption encryption
    out=$("$XRAY_BIN" vlessenc 2>/dev/null) || true
    [ -n "$out" ] || { error "生成 VLESS Encryption 配置失败。"; return 1; }
    if [ "$AUTH_MODE" = mlkem768 ]; then section="Authentication: ML-KEM-768, Post-Quantum"; else section="Authentication: X25519, not Post-Quantum"; fi
    decryption=$(extract_vlessenc_value "$out" "$section" decryption)
    encryption=$(extract_vlessenc_value "$out" "$section" encryption)
    if ! validate_encryption_token "$decryption" 600s ||
       ! validate_encryption_token "$encryption" 0rtt; then
        error "无法解析或校验 Xray 生成的 VLESS Encryption 密钥串。"
        return 1
    fi
    decryption=$(awk -F. -v m="$TRAFFIC_MODE" 'BEGIN{OFS="."}{$2=m;print}' <<< "$decryption")
    encryption=$(awk -F. -v m="$TRAFFIC_MODE" 'BEGIN{OFS="."}{$2=m;print}' <<< "$encryption")
    printf '%s|%s\n' "$decryption" "$encryption"
}

validate_reality_key() {
    local key="$1" normalized padding bytes
    [[ "$key" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    normalized=$(printf '%s' "$key" | tr '_-' '/+')
    padding=$(( (4 - ${#normalized} % 4) % 4 )); normalized+=$(printf '%*s' "$padding" '' | tr ' ' '=')
    bytes=$(printf '%s' "$normalized" | base64 -d 2>/dev/null | wc -c) || return 1
    [ "$bytes" = 32 ]
}

generate_reality_keys() {
    local out private public
    out=$("$XRAY_BIN" x25519 2>/dev/null) || true
    private=$(awk '/^(PrivateKey:|Private key:)/ {print $NF; exit}' <<< "$out")
    public=$(awk '/^(Password|PublicKey:|Public key:)/ {print $NF; exit}' <<< "$out")
    if ! validate_reality_key "$private" || ! validate_reality_key "$public"; then
        error "无法解析或校验 REALITY 密钥对。"
        return 1
    fi
    printf '%s|%s\n' "$private" "$public"
}

write_config() {
    local port="$1" uuid="$2" decryption="$3" encryption="$4" mode="$5" private="${6:-}" public="${7:-}" sni="${8:-}" short_id="${9:-}"
    local tmp account user group enc_tmp reality_tmp test_log snapshot merged
    local preserve="${10:-false}"
    validate_encryption_token "$encryption" 0rtt || return 1
    if [ "$mode" = reality ]; then
        validate_reality_key "$private" && validate_reality_key "$public" && valid_sni "$sni" && valid_short_id "$short_id" || return 1
    fi
    account=$(service_account) || { error "无法确定 Xray systemd 服务账户。"; return 1; }
    user=${account%%:*}; group=${account#*:}
    install -d -m 0755 "$(dirname "$XRAY_CONFIG")" || return 1
    tmp=$(mktemp "${XRAY_CONFIG}.tmp.XXXXXX.json") || return 1
    chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
    if [ "$mode" = reality ]; then
        jq -n --argjson port "$port" --arg uuid "$uuid" --arg decryption "$decryption" --arg private "$private" --arg sni "$sni" --arg sid "$short_id" '
          {log:{loglevel:"warning"},inbounds:[{listen:"::",port:$port,protocol:"vless",settings:{clients:[{id:$uuid,flow:"xtls-rprx-vision"}],decryption:$decryption},streamSettings:{network:"tcp",security:"reality",realitySettings:{show:false,dest:($sni+":443"),xver:0,serverNames:[$sni],privateKey:$private,shortIds:[$sid]}}}],outbounds:[{protocol:"freedom",settings:{domainStrategy:"UseIPv4v6"}}]}' > "$tmp" || { rm -f "$tmp"; return 1; }
    else
        jq -n --argjson port "$port" --arg uuid "$uuid" --arg decryption "$decryption" '
          {log:{loglevel:"warning"},inbounds:[{listen:"::",port:$port,protocol:"vless",settings:{clients:[{id:$uuid,flow:"xtls-rprx-vision"}],decryption:$decryption}}],outbounds:[{protocol:"freedom",settings:{domainStrategy:"UseIPv4v6"}}]}' > "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    if [ "$preserve" = true ]; then
        merged=$(mktemp "${XRAY_CONFIG}.tmp.XXXXXX.json") || { rm -f "$tmp"; return 1; }
        # Only update owned parameters; preserve listeners, clients and user extensions.
        if ! jq --slurpfile new "$tmp" '
          .inbounds[0] |= (
            .port = $new[0].inbounds[0].port |
            .settings.decryption = $new[0].inbounds[0].settings.decryption |
            .settings.clients[0].id = $new[0].inbounds[0].settings.clients[0].id |
            if $new[0].inbounds[0].streamSettings.security == "reality" then
              if .streamSettings.security == "reality" then
                .streamSettings.realitySettings |= (
                  if .serverNames[0] != $new[0].inbounds[0].streamSettings.realitySettings.serverNames[0] then
                    .dest = $new[0].inbounds[0].streamSettings.realitySettings.dest |
                    .serverNames[0] = $new[0].inbounds[0].streamSettings.realitySettings.serverNames[0]
                  else . end |
                  .shortIds[0] = $new[0].inbounds[0].streamSettings.realitySettings.shortIds[0])
              else
                .streamSettings = ((.streamSettings // {}) * $new[0].inbounds[0].streamSettings)
              end
            else
              if .streamSettings.security == "reality" then
                .streamSettings |= (del(.realitySettings) | .security = "none")
              else . end
            end)' "$XRAY_CONFIG" > "$merged"; then
            rm -f "$tmp" "$merged"; return 1
        fi
        mv -f "$merged" "$tmp" || { rm -f "$tmp" "$merged"; return 1; }
    fi
    test_log=$(mktemp) || { rm -f "$tmp"; return 1; }
    chmod 600 "$test_log" || { rm -f "$tmp" "$test_log"; return 1; }
    if ! "$XRAY_BIN" run -test -config "$tmp" >"$test_log" 2>&1; then
        error "Xray 配置校验失败，未替换现有配置。"; sed -n '1,40p' "$test_log" >&2 || true; rm -f "$tmp" "$test_log"; return 1
    fi
    rm -f "$test_log"
    snapshot=$(mktemp -d /tmp/xray-rollback.XXXXXX) || { rm -f "$tmp"; return 1; }
    if ! chmod 700 "$snapshot" ||
       ! { [ ! -f "$XRAY_CONFIG" ] || cp -p "$XRAY_CONFIG" "$snapshot/config.json"; } ||
       ! { [ ! -f "$ENCRYPTION_INFO" ] || cp -p "$ENCRYPTION_INFO" "$snapshot/encryption.info"; } ||
       ! { [ ! -f "$REALITY_INFO" ] || cp -p "$REALITY_INFO" "$snapshot/reality.info"; }; then
        rm -rf "$snapshot"; rm -f "$tmp"
        error "无法创建配置快照，未替换现有配置。"; return 1
    fi
    ROLLBACK_DIR="$snapshot"
    enc_tmp=$(mktemp "${ENCRYPTION_INFO}.tmp.XXXXXX") || { rm -f "$tmp"; return 1; }
    if ! chmod 600 "$enc_tmp" || ! printf '%s\n' "$encryption" > "$enc_tmp"; then
        rm -f "$tmp" "$enc_tmp"; return 1
    fi
    if [ "$mode" = reality ]; then
        reality_tmp=$(mktemp "${REALITY_INFO}.tmp.XXXXXX") || { rm -f "$tmp" "$enc_tmp"; return 1; }
        if ! chmod 600 "$reality_tmp" || ! printf '%s|%s|%s\n' "$public" "$sni" "$short_id" > "$reality_tmp"; then
            rm -f "$tmp" "$enc_tmp" "$reality_tmp"; return 1
        fi
    else
        reality_tmp=""
    fi
    if ! mv -f "$tmp" "$XRAY_CONFIG" || ! chmod 600 "$XRAY_CONFIG" || ! chown "$user:$group" "$XRAY_CONFIG"; then
        error "替换 Xray 配置失败，正在恢复旧配置。"
        rm -f "$tmp" "$enc_tmp" "$reality_tmp"
        rollback_config
        return 1
    fi
    if ! mv -f "$enc_tmp" "$ENCRYPTION_INFO"; then
        error "写入客户端加密信息失败，正在恢复旧配置。"
        rm -f "$reality_tmp"
        rollback_config
        return 1
    fi
    if [ "$mode" = reality ]; then
        if ! mv -f "$reality_tmp" "$REALITY_INFO"; then
            error "写入 REALITY 客户端信息失败，正在恢复旧配置。"
            rollback_config
            return 1
        fi
    elif ! rm -f "$REALITY_INFO"; then
        error "清理旧 REALITY 信息失败，正在恢复旧配置。"
        rollback_config
        return 1
    fi
}

valid_ipv6() {
    local ip="$1" part tail left right count=0 octet
    local -a parts octets
    if [[ "$ip" == *.* ]]; then
        tail=${ip##*:}
        IFS=. read -r -a octets <<< "$tail"
        [ "${#octets[@]}" = 4 ] || return 1
        for octet in "${octets[@]}"; do
            [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] && [ "$octet" -le 255 ] || return 1
        done
        ip=${ip%:*}:0:0
    fi
    [[ "$ip" =~ ^[0-9A-Fa-f:]+$ && "$ip" != *:::* ]] || return 1
    if [[ "$ip" == *::* ]]; then
        left=${ip%%::*}; right=${ip#*::}
        [[ "$right" != *::* ]] || return 1
        ip=${left:+$left:}$right
    else
        [[ "$ip" != :* && "$ip" != *: ]] || return 1
        left=full
    fi
    IFS=: read -r -a parts <<< "$ip"
    for part in "${parts[@]}"; do
        [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        count=$((count + 1))
    done
    if [ "$left" = full ]; then [ "$count" = 8 ]; else [ "$count" -lt 8 ]; fi
}

public_ip() {
    local ip valid octet cache_file="/usr/local/etc/xray/.public-ip"
    local -a ip_octets
    # 缓存 1 天，避免每次查看配置都发起网络请求；公网 IP 变更后自动刷新
    if [ -f "$cache_file" ] && [ -z "$(find "$cache_file" -mmin +1440 2>/dev/null)" ]; then
        ip=$(<"$cache_file")
        [ -n "$ip" ] && { printf '%s\n' "$ip"; return; }
    fi
    for endpoint in https://api-ipv4.ip.sb/ip https://api.ipify.org https://ip.seeip.org; do
        ip=$(curl -4fs --max-time 5 "$endpoint" 2>/dev/null || true)
        if [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
            valid=true
            IFS='.' read -r -a ip_octets <<< "$ip"
            for octet in "${ip_octets[@]}"; do [ "$octet" -le 255 ] || valid=false; done
            if [ "$valid" = true ]; then
                { [[ -d "${cache_file%/*}" ]] && printf '%s\n' "$ip" 2>/dev/null > "$cache_file"; } || true
                printf '%s\n' "$ip"; return
            fi
        fi
    done
    for endpoint in https://api-ipv6.ip.sb/ip https://api64.ipify.org; do
        ip=$(curl -6fs --max-time 5 "$endpoint" 2>/dev/null || true)
        if valid_ipv6 "$ip"; then
            { [[ -d "${cache_file%/*}" ]] && printf '[%s]\n' "$ip" 2>/dev/null > "$cache_file"; } || true
            printf '[%s]\n' "$ip"; return
        fi
    done
    return 1
}

show_subscription() {
    local address uuid port encryption security public sni sid link title
    if [ ! -f "$XRAY_CONFIG" ] || [ ! -f "$ENCRYPTION_INFO" ]; then
        error "缺少配置或客户端信息。"
        return 1
    fi
    jq -e '.inbounds[0].port and .inbounds[0].settings.clients[0].id and .inbounds[0].settings.decryption' "$XRAY_CONFIG" >/dev/null 2>&1 || {
        error "Xray 配置结构无效，无法生成订阅链接。"
        return 1
    }
    address=$(public_ip) || { error "无法获取公网 IP，无法生成订阅链接。"; return 1; }
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG"); port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG"); encryption=$(<"$ENCRYPTION_INFO")
    security=$(jq -r '.inbounds[0].streamSettings.security // "none"' "$XRAY_CONFIG")
    if [ "$security" = reality ]; then
        [ -f "$REALITY_INFO" ] || { error "缺少 REALITY 客户端信息。"; return 1; }
        IFS='|' read -r public sni sid < "$REALITY_INFO" || return 1
        if ! validate_reality_key "$public" || ! valid_sni "$sni" || ! valid_short_id "$sid"; then
            error "REALITY 客户端信息无效，请先修改配置修复。"; return 1
        fi
        title="$(hostname) VLESS-E-REALITY"
        link="vless://${uuid}@${address}:${port}?encryption=$(uri_encode "$encryption")&security=reality&sni=$(uri_encode "$sni")&sid=$(uri_encode "$sid")&fp=chrome&pbk=$(uri_encode "$public")&flow=xtls-rprx-vision&type=tcp#$(uri_encode "$title")"
    else
        title="$(hostname) VLESS-E"
        link="vless://${uuid}@${address}:${port}?encryption=$(uri_encode "$encryption")&flow=xtls-rprx-vision&type=tcp&security=none#$(uri_encode "$title")"
    fi
    local sub_tmp
    sub_tmp=$(mktemp "${SUBSCRIPTION_INFO}.tmp.XXXXXX") || return 1
    if ! chmod 600 "$sub_tmp" || ! printf '%s\n' "$link" > "$sub_tmp" || ! mv -f "$sub_tmp" "$SUBSCRIPTION_INFO"; then
        rm -f "$sub_tmp"
        error "保存订阅链接失败。"; return 1
    fi
    print_divider
    cecho "$C_CYAN" " --- VLESS 订阅信息 --- "
    echo " 模式: $([ "$security" = reality ] && echo 'VLESS Encryption + REALITY' || echo 'VLESS Encryption')"
    echo " 地址: $address"; echo " 端口: $port"; echo " UUID: $uuid"
    echo " 传输: tcp | 安全: $security"
    echo " 流控: xtls-rprx-vision"
    [ "$security" = reality ] || echo " security=none：无 TLS 外层，仍由 VLESS Encryption 加密。"
    echo " 客户端 encryption: $encryption"
    [ "$security" != reality ] || { echo " SNI: $sni"; echo " Short ID: $sid"; echo " PublicKey: $public"; echo " 指纹: chrome"; }
    print_divider; cecho "$C_GREEN" " 订阅链接（已保存到 $SUBSCRIPTION_INFO）："; echo; cecho "$C_GREEN" "$link"; print_divider
}

print_step() { cecho "$C_BLUE" "  [$1/$2] $3" 2; }
print_divider() { cecho "$C_CYAN" "────────────────────────────────────" 1; }

# xray-dual 同款菜单项：彩色编号 + 两列对齐
menu_item() { # <颜色> <编号> <说明>
    local color="$1" num="$2" label="$3"
    if color_enabled 1; then
        printf "  %b%-2s%b %-35s\n" "$color" "$num" "$C_RESET" "$label"
    else
        printf "  %-2s %-35s\n" "$num" "$label"
    fi
}

# 带颜色的默认值文本（NO_COLOR/非 tty 时纯文本，供 read -p 使用）
prompt_default() {
    if color_enabled 2; then printf '%b%s%b' "$C_CYAN" "$1" "$C_RESET"; else printf '%s' "$1"; fi
}

xray_status_line() {
    local version mode
    if [ ! -x "$XRAY_BIN" ]; then
        cecho "$C_RED" " Xray 状态: 未安装" 1
        return
    fi
    version=$("$XRAY_BIN" version 2>/dev/null | awk 'NR==1{print $2}' || true)
    version=${version:-未知}
    local state_text state_color
    if systemctl is-active --quiet xray 2>/dev/null; then
        state_text="运行中"; state_color="$C_GREEN"
    else
        state_text="未运行"; state_color="$C_YELLOW"
    fi
    if [ -f "$XRAY_CONFIG" ] && [ "$(jq -r '.inbounds[0].streamSettings.security // "none"' "$XRAY_CONFIG" 2>/dev/null)" = reality ]; then
        mode="VLESS Encryption + REALITY"
    else
        mode="VLESS Encryption"
    fi
    if color_enabled 1; then
        printf ' Xray 状态: %b已安装%b | %b%s%b | 版本: %b%s%b\n' \
            "$C_GREEN" "$C_RESET" "$state_color" "$state_text" "$C_RESET" "$C_CYAN" "$version" "$C_RESET"
    else
        printf ' Xray 状态: 已安装 | %s | 版本: %s\n' "$state_text" "$version"
    fi
    cecho "$C_CYAN" " 当前配置: $mode" 1
}

uninstall_xray() {
    local confirm
    if [ ! -x "$XRAY_BIN" ] && [ ! -f "$XRAY_CONFIG" ] && [ ! -f "$ENCRYPTION_INFO" ] && [ ! -f "$REALITY_INFO" ] && [ ! -f "$SUBSCRIPTION_INFO" ] && [ ! -f /etc/systemd/system/xray.service ]; then
        info "Xray 未安装，无需卸载。"
        return 0
    fi
    echo
    cecho "$C_YELLOW" "  即将卸载 Xray，并使用官方 --purge 清除 Xray 的全部配置和文件。"
    cecho "$C_YELLOW" "  这不仅限于本脚本生成的文件；成功后还会删除本脚本，操作不可恢复。"
    read -r -p "  确定继续？[y/N]: " confirm || { error "读取确认失败，已取消卸载。"; return 2; }
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then info "已取消卸载。"; return 0; fi
    print_step 1 3 "正在停止并卸载 Xray..."
    if [ -x "$XRAY_BIN" ] || [ -f /etc/systemd/system/xray.service ]; then
        if ! run_official_installer remove --purge; then error "Xray 卸载失败。"; return 1; fi
    else
        info "Xray 二进制与服务不存在，跳过官方卸载，仅清理残留。"
    fi
    print_step 2 3 "正在清除配置和客户端信息..."
    if ! rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray ||
       ! rm -f "$ENCRYPTION_INFO" "$REALITY_INFO" "$SUBSCRIPTION_INFO"; then
        error "残留文件清理失败，保留本脚本以便重试。"; return 1
    fi
    print_step 3 3 "正在确认卸载结果..."
    if [ -e "$XRAY_BIN" ] || systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -qx 'xray.service'; then
        error "仍检测到 Xray 文件或服务，请使用菜单 5 查看日志。"
        return 1
    fi
    # 官方 --purge 不会删除本脚本及脚本生成在 /root 下的文件。
    if [ -f "${0:-}" ] && ! rm -f -- "$0"; then
        error "本脚本删除失败，请手动删除 $0"; return 1
    fi
    success "Xray、配置、客户端信息及本脚本已清除。"
}

rollback_config() {
    if [ -z "$ROLLBACK_DIR" ] || [ ! -d "$ROLLBACK_DIR" ]; then return 0; fi
    error "正在恢复上一次可用配置..."
    local failed=false
    if [ -f "$ROLLBACK_DIR/config.json" ]; then cp -p "$ROLLBACK_DIR/config.json" "$XRAY_CONFIG" || failed=true; else rm -f "$XRAY_CONFIG" || failed=true; fi
    if [ -f "$ROLLBACK_DIR/encryption.info" ]; then cp -p "$ROLLBACK_DIR/encryption.info" "$ENCRYPTION_INFO" || failed=true; else rm -f "$ENCRYPTION_INFO" || failed=true; fi
    if [ -f "$ROLLBACK_DIR/reality.info" ]; then cp -p "$ROLLBACK_DIR/reality.info" "$REALITY_INFO" || failed=true; else rm -f "$REALITY_INFO" || failed=true; fi
    if [ -f "$XRAY_CONFIG" ] && ! "$XRAY_BIN" run -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then failed=true; fi
    if [ "$failed" = true ]; then
        error "配置回滚失败，请手动恢复；快照保留在 $ROLLBACK_DIR"
        return 1
    fi
    clear_rollback || return 1
    success "配置回滚完成。"
}
clear_rollback() { [ -z "$ROLLBACK_DIR" ] || { rm -rf "$ROLLBACK_DIR" || return 1; ROLLBACK_DIR=""; }; }
begin_install_snapshot() {
    local dir geo
    dir=$(mktemp -d /tmp/xray-install-rollback.XXXXXX) || return 1
    if ! chmod 700 "$dir" ||
       ! { [ ! -e "$XRAY_BIN" ] || cp -p "$XRAY_BIN" "$dir/xray"; } ||
       ! { [ ! -f "$XRAY_CONFIG" ] || cp -p "$XRAY_CONFIG" "$dir/config.json"; } ||
       ! { [ ! -f "$ENCRYPTION_INFO" ] || cp -p "$ENCRYPTION_INFO" "$dir/encryption.info"; } ||
       ! { [ ! -f "$REALITY_INFO" ] || cp -p "$REALITY_INFO" "$dir/reality.info"; }; then
        rm -rf "$dir"
        return 1
    fi
    for geo in geoip.dat geosite.dat; do
        if [ -f "/usr/local/share/xray/$geo" ] && ! cp -p "/usr/local/share/xray/$geo" "$dir/$geo"; then
            rm -rf "$dir"; return 1
        fi
    done
    if systemctl is-active --quiet xray; then
        touch "$dir/was-active" || { rm -rf "$dir"; return 1; }
    fi
    if [ -f /etc/systemd/system/xray.service ]; then
        cp -p /etc/systemd/system/xray.service "$dir/xray.service" || { rm -rf "$dir"; return 1; }
    fi
    INSTALL_ROLLBACK_DIR="$dir"
}
restore_install_snapshot() {
    if [ -z "$INSTALL_ROLLBACK_DIR" ] || [ ! -d "$INSTALL_ROLLBACK_DIR" ]; then return 0; fi
    error "正在恢复安装前的配置和 Xray 核心..."
    local failed=false geo
    if ! systemctl stop xray; then
        error "停止 Xray 失败，未覆盖文件；快照保留在 $INSTALL_ROLLBACK_DIR"; return 1
    fi
    if [ -f "$INSTALL_ROLLBACK_DIR/xray" ]; then cp -p "$INSTALL_ROLLBACK_DIR/xray" "$XRAY_BIN" || failed=true; else rm -f "$XRAY_BIN" || failed=true; fi
    if [ -f "$INSTALL_ROLLBACK_DIR/config.json" ]; then cp -p "$INSTALL_ROLLBACK_DIR/config.json" "$XRAY_CONFIG" || failed=true; else rm -f "$XRAY_CONFIG" || failed=true; fi
    if [ -f "$INSTALL_ROLLBACK_DIR/encryption.info" ]; then cp -p "$INSTALL_ROLLBACK_DIR/encryption.info" "$ENCRYPTION_INFO" || failed=true; else rm -f "$ENCRYPTION_INFO" || failed=true; fi
    if [ -f "$INSTALL_ROLLBACK_DIR/reality.info" ]; then cp -p "$INSTALL_ROLLBACK_DIR/reality.info" "$REALITY_INFO" || failed=true; else rm -f "$REALITY_INFO" || failed=true; fi
    for geo in geoip.dat geosite.dat; do
        if [ -f "$INSTALL_ROLLBACK_DIR/$geo" ]; then
            cp -p "$INSTALL_ROLLBACK_DIR/$geo" "/usr/local/share/xray/$geo" || failed=true
        else
            rm -f "/usr/local/share/xray/$geo" || failed=true
        fi
    done
    if [ -f "$INSTALL_ROLLBACK_DIR/xray.service" ]; then
        cp -p "$INSTALL_ROLLBACK_DIR/xray.service" /etc/systemd/system/xray.service || failed=true
    elif [ ! -f "$INSTALL_ROLLBACK_DIR/xray" ]; then
        if systemctl disable --now xray; then
            rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service || failed=true
        else failed=true; fi
    fi
    systemctl daemon-reload || failed=true
    if [ "$failed" = false ] && [ -f "$INSTALL_ROLLBACK_DIR/was-active" ] && [ -x "$INSTALL_ROLLBACK_DIR/xray" ]; then
        restart_xray || failed=true
    fi
    if [ "$failed" = true ]; then
        error "安装回滚失败，请手动恢复；快照保留在 $INSTALL_ROLLBACK_DIR"; return 1
    fi
    clear_install_snapshot || return 1
    success "安装回滚完成。"
}
clear_install_snapshot() { [ -z "$INSTALL_ROLLBACK_DIR" ] || { rm -rf "$INSTALL_ROLLBACK_DIR" || return 1; INSTALL_ROLLBACK_DIR=""; }; }
update_xray() {
    [ -f /etc/systemd/system/xray.service ] || { error "主服务文件缺失，请先恢复 /etc/systemd/system/xray.service。"; return 1; }
    begin_install_snapshot || { error "无法创建更新回滚快照。"; return 1; }
    # --without-geodata: 官方 install 默认已含 geodata 下载，与下方
    # install-geodata 重复；统一由 install-geodata 负责。
    if ! run_official_installer install --without-geodata --no-update-service; then
        error "Xray 更新失败，正在回滚。"
    elif ! run_official_installer install-geodata; then
        error "GeoIP/GeoSite 更新失败，正在回滚。"
    elif ! { if [ -f "$INSTALL_ROLLBACK_DIR/was-active" ]; then restart_xray; else systemctl stop xray; fi; }; then
        error "恢复 Xray 运行状态失败，正在回滚。"
    else
        clear_install_snapshot
        success "Xray 更新完成。"
        return 0
    fi
    restore_install_snapshot || return 1
    return 1
}
abort_install() {
    restore_install_snapshot || return 1
    clear_rollback
    return 1
}
uri_encode() { jq -nr --arg value "$1" '$value | @uri'; }
restart_xray() {
    info "正在重启 Xray 服务..."
    if systemctl restart xray && sleep 1 && systemctl is-active --quiet xray; then
        success "Xray 服务已成功重启."; return 0
    fi
    error "Xray 服务启动失败。"
    return 1
}

install_selected() {
    local port="$1" uuid="$2" mode="$3" sni="${4:-}" sid="${5:-}" pair dec enc keys private public
    local total=4 path
    local -a service_args=()
    [ "$mode" != reality ] || total=5
    if [ -f /etc/systemd/system/xray.service ]; then
        service_args=(--no-update-service)
    else
        # 官方在主 unit 缺失时忽略 --no-update-service；拒绝覆盖残留服务定义。
        for path in "$XRAY_BIN" "$XRAY_CONFIG" \
            /etc/systemd/system/xray.service /etc/systemd/system/xray@.service \
            /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d \
            /lib/systemd/system/xray.service /usr/lib/systemd/system/xray.service; do
            if [ -e "$path" ] || [ -L "$path" ]; then
                error "检测到既有安装但主服务文件缺失，请先恢复 /etc/systemd/system/xray.service。"; return 1
            fi
        done
    fi
    begin_install_snapshot || { error "无法创建安装回滚快照。"; return 1; }
    print_step 1 "$total" "正在安装 / 更新 Xray 核心..."
    # --without-geodata: 官方 install 默认已含 geodata 下载，与下方
    # install-geodata 重复；统一由 install-geodata 负责。
    run_official_installer install --without-geodata "${service_args[@]}" || { error "Xray 核心安装失败。"; abort_install; return 1; }
    print_step 2 "$total" "正在更新 GeoIP 和 GeoSite 数据..."
    run_official_installer install-geodata || { error "Geo 数据更新失败。"; abort_install; return 1; }
    print_step 3 "$total" "正在生成 VLESS Encryption 密钥材料..."
    xray_supports || { error "已安装的 Xray 不支持 VLESS Encryption。"; abort_install; return 1; }
    pair=$(generate_encryption_pair) || { abort_install; return 1; }; IFS='|' read -r dec enc <<< "$pair"
    if [ "$mode" = reality ]; then
        print_step 4 5 "正在生成 REALITY 密钥对..."
        keys=$(generate_reality_keys) || { abort_install; return 1; }; IFS='|' read -r private public <<< "$keys"
        print_step 5 5 "正在写入并校验 REALITY 配置..."
        write_config "$port" "$uuid" "$dec" "$enc" reality "$private" "$public" "$sni" "$sid" || { abort_install; return 1; }
    else
        print_step 4 "$total" "正在写入并校验配置..."
        write_config "$port" "$uuid" "$dec" "$enc" encryption || { abort_install; return 1; }
    fi
    if ! restart_xray; then
        abort_install || return 1
        return 1
    fi
    clear_install_snapshot
    clear_rollback
    success "安装完成：$([ "$mode" = reality ] && echo 'VLESS Encryption + REALITY' || echo 'VLESS Encryption')。"
    show_subscription || info "Xray 已安装并运行，但暂时无法生成订阅链接。"
    return 0
}

interactive_install() {
    local choice port uuid sni="" sid="20220701" mode
    echo
    section_title "请选择安装模式（每次只能安装一种）"
    info "安装 / 重装覆盖 Xray 配置；请放行节点端口。"
    info "客户端须支持 VLESS Encryption、encryption 参数及 Vision（xtls-rprx-vision）。"
    info "Encryption 自身加密；需要 TLS 外观选 + REALITY。"
    menu_item "$C_GREEN" "1." "VLESS Encryption"
    menu_item "$C_YELLOW" "2." "VLESS Encryption + REALITY"
    print_divider
    read -r -p " 请输入选项 [1-2]: " choice || { error "读取菜单输入失败，请在交互式终端中运行。"; return 2; }
    case "$choice" in 1) mode=encryption;; 2) mode=reality;; *) error "无效选项。"; return 1;; esac
    read -r -p " -> 请输入端口 [1-65535] (默认: $(prompt_default 443)): " port || { error "读取端口失败。"; return 2; }; port=${port:-443}; valid_port "$port" || { error "端口无效。"; return 1; }
    if [ "$port" != "$(current_port)" ] && port_in_use "$port"; then
        error "端口 $port 已被占用，请选择其他端口。"
        return 1
    fi
    read -r -p " -> 请输入UUID (留空将自动生成): " uuid || { error "读取 UUID 失败。"; return 2; }; uuid=${uuid:-$("$XRAY_BIN" uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)}; valid_uuid "$uuid" || { error "UUID 格式无效。"; return 1; }
    if [ "$mode" = reality ]; then
        info "SNI 目标须从服务器可达、支持 TLS 1.3（443）；无需自有域名或证书。"
        read -r -p " -> 请输入REALITY SNI域名 (默认: $(prompt_default www.sega.com)): " sni || { error "读取 SNI 失败。"; return 2; }; sni=${sni:-www.sega.com}; valid_sni "$sni" || { error "SNI 格式无效。"; return 1; }
        read -r -p " -> 请输入REALITY Short ID [2-16 位偶数长度十六进制] (默认: $(prompt_default 20220701)): " sid || { error "读取 Short ID 失败。"; return 2; }; sid=${sid:-20220701}; valid_short_id "$sid" || { error "Short ID 格式无效。"; return 1; }
    fi
    print_divider
    info "开始安装：$([ "$mode" = reality ] && echo 'VLESS Encryption + REALITY' || echo 'VLESS Encryption')；认证 ${AUTH_MODE} / 外观 ${TRAFFIC_MODE}（选项见 --help）。"
    install_selected "$port" "$uuid" "$mode" "$sni" "$sid"
}

modify_config() {
    local current_mode target_mode choice port uuid sni="" sid="20220701" dec enc private="" public="" pair keys input
    local step=0 total=1
    if [ ! -f "$XRAY_CONFIG" ] || [ ! -f "$ENCRYPTION_INFO" ]; then
        error "未检测到可修改的 Xray 配置。"
        return 1
    fi

    current_mode=$(jq -r '.inbounds[0].streamSettings.security // "none"' "$XRAY_CONFIG")
    [ "$current_mode" = reality ] || current_mode=encryption
    port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG")
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG")

    echo
    section_title "当前模式：$([ "$current_mode" = reality ] && echo 'VLESS Encryption + REALITY' || echo 'VLESS Encryption')"
    info "仅修改首个入站相关字段；SNI 同步目标为该域名:443，其余保留。"
    info "Encryption 自身加密；+ REALITY 增加 TLS 外观。"
    info "保留模式保留密钥；切换按 ${AUTH_MODE}/${TRAFFIC_MODE} 重新生成密钥，须重新导入节点。"
    cecho "$C_CYAN" " 请选择修改方式：" 1
    print_divider
    menu_item "$C_GREEN" "1." "保留当前模式，只修改参数"
    if [ "$current_mode" = reality ]; then
        menu_item "$C_YELLOW" "2." "切换为 VLESS Encryption"
    else
        menu_item "$C_YELLOW" "2." "切换为 VLESS Encryption + REALITY"
    fi
    menu_item "$C_MAGENTA" "0." "返回主菜单"
    print_divider
    read -r -p " 请输入选项 [0-2]: " choice || { error "读取菜单输入失败，请在交互式终端中运行。"; return 2; }
    case "$choice" in
        0) return ;;
        1) target_mode=$current_mode ;;
        2)
            if [ "$current_mode" = reality ]; then target_mode=encryption; else target_mode=reality; fi
            ;;
        *) error "无效选项。"; return 1 ;;
    esac

    read -r -p " -> 新端口 (当前: $(prompt_default "$port"), 回车保留): " input || { error "读取端口失败。"; return 2; }; port=${input:-$port}; valid_port "$port" || { error "端口无效。"; return 1; }
    if [ "$port" != "$(jq -r '.inbounds[0].port // empty' "$XRAY_CONFIG" 2>/dev/null)" ] && port_in_use "$port"; then
        error "端口 $port 已被占用，请选择其他端口。"
        return 1
    fi
    read -r -p " -> 新UUID (当前: $(prompt_default "$uuid"), 回车保留): " input || { error "读取 UUID 失败。"; return 2; }; uuid=${input:-$uuid}; valid_uuid "$uuid" || { error "UUID 格式无效。"; return 1; }

    if [ "$target_mode" != "$current_mode" ]; then
        total=2
        [ "$target_mode" != reality ] || total=3
    fi
    if [ "$target_mode" = reality ]; then
        if [ "$current_mode" = reality ]; then
            private=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey // empty' "$XRAY_CONFIG")
            sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0] // empty' "$XRAY_CONFIG")
            sid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0] // empty' "$XRAY_CONFIG")
            validate_reality_key "$private" || { error "现有 REALITY 私钥无效，未修改配置。"; return 1; }
            keys=$("$XRAY_BIN" x25519 -i "$private") || return 1
            public=$(awk '/^(Password|PublicKey:|Public key:)/ {print $NF; exit}' <<< "$keys")
            validate_reality_key "$public" || { error "无法推导 REALITY 公钥。"; return 1; }
        else
            sni="www.sega.com"
        fi
        info "SNI 目标须从服务器可达、支持 TLS 1.3（443）；无需自有域名或证书。"
        read -r -p " -> REALITY SNI (当前/默认: $(prompt_default "$sni"), 回车保留): " input || { error "读取 SNI 失败。"; return 2; }; sni=${input:-$sni}; valid_sni "$sni" || { error "SNI 格式无效。"; return 1; }
        read -r -p " -> REALITY Short ID [2-16 位偶数长度十六进制] (当前/默认: $(prompt_default "$sid"), 回车保留): " input || { error "读取 Short ID 失败。"; return 2; }; sid=${input:-$sid}; valid_short_id "$sid" || { error "Short ID 格式无效。"; return 1; }
        # 仅切换到 REALITY 时生成新密钥；保留模式从现有私钥推导。
        if [ "$current_mode" != reality ]; then
            step=$((step + 1)); print_step "$step" "$total" "正在生成 REALITY 密钥对..."
            keys=$(generate_reality_keys) || return 1
            IFS='|' read -r private public <<< "$keys"
        fi
    fi

    if [ "$target_mode" = "$current_mode" ]; then
        dec=$(jq -r '.inbounds[0].settings.decryption' "$XRAY_CONFIG")
        enc=$(<"$ENCRYPTION_INFO")
    else
        step=$((step + 1)); print_step "$step" "$total" "正在生成 $([ "$target_mode" = reality ] && echo 'REALITY 模式' || echo 'Encryption 模式') 密钥材料..."
        pair=$(generate_encryption_pair) || return 1
        IFS='|' read -r dec enc <<< "$pair"
    fi
    step=$((step + 1)); print_step "$step" "$total" "正在写入并校验新配置..."
    if [ "$target_mode" = reality ]; then
        if ! write_config "$port" "$uuid" "$dec" "$enc" reality "$private" "$public" "$sni" "$sid" true; then
            error "配置写入失败。"
            return 1
        fi
    elif ! write_config "$port" "$uuid" "$dec" "$enc" encryption "" "" "" "" true; then
        error "配置写入失败。"
        return 1
    fi
    if ! restart_xray; then
        error "正在回滚配置。"
        rollback_config || true
        if ! restart_xray; then
            error "回滚后 Xray 仍未运行，请立即检查服务和配置。"
        fi
        return 1
    fi
    clear_rollback
    success "配置已更新为 $([ "$target_mode" = reality ] && echo 'VLESS Encryption + REALITY' || echo 'VLESS Encryption')。"
    show_subscription
}

print_header() {
    clear 2>/dev/null || true
    cecho "$C_CYAN" " Xray VLESS Encryption 管理脚本" 1
    cecho "$C_YELLOW" " Version: ${SCRIPT_VERSION}" 1
    print_divider
    xray_status_line
    print_divider
}

main_menu() {
    local choice
    while true; do
        print_header
        menu_item "$C_GREEN" "1." "安装 / 重装"
        menu_item "$C_CYAN" "2." "更新 Xray"
        menu_item "$C_CYAN" "3." "重启 Xray"
        menu_item "$C_RED" "4." "卸载 Xray"
        print_divider
        menu_item "$C_MAGENTA" "5." "查看 Xray 日志"
        menu_item "$C_YELLOW" "6." "修改当前配置"
        menu_item "$C_GREEN" "7." "查看订阅信息"
        print_divider
        menu_item "$C_YELLOW" "0." "退出"
        print_divider
        read -r -p " 请输入选项 [0-7]: " choice || { error "读取菜单输入失败，请在交互式终端中运行。"; return 2; }
        case "$choice" in
            1) ( interactive_install ) || true ;;
            2)
                current_version=$(current_xray_version || true)
                latest_version=$(latest_xray_version || true)
                if [ -z "$current_version" ]; then
                    error "无法读取当前 Xray 版本，已取消更新。"
                elif [ -z "$latest_version" ]; then
                    error "无法获取 Xray 最新版本，已取消更新。"
                elif [ "$current_version" = "$latest_version" ]; then
                    success "Xray 已是最新版本（$current_version），无需更新。"
                else
                    info "当前版本：$current_version，最新版本：$latest_version"
                    info "正在更新 Xray..."
                    update_xray || true
                fi
                ;;
            3) ( restart_xray ) || true ;;
            4) ( uninstall_xray ) || true ;;
            5) journalctl -u xray -f --no-pager || true ;;
            6) ( modify_config ) || true ;;
            7) ( show_subscription ) || true ;;
            0) success "感谢使用。"; return ;;
            *) error "无效选项。" ;;
        esac
        read -r -n 1 -s -p "  按任意键返回菜单..." || true; echo
    done
}

show_help() {
    cat <<EOF
Xray VLESS Unified Installer ${SCRIPT_VERSION}

用法：
  $0                              # 交互式：选择安装其中一种模式
  $0 install [选项]               # 无交互安装

无交互模式选择（两者只能安装一个）：
  不带 --sni：VLESS Encryption
  带 --sni： VLESS Encryption + REALITY

选项：
  --port <端口>       监听端口（默认：443）
  --uuid <UUID>       UUID（默认：自动生成）
  --auth <认证模式>   mlkem768（ML-KEM-768，后量子认证）或 x25519（非后量子认证）
                      默认：mlkem768
  --mode <流量外观>   native 原始格式；xorpub 混淆公钥部分；random 全随机外观
                      默认：native；无特殊需求保持默认，客户端须与服务端一致
  --sni <域名>        启用 REALITY + Vision；该模式必填
  --short-id <ID>     REALITY Short ID：2-16 位偶数长度十六进制（默认：20220701）
  -h, --help         显示帮助

两种模式均使用 Vision（xtls-rprx-vision）；客户端须支持 VLESS Encryption 及 encryption 参数。
Encryption 自身加密（security=none 不代表明文）；+ REALITY 增加 TLS 外观。
SNI 是服务器可达、支持 TLS 1.3 的目标域名（443），无需自有域名或证书。
认证一般选默认 mlkem768；x25519 认证密钥更短，但不具备后量子认证能力。
两种认证均使用 mlkem768x25519plus 后量子密钥交换；不要混用两组密钥。
安装 / 重装覆盖整个 Xray 配置；请自行放行节点端口。

示例：
  $0 install --port 12345
  $0 install --port 12345 --auth mlkem768 --mode native
  $0 install --port 12345 --sni www.sega.com
EOF
}

main() {
    if [ "$#" -gt 0 ] && [ "$1" != install ]; then error "未知参数: $1"; return 2; fi
    require_root_and_dependencies
    if [ "$#" -eq 0 ]; then main_menu; return; fi
    shift
    local port=443 uuid="" sni="" sid=20220701
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                if [ "$#" -ne 1 ]; then
                    error "选项 $1 不接受多余参数"
                    show_help
                    exit 2
                fi
                show_help
                exit 0
                ;;
            --port|--uuid|--auth|--mode|--sni|--short-id)
                if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" = -* ]]; then
                    error "参数 $1 缺少有效值。"
                    exit 2
                fi
                case "$1" in --port) port=$2;; --uuid) uuid=$2;; --auth) AUTH_MODE=$2;; --mode) TRAFFIC_MODE=$2;; --sni) sni=$2;; --short-id) sid=$2; REALITY_SHORT_ID_SET=true;; esac; shift 2 ;;
            *) error "未知参数: $1"; show_help; exit 2 ;;
        esac
    done
    valid_port "$port" || { error "端口无效。"; exit 1; }; valid_auth "$AUTH_MODE" || { error "认证模式无效。"; exit 1; }; valid_appearance "$TRAFFIC_MODE" || { error "外观模式无效。"; exit 1; }
    uuid=${uuid:-$(cat /proc/sys/kernel/random/uuid)}
    valid_uuid "$uuid" || { error "UUID 格式无效。"; exit 1; }
    if [ -n "$sni" ]; then INSTALL_MODE=reality; valid_sni "$sni" || { error "SNI 域名格式无效。"; exit 1; }; valid_short_id "$sid" || { error "Short ID 格式无效。"; exit 1; }
    else INSTALL_MODE=encryption; [ "$REALITY_SHORT_ID_SET" = false ] || { error "--short-id 只能与 --sni（REALITY 模式）一起使用。"; exit 2; }; fi
    # 端口占用预检查（同端口重装豁免）
    if [ "$port" != "$(current_port)" ] && port_in_use "$port"; then
        error "端口 $port 已被占用，请选择其他端口。"
        exit 1
    fi
    info "安装模式：$([ "$INSTALL_MODE" = reality ] && echo 'VLESS Encryption + REALITY' || echo 'VLESS Encryption')"
    install_selected "$port" "$uuid" "$INSTALL_MODE" "$sni" "$sid"
}

# 兼容 bash <(curl ...)、直接执行与 curl ... | bash 管道方式；
# ${BASH_SOURCE[0]:-} 兼容 set -u 下管道模式的空数组
if [ "${BASH_SOURCE[0]:-}" = "$0" ] || [ -z "${BASH_SOURCE[0]:-}" ]; then
    if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
        if [ "$#" -ne 1 ]; then
            error "选项 $1 不接受多余参数"
            show_help
            exit 2
        fi
        show_help
        exit 0
    fi
    if [ "${1:-}" = install ] && { [ "${2:-}" = --help ] || [ "${2:-}" = -h ]; }; then
        if [ "$#" -ne 2 ]; then
            error "选项 $2 不接受多余参数"
            show_help
            exit 2
        fi
        show_help
        exit 0
    fi
    if [ "$#" -gt 0 ] && [ "$1" != install ]; then
        error "未知参数: $1"; exit 2
    fi
    if [ ! -t 0 ] && [ "${1:-}" != install ]; then
        error "交互模式需要 TTY；请使用 install 子命令及非交互参数。"
        exit 2
    fi
    main "$@"
fi
