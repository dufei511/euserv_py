#!/bin/bash

# EUserv 自动续期一键部署脚本 V2.2
# 支持 Docker 和本地 Python 两种运行模式，可自由切换
# 支持多账号配置（与 euser_renew.py 变量名完全兼容）

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 配置文件路径
INSTALL_DIR="/opt/euserv_renew"
CONFIG_FILE="${INSTALL_DIR}/config.env"
SERVICE_NAME="euserv-renew"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
COMMAND_LINK="/usr/local/bin/dj"
MODE_FILE="${INSTALL_DIR}/.run_mode"
GITHUB_REPO="https://raw.githubusercontent.com/dufei511/euserv_py/main"

PYTHON_TARGET="3.12"
PYTHON_BIN_NAME="python3.12"

print_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本必须以root权限运行"
        exit 1
    fi
}

get_run_mode() {
    [ -f "${MODE_FILE}" ] && cat ${MODE_FILE} || echo "none"
}

set_run_mode() {
    echo "$1" > ${MODE_FILE}
}

create_directories() {
    print_info "创建项目目录..."
    mkdir -p ${INSTALL_DIR}/{logs,config,cookies}
    print_success "目录创建完成"
}

download_scripts() {
    print_info "下载EUserv续期脚本和依赖文件..."
    if curl -fsSL ${GITHUB_REPO}/euser_renew.py -o ${INSTALL_DIR}/euser_renew.py; then
        chmod +x ${INSTALL_DIR}/euser_renew.py
        print_success "主脚本下载成功"
    else
        print_error "主脚本下载失败，请检查网络连接或GitHub是否可访问"
        exit 1
    fi
    if curl -fsSL ${GITHUB_REPO}/requirements.txt -o ${INSTALL_DIR}/requirements.txt; then
        print_success "requirements.txt 下载成功"
    else
        print_warning "requirements.txt 下载失败，将使用默认依赖列表"
        cat > ${INSTALL_DIR}/requirements.txt <<'EOF'
requests
beautifulsoup4
lxml
python-dotenv
ddddocr
pillow
imap-tools
numpy
EOF
    fi
}

# -------------------------------------------------------
# 变量名后缀规则（与 euser_renew.py 完全一致）：
#   账号1 → 无后缀: EUSERV_EMAIL / EUSERV_PASSWORD / EMAIL_PASS / EMAIL_PIN(可选)
#   账号2 → 后缀2:  EUSERV_EMAIL2 / EUSERV_PASSWORD2 / EMAIL_PASS2 / EMAIL_PIN2(可选)
#   账号N → 后缀N
#   IMAP_SERV 已废弃，IMAP 地址由 euser_renew.py 根据 EMAIL_PIN（或 EUSERV_EMAIL）自动推断
# -------------------------------------------------------
_suffix() {
    # 账号1返回空字符串，账号2+返回数字
    local idx=$1
    [[ "$idx" -eq 1 ]] && echo "" || echo "$idx"
}

# 从配置文件读取当前账号总数
_count_accounts() {
    local max=0
    # 账号1无后缀
    grep -q "^EUSERV_EMAIL=" "${CONFIG_FILE}" 2>/dev/null && max=1
    # 账号2..20
    for i in $(seq 2 20); do
        grep -q "^EUSERV_EMAIL${i}=" "${CONFIG_FILE}" 2>/dev/null && max=$i
    done
    echo "$max"
}

# -------------------------------------------------------
# 首次安装：录入多账号
# -------------------------------------------------------
configure_env() {
    print_info "配置账号信息..."
    echo ""

    accounts=()   # 每个元素: "email|password|pin_email|pin_pass"
    account_index=1

    print_info "=== EUserv 账号配置（支持多个账号，每个账号有独立的收件邮箱）==="
    echo ""

    while true; do
        print_info "--- 账号 #${account_index} ---"
        read -p "  EUserv 登录邮箱: " acc_email
        read -sp "  EUserv 登录密码: " acc_password
        echo ""
        read -p "  接收PIN的邮箱 (直接回车则与登录邮箱相同): " acc_pin_email
        acc_pin_email="${acc_pin_email:-}"
        read -sp "  接收PIN邮箱的应用专用密码: " acc_pin_pass
        echo ""

        if [[ -z "$acc_email" || -z "$acc_password" || -z "$acc_pin_pass" ]]; then
            print_warning "必填项不能为空，请重新输入"
            continue
        fi

        accounts+=("${acc_email}|${acc_password}|${acc_pin_email}|${acc_pin_pass}")
        account_index=$((account_index + 1))

        echo ""
        read -p "  是否继续添加下一个账号? (y/N): " add_more
        [[ "$add_more" != "y" && "$add_more" != "Y" ]] && break
        echo ""
    done

    echo ""
    print_info "共录入 ${#accounts[@]} 个账号"

    echo ""
    print_info "=== 可选项：推送通知配置（不需要可直接回车跳过）==="
    read -p "Telegram Bot Token (可选): " tg_bot_token
    read -p "Telegram Chat ID (可选): " tg_chat_id
    read -p "Bark推送URL (可选): " bark_url
    echo ""

    # 写配置文件
    cat > ${CONFIG_FILE} <<EOF
# EUserv 多账号配置
# 账号1无数字后缀，账号2起追加数字: EUSERV_EMAIL2, EUSERV_EMAIL3 ...
# EMAIL_PIN 为可选项，未填写时 PIN 发送到登录邮箱；IMAP 地址由脚本自动推断，无需配置

EOF

    local idx=1
    for entry in "${accounts[@]}"; do
        IFS='|' read -r e p pin_e pin_p <<< "$entry"
        local sfx
        [[ "$idx" -eq 1 ]] && sfx="" || sfx="$idx"
        cat >> ${CONFIG_FILE} <<EOF
# 账号 $idx
EUSERV_EMAIL${sfx}=${e}
EUSERV_PASSWORD${sfx}=${p}
EMAIL_PASS${sfx}=${pin_p}
EOF
        # EMAIL_PIN 仅在与登录邮箱不同时写入
        if [[ -n "$pin_e" && "$pin_e" != "$e" ]]; then
            echo "EMAIL_PIN${sfx}=${pin_e}" >> ${CONFIG_FILE}
        fi
        echo "" >> ${CONFIG_FILE}
        idx=$((idx + 1))
    done

    cat >> ${CONFIG_FILE} <<EOF
# 推送通知配置（可选）
EOF
    [ -n "$tg_bot_token" ] && echo "TG_BOT_TOKEN=${tg_bot_token}" >> ${CONFIG_FILE}
    [ -n "$tg_chat_id" ]   && echo "TG_CHAT_ID=${tg_chat_id}"     >> ${CONFIG_FILE}
    [ -n "$bark_url" ]     && echo "BARK_URL=${bark_url}"          >> ${CONFIG_FILE}

    chmod 600 ${CONFIG_FILE}
    print_success "环境变量配置完成（共 ${#accounts[@]} 个账号）"
}

create_dockerfile() {
    print_info "创建Dockerfile..."
    cat > ${INSTALL_DIR}/Dockerfile <<'EOF'
FROM python:3.12-slim

RUN mkdir -p /app && chmod 777 /app
WORKDIR /app

COPY requirements.txt /app/
RUN pip install --no-cache-dir -r requirements.txt

ENV TZ=Asia/Shanghai
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

COPY euser_renew.py /app/
COPY config.env /app/

CMD ["python", "/app/euser_renew.py"]
EOF
    print_success "Dockerfile创建完成"
}

create_docker_compose() {
    local run_hour=$1
    print_info "创建docker-compose配置..."
    cat > ${COMPOSE_FILE} <<EOF
services:
  euserv-renew:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: euserv-renew
    restart: "no"
    env_file:
      - config.env
    volumes:
      - ./logs:/app/logs
      - ./cookies:/app/cookies
      - ./config.env:/app/config.env:ro
      - ./euser_renew.py:/app/euser_renew.py:ro
    environment:
      - TZ=Asia/Shanghai
      - RUN_HOUR=${run_hour}
    security_opt:
      - no-new-privileges:true
    labels:
      - "euserv.schedule=${run_hour}"
EOF
    print_success "docker-compose配置创建完成"
}

get_compose_cmd() {
    if docker compose version &>/dev/null 2>&1; then
        echo "$(command -v docker) compose"
    elif command -v docker-compose &>/dev/null 2>&1; then
        command -v docker-compose
    else
        echo "/usr/local/bin/docker-compose"
    fi
}

install_docker() {
    print_info "安装Docker环境..."
    if ! command -v docker &> /dev/null; then
        print_info "Docker未安装，正在安装..."
        curl -fsSL https://get.docker.com | bash
        systemctl enable docker
        systemctl start docker
        print_success "Docker安装完成"
    else
        print_success "Docker已安装"
    fi
    if ! docker compose version &> /dev/null && ! command -v docker-compose &> /dev/null; then
        print_info "Docker Compose未安装，正在安装..."
        curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
            -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
        print_success "Docker Compose安装完成"
    else
        print_success "Docker Compose已安装"
    fi
}

install_python() {
    print_info "检测Python环境..."

    EXISTING_PYTHON=""
    EXISTING_VER_MINOR=0

    for bin in python3.12 python3.11 python3.10 python3 python; do
        if command -v "$bin" &>/dev/null; then
            _ver=$("$bin" -c "import sys; print('{}.{}'.format(*sys.version_info[:2]))" 2>/dev/null)
            _major=$(echo "$_ver" | cut -d. -f1)
            _minor=$(echo "$_ver" | cut -d. -f2)
            if [[ "$_major" == "3" ]]; then
                EXISTING_PYTHON="$bin"
                EXISTING_VER_MINOR="$_minor"
                break
            fi
        fi
    done

    if [[ -n "$EXISTING_PYTHON" ]]; then
        if [[ "$EXISTING_VER_MINOR" -ge 13 ]]; then
            print_error "当前 Python 版本过高（3.${EXISTING_VER_MINOR}），续期脚本仅支持 3.12 及以下"
            print_error "请改用 Docker 模式"
            exit 1
        fi
        print_success "Python 3.${EXISTING_VER_MINOR} 符合要求，跳过安装"
        PYTHON_BIN_NAME="$EXISTING_PYTHON"
    else
        _do_install_python312
    fi

    if ! command -v ${PYTHON_BIN_NAME} &>/dev/null; then
        print_error "Python 安装失败，请改用 Docker 模式"
        exit 1
    fi

    if ! ${PYTHON_BIN_NAME} -m pip --version &>/dev/null 2>&1; then
        apt-get install -y python3-pip -qq 2>/dev/null || \
        curl -fsSL https://bootstrap.pypa.io/get-pip.py | ${PYTHON_BIN_NAME}
    fi

    if [ -f "${INSTALL_DIR}/requirements.txt" ]; then
        ${PYTHON_BIN_NAME} -m pip install -q -r "${INSTALL_DIR}/requirements.txt" \
        || ${PYTHON_BIN_NAME} -m pip install -q -r "${INSTALL_DIR}/requirements.txt" \
           --break-system-packages
        print_success "Python依赖安装完成"
    else
        print_error "requirements.txt 不存在"
        exit 1
    fi
    print_success "Python路径: $(command -v ${PYTHON_BIN_NAME})"
}

_do_install_python312() {
    . /etc/os-release 2>/dev/null
    OS_ID="${ID:-unknown}"
    OS_CODENAME="${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null || echo "unknown")}"
    print_info "系统: ${OS_ID} ${OS_CODENAME}"
    apt-get update -qq 2>/dev/null || true

    if apt-get install -y python3.12 python3-pip 2>/dev/null; then
        apt-get install -y python3.12-distutils 2>/dev/null || true
        PYTHON_BIN_NAME="python3.12"; print_success "Python 3.12 安装完成（系统源）"; return 0
    fi
    if [[ "$OS_ID" == "ubuntu" ]]; then
        apt-get install -y software-properties-common -qq
        add-apt-repository -y ppa:deadsnakes/ppa; apt-get update -qq
        if apt-get install -y python3.12 python3.12-distutils python3.12-venv python3-pip; then
            PYTHON_BIN_NAME="python3.12"; print_success "Python 3.12 安装完成（deadsnakes）"; return 0
        fi
    fi
    if [[ "$OS_ID" == "debian" ]]; then
        echo "deb http://deb.debian.org/debian ${OS_CODENAME}-backports main" \
            > /etc/apt/sources.list.d/backports.list
        apt-get update -qq
        if apt-get install -y -t "${OS_CODENAME}-backports" python3.12 python3-pip 2>/dev/null; then
            apt-get install -y -t "${OS_CODENAME}-backports" python3.12-distutils 2>/dev/null || true
            PYTHON_BIN_NAME="python3.12"; print_success "Python 3.12 安装完成（backports）"; return 0
        fi
    fi
    print_error "无法安装 Python 3.12，建议改用 Docker 模式"
    exit 1
}

get_python_path() {
    command -v ${PYTHON_BIN_NAME} 2>/dev/null || echo "/usr/bin/${PYTHON_BIN_NAME}"
}

setup_docker_cron() {
    local run_hour=$1
    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    print_info "首次构建 Docker 镜像..."
    (cd ${INSTALL_DIR} && ${compose_cmd} -f ${COMPOSE_FILE} build)
    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=EUserv Auto Renew Service (Docker)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=${INSTALL_DIR}
ExecStart=${compose_cmd} -f ${COMPOSE_FILE} run --rm euserv-renew
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/${SERVICE_NAME}.timer <<EOF
[Unit]
Description=EUserv Auto Renew Timer
Requires=${SERVICE_NAME}.service

[Timer]
OnCalendar=*-*-* ${run_hour}:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME}.timer
    systemctl start ${SERVICE_NAME}.timer
    print_success "Docker模式定时任务设置完成（每天 ${run_hour}:00）"
}

setup_python_cron() {
    local run_hour=$1
    local python_path
    python_path=$(get_python_path)
    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=EUserv Auto Renew Service (Python ${PYTHON_TARGET})
After=network.target

[Service]
Type=oneshot
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${CONFIG_FILE}
ExecStart=${python_path} ${INSTALL_DIR}/euser_renew.py
StandardOutput=journal
StandardError=journal
User=root

[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/${SERVICE_NAME}.timer <<EOF
[Unit]
Description=EUserv Auto Renew Timer
Requires=${SERVICE_NAME}.service

[Timer]
OnCalendar=*-*-* ${run_hour}:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME}.timer
    systemctl start ${SERVICE_NAME}.timer
    print_success "Python模式定时任务设置完成（每天 ${run_hour}:00）"
}

# -------------------------------------------------------
# 快捷命令 dj（内嵌脚本）
# -------------------------------------------------------
create_command() {
    print_info "创建快捷命令..."
    cat > ${COMMAND_LINK} <<'SCRIPT_EOF'
#!/bin/bash

INSTALL_DIR="/opt/euserv_renew"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
MODE_FILE="${INSTALL_DIR}/.run_mode"
CONFIG_FILE="${INSTALL_DIR}/config.env"
PYTHON_BIN="python3.12"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
print_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

get_run_mode() { [ -f "${MODE_FILE}" ] && cat ${MODE_FILE} || echo "unknown"; }
get_python_path() { command -v ${PYTHON_BIN} 2>/dev/null || echo "/usr/bin/${PYTHON_BIN}"; }
get_compose_cmd() {
    if docker compose version &>/dev/null 2>&1; then
        echo "$(command -v docker) compose"
    elif command -v docker-compose &>/dev/null 2>&1; then
        command -v docker-compose
    else
        echo "/usr/local/bin/docker-compose"
    fi
}

# 统计配置文件中的账号数
# 规则：账号1=无后缀(EUSERV_EMAIL)，账号N=后缀N(EUSERV_EMAILN)
_count_accounts() {
    local max=0
    grep -q "^EUSERV_EMAIL=" "${CONFIG_FILE}" 2>/dev/null && max=1
    for i in $(seq 2 20); do
        grep -q "^EUSERV_EMAIL${i}=" "${CONFIG_FILE}" 2>/dev/null && max=$i
    done
    echo "$max"
}

# 读取第N个账号的某字段（传字段名前缀，如 EUSERV_EMAIL）
_get_field() {
    local prefix=$1   # e.g. EUSERV_EMAIL
    local idx=$2      # e.g. 1
    local sfx
    [[ "$idx" -eq 1 ]] && sfx="" || sfx="$idx"
    grep "^${prefix}${sfx}=" "${CONFIG_FILE}" 2>/dev/null | cut -d= -f2-
}

# 设置第N个账号的某字段
_set_field() {
    local prefix=$1
    local idx=$2
    local value=$3
    local sfx
    [[ "$idx" -eq 1 ]] && sfx="" || sfx="$idx"
    local key="${prefix}${sfx}"
    if grep -q "^${key}=" "${CONFIG_FILE}"; then
        # 值中可能有特殊字符，用 python 做安全替换
        python3 -c "
import re, sys
key, val, path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f: content = f.read()
content = re.sub(r'^' + re.escape(key) + r'=.*', key + '=' + val, content, flags=re.MULTILINE)
with open(path, 'w') as f: f.write(content)
" "$key" "$value" "${CONFIG_FILE}" 2>/dev/null || \
        sed -i "s|^${key}=.*|${key}=${value}|" "${CONFIG_FILE}"
    else
        echo "${key}=${value}" >> "${CONFIG_FILE}"
    fi
}

# 删除第N个账号的所有字段
_delete_account_fields() {
    local idx=$1
    local sfx
    [[ "$idx" -eq 1 ]] && sfx="" || sfx="$idx"
    for prefix in EUSERV_EMAIL EUSERV_PASSWORD EMAIL_PASS EMAIL_PIN; do
        sed -i "/^${prefix}${sfx}=/d" "${CONFIG_FILE}"
        # 删掉上面可能残留的注释行 "# 账号 N"
        sed -i "/^# 账号 ${idx}$/d" "${CONFIG_FILE}"
    done
}

# 把第 from 位的账号所有字段重命名为第 to 位
_rename_account() {
    local from=$1 to=$2
    local sfx_from sfx_to
    [[ "$from" -eq 1 ]] && sfx_from="" || sfx_from="$from"
    [[ "$to"   -eq 1 ]] && sfx_to=""   || sfx_to="$to"
    for prefix in EUSERV_EMAIL EUSERV_PASSWORD EMAIL_PASS EMAIL_PIN; do
        local old_key="${prefix}${sfx_from}"
        local new_key="${prefix}${sfx_to}"
        local val
        val=$(grep "^${old_key}=" "${CONFIG_FILE}" | cut -d= -f2-)
        sed -i "/^${old_key}=/d" "${CONFIG_FILE}"
        echo "${new_key}=${val}" >> "${CONFIG_FILE}"
    done
}

show_menu() {
    clear
    local mode mode_display acc_count
    mode=$(get_run_mode)
    acc_count=$(_count_accounts)
    case $mode in
        docker) mode_display="Docker容器" ;;
        python) mode_display="本地Python ${PYTHON_BIN}" ;;
        *)      mode_display="未配置" ;;
    esac
    echo "======================================"
    echo " EUserv 自动续期管理面板"
    echo "======================================"
    echo " 当前运行模式: ${mode_display}"
    echo " 已配置账号数: ${acc_count} 个"
    echo "======================================"
    echo "1. 查看服务状态"
    echo "2. 查看日志"
    echo "3. 立即执行续期"
    echo "4. 重启服务"
    echo "5. 修改执行时间"
    echo "6. 管理账号"
    echo "7. 更新续期脚本"
    echo "8. 切换运行模式"
    echo "9. 卸载服务"
    echo "0. 退出"
    echo "======================================"
    read -p "请选择操作 [0-9]: " choice
    case $choice in
        1) show_status ;; 2) show_logs ;; 3) run_now ;; 4) restart_service ;;
        5) change_schedule ;; 6) manage_accounts ;; 7) update_script ;;
        8) switch_mode ;; 9) uninstall ;; 0) exit 0 ;;
        *) echo "无效选择"; sleep 2; show_menu ;;
    esac
}

show_status() {
    echo ""
    echo "===== 服务状态 ====="
    systemctl status euserv-renew.timer --no-pager
    echo ""
    echo "===== 下次执行时间 ====="
    systemctl list-timers euserv-renew.timer --no-pager
    echo ""
    read -p "按回车键返回菜单..."
    show_menu
}

show_logs() {
    echo ""
    echo "===== 最近的日志 (按Ctrl+C退出) ====="
    journalctl -u euserv-renew.service -f --no-pager
    show_menu
}

run_now() {
    echo ""
    local mode=$(get_run_mode)
    local compose_cmd=$(get_compose_cmd)
    if [ "$mode" == "docker" ]; then
        echo "===== 立即执行续期任务 (Docker模式) ====="
        cd ${INSTALL_DIR} && ${compose_cmd} run --rm euserv-renew
    elif [ "$mode" == "python" ]; then
        echo "===== 立即执行续期任务 (Python模式) ====="
        systemctl start euserv-renew.service
        sleep 2
        journalctl -u euserv-renew.service -n 50 --no-pager
    fi
    read -p "按回车键返回菜单..."
    show_menu
}

restart_service() {
    echo ""
    local mode=$(get_run_mode)
    local compose_cmd=$(get_compose_cmd)
    if [ "$mode" == "docker" ]; then
        cd ${INSTALL_DIR}; ${compose_cmd} down; ${compose_cmd} build
        systemctl restart euserv-renew.timer
        print_success "Docker服务及定时器已重启"
    elif [ "$mode" == "python" ]; then
        systemctl restart euserv-renew.timer
        print_success "Python定时服务已重启"
    fi
    sleep 2; show_menu
}

change_schedule() {
    echo ""
    read -p "请输入新的执行时间(0-23): " new_hour
    if [[ $new_hour =~ ^[0-9]+$ ]] && [ $new_hour -ge 0 ] && [ $new_hour -le 23 ]; then
        sed -i "s/OnCalendar=\*-\*-\* [0-9]\{1,2\}:00:00/OnCalendar=*-*-* ${new_hour}:00:00/" \
            /etc/systemd/system/euserv-renew.timer
        systemctl daemon-reload; systemctl restart euserv-renew.timer
        print_success "执行时间已修改为每天 ${new_hour}:00"
    else
        print_warning "无效的时间，请输入0-23之间的数字"
    fi
    sleep 2; show_menu
}

# -------------------------------------------------------
# 账号管理
# -------------------------------------------------------
_list_accounts() {
    local count=$(_count_accounts)
    if [[ "$count" -eq 0 ]]; then
        echo "  （暂无账号）"
        return
    fi
    for i in $(seq 1 "$count"); do
        local email pin_email
        email=$(_get_field EUSERV_EMAIL "$i")
        pin_email=$(_get_field EMAIL_PIN "$i")
        [[ -z "$pin_email" ]] && pin_email="（同登录邮箱）"
        printf "  账号 #%-2s  登录: %-30s  PIN收件: %s\n" \
               "$i" "$email" "$pin_email"
    done
}

manage_accounts() {
    while true; do
        echo ""
        echo "===== 账号管理 ====="
        echo ""
        _list_accounts
        echo ""
        echo "  a. 添加账号    d. 删除账号    e. 修改账号"
        echo "  n. 修改推送配置    q. 返回主菜单"
        echo ""
        read -p "请选择操作 [a/d/e/n/q]: " sub
        case "$sub" in
            a|A) _add_account ;;
            d|D) _delete_account ;;
            e|E) _edit_account ;;
            n|N) _change_notify ;;
            q|Q) break ;;
            *) echo "无效选择" ;;
        esac
    done
    show_menu
}

_add_account() {
    echo ""
    local count=$(_count_accounts)
    local new_idx=$((count + 1))
    print_info "--- 添加账号 #${new_idx} ---"

    read -p "  EUserv 登录邮箱: " new_email
    read -sp "  EUserv 登录密码: " new_pass; echo ""
    read -p "  接收PIN的邮箱 (直接回车则与登录邮箱相同): " new_pin_email
    read -sp "  接收PIN邮箱的应用专用密码: " new_pin_pass; echo ""

    if [[ -z "$new_email" || -z "$new_pass" || -z "$new_pin_pass" ]]; then
        print_warning "必填项不能为空，取消添加"
        return
    fi

    local sfx; [[ "$new_idx" -eq 1 ]] && sfx="" || sfx="$new_idx"
    {
        echo ""
        echo "# 账号 ${new_idx}"
        echo "EUSERV_EMAIL${sfx}=${new_email}"
        echo "EUSERV_PASSWORD${sfx}=${new_pass}"
        echo "EMAIL_PASS${sfx}=${new_pin_pass}"
    } >> "${CONFIG_FILE}"
    # EMAIL_PIN 仅在与登录邮箱不同时写入
    if [[ -n "$new_pin_email" && "$new_pin_email" != "$new_email" ]]; then
        echo "EMAIL_PIN${sfx}=${new_pin_email}" >> "${CONFIG_FILE}"
    fi
    print_success "账号 #${new_idx} 已添加: ${new_email}"
}

_delete_account() {
    echo ""
    local count=$(_count_accounts)
    [[ "$count" -eq 0 ]] && print_warning "没有可删除的账号" && return
    _list_accounts
    echo ""
    read -p "请输入要删除的账号序号 (1-${count}，q取消): " del_idx
    [[ "$del_idx" == "q" || "$del_idx" == "Q" ]] && return
    if ! [[ "$del_idx" =~ ^[0-9]+$ ]] || [[ "$del_idx" -lt 1 || "$del_idx" -gt "$count" ]]; then
        print_warning "无效序号"; return
    fi

    local del_email=$(_get_field EUSERV_EMAIL "$del_idx")
    read -p "确定删除账号 #${del_idx} (${del_email})? (y/N): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return

    _delete_account_fields "$del_idx"

    # 后续账号向前移位
    local j=$del_idx
    while [[ $j -lt $count ]]; do
        _rename_account $((j + 1)) $j
        j=$((j + 1))
    done

    print_success "账号 #${del_idx} (${del_email}) 已删除，剩余 $((count - 1)) 个账号"
}

_edit_account() {
    echo ""
    local count=$(_count_accounts)
    [[ "$count" -eq 0 ]] && print_warning "没有可修改的账号" && return
    _list_accounts
    echo ""
    read -p "请输入要修改的账号序号 (1-${count}，q取消): " edit_idx
    [[ "$edit_idx" == "q" || "$edit_idx" == "Q" ]] && return
    if ! [[ "$edit_idx" =~ ^[0-9]+$ ]] || [[ "$edit_idx" -lt 1 || "$edit_idx" -gt "$count" ]]; then
        print_warning "无效序号"; return
    fi

    echo ""
    echo "当前配置:"
    echo "  登录邮箱: $(_get_field EUSERV_EMAIL $edit_idx)"
    local cur_pin; cur_pin=$(_get_field EMAIL_PIN $edit_idx)
    echo "  PIN收件邮箱: ${cur_pin:-（同登录邮箱）}"
    echo "（直接回车表示保持不变）"
    echo ""

    read -p "  新的登录邮箱: " v; [[ -n "$v" ]] && _set_field EUSERV_EMAIL "$edit_idx" "$v"
    read -sp "  新的登录密码: " v; echo ""; [[ -n "$v" ]] && _set_field EUSERV_PASSWORD "$edit_idx" "$v"
    read -p "  新的PIN收件邮箱 (留空=同登录邮箱): " v
    if [[ -n "$v" ]]; then
        _set_field EMAIL_PIN "$edit_idx" "$v"
    else
        # 清除 EMAIL_PIN 字段（留空即回退到登录邮箱）
        local sfx; [[ "$edit_idx" -eq 1 ]] && sfx="" || sfx="$edit_idx"
        sed -i "/^EMAIL_PIN${sfx}=/d" "${CONFIG_FILE}"
    fi
    read -sp "  新的收件邮箱密码: " v; echo ""; [[ -n "$v" ]] && _set_field EMAIL_PASS "$edit_idx" "$v"

    print_success "账号 #${edit_idx} 已更新"
}

_change_notify() {
    echo ""
    print_info "--- 修改推送配置（留空则清除该项）---"
    read -p "Telegram Bot Token: " tg_bot_token
    read -p "Telegram Chat ID: " tg_chat_id
    read -p "Bark推送URL: " bark_url
    for key in TG_BOT_TOKEN TG_CHAT_ID BARK_URL; do
        sed -i "/^${key}=/d" "${CONFIG_FILE}"
    done
    [ -n "$tg_bot_token" ] && echo "TG_BOT_TOKEN=${tg_bot_token}" >> "${CONFIG_FILE}"
    [ -n "$tg_chat_id" ]   && echo "TG_CHAT_ID=${tg_chat_id}"    >> "${CONFIG_FILE}"
    [ -n "$bark_url" ]     && echo "BARK_URL=${bark_url}"         >> "${CONFIG_FILE}"
    print_success "推送配置已更新"
}

update_script() {
    echo ""
    echo "===== 更新续期脚本 ====="
    [ -f "${INSTALL_DIR}/euser_renew.py" ] && \
        echo "当前修改时间: $(stat -c %y ${INSTALL_DIR}/euser_renew.py 2>/dev/null)"
    echo ""
    read -p "确定从GitHub更新? (y/N): " confirm
    [[ $confirm != "y" && $confirm != "Y" ]] && show_menu && return

    [ -f "${INSTALL_DIR}/euser_renew.py" ] && \
        cp ${INSTALL_DIR}/euser_renew.py \
           ${INSTALL_DIR}/euser_renew.py.bak.$(date +%Y%m%d_%H%M%S)

    if curl -fsSL https://raw.githubusercontent.com/dufei511/euserv_py/main/euser_renew.py \
           -o ${INSTALL_DIR}/euser_renew.py.new; then
        mv ${INSTALL_DIR}/euser_renew.py.new ${INSTALL_DIR}/euser_renew.py
        chmod +x ${INSTALL_DIR}/euser_renew.py
        print_success "脚本更新成功"
        curl -fsSL https://raw.githubusercontent.com/dufei511/euserv_py/main/requirements.txt \
            -o ${INSTALL_DIR}/requirements.txt 2>/dev/null && print_success "requirements.txt 更新成功"
        local mode=$(get_run_mode)
        local compose_cmd=$(get_compose_cmd)
        if [ "$mode" == "python" ]; then
            local py_path=$(get_python_path)
            ${py_path} -m pip install -q -r ${INSTALL_DIR}/requirements.txt \
            || ${py_path} -m pip install -q -r ${INSTALL_DIR}/requirements.txt --break-system-packages
        fi
        read -p "是否立即重启服务? (Y/n): " r
        if [[ $r != "n" && $r != "N" ]]; then
            if [ "$mode" == "docker" ]; then
                cd ${INSTALL_DIR}; ${compose_cmd} down; ${compose_cmd} build
                systemctl restart euserv-renew.timer
            else
                systemctl restart euserv-renew.timer
            fi
            print_success "服务已重启"
        fi
    else
        print_error "脚本下载失败"
    fi
    echo ""; read -p "按回车键返回菜单..."; show_menu
}

switch_mode() {
    echo ""
    echo "===== 切换运行模式 ====="
    local current_mode=$(get_run_mode)
    echo "当前模式: $current_mode"
    echo ""
    echo "1. Docker容器模式  2. 本地Python模式  3. 返回菜单"
    read -p "请选择 [1-3]: " mode_choice

    case $mode_choice in
        1)
            [ "$current_mode" == "docker" ] && echo "当前已是Docker模式" && sleep 2 && show_menu && return
            if ! command -v docker &>/dev/null; then
                curl -fsSL https://get.docker.com | bash; systemctl enable docker; systemctl start docker
            fi
            if ! docker compose version &>/dev/null && ! command -v docker-compose &>/dev/null; then
                curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
                    -o /usr/local/bin/docker-compose; chmod +x /usr/local/bin/docker-compose
            fi
            local compose_cmd=$(get_compose_cmd)
            systemctl stop euserv-renew.timer 2>/dev/null; systemctl stop euserv-renew.service 2>/dev/null
            local run_hour
            run_hour=$(grep "OnCalendar=" /etc/systemd/system/euserv-renew.timer 2>/dev/null \
                | sed 's/.*\*-\*-\* \([0-9]*\):00:00/\1/' || echo "3")
            mkdir -p ${INSTALL_DIR}/{logs,config,cookies}
            cd ${INSTALL_DIR}
            cat > Dockerfile <<'DOCKERFILE'
FROM python:3.12-slim
RUN mkdir -p /app && chmod 777 /app
WORKDIR /app
COPY requirements.txt /app/
RUN pip install --no-cache-dir -r requirements.txt
ENV TZ=Asia/Shanghai
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone
COPY euser_renew.py /app/
COPY config.env /app/
CMD ["python", "/app/euser_renew.py"]
DOCKERFILE
            cat > docker-compose.yml <<COMPOSE
services:
  euserv-renew:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: euserv-renew
    restart: "no"
    env_file:
      - config.env
    volumes:
      - ./logs:/app/logs
      - ./cookies:/app/cookies
      - ./config.env:/app/config.env:ro
      - ./euser_renew.py:/app/euser_renew.py:ro
    environment:
      - TZ=Asia/Shanghai
      - RUN_HOUR=${run_hour}
    security_opt:
      - no-new-privileges:true
    labels:
      - "euserv.schedule=${run_hour}"
COMPOSE
            ${compose_cmd} -f ${INSTALL_DIR}/docker-compose.yml build
            cat > /etc/systemd/system/euserv-renew.service <<SERVICE
[Unit]
Description=EUserv Auto Renew Service (Docker)
After=docker.service
Requires=docker.service
[Service]
Type=oneshot
WorkingDirectory=${INSTALL_DIR}
ExecStart=${compose_cmd} -f ${INSTALL_DIR}/docker-compose.yml run --rm euserv-renew
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
SERVICE
            systemctl daemon-reload; systemctl enable euserv-renew.timer; systemctl start euserv-renew.timer
            echo "docker" > ${MODE_FILE}; print_success "已切换到Docker模式"
            ;;
        2)
            [ "$current_mode" == "python" ] && echo "当前已是Python模式" && sleep 2 && show_menu && return
            local compose_cmd=$(get_compose_cmd)
            cd ${INSTALL_DIR}; ${compose_cmd} down -v 2>/dev/null
            if ! command -v ${PYTHON_BIN} &>/dev/null; then
                apt-get update -qq
                . /etc/os-release 2>/dev/null
                if apt-cache show ${PYTHON_BIN} &>/dev/null 2>&1; then
                    apt-get install -y ${PYTHON_BIN} python3-pip -qq
                elif [[ "${ID:-}" == "ubuntu" ]]; then
                    apt-get install -y software-properties-common -qq
                    add-apt-repository -y ppa:deadsnakes/ppa; apt-get update -qq
                    apt-get install -y ${PYTHON_BIN} -qq
                else
                    CODENAME=$(lsb_release -cs 2>/dev/null || echo "bookworm")
                    echo "deb http://deb.debian.org/debian ${CODENAME}-backports main" \
                        > /etc/apt/sources.list.d/backports.list
                    apt-get update -qq
                    apt-get install -y -t ${CODENAME}-backports ${PYTHON_BIN} || apt-get install -y ${PYTHON_BIN} -qq
                fi
            fi
            local py_path=$(command -v ${PYTHON_BIN})
            ${py_path} -m pip install -q -r ${INSTALL_DIR}/requirements.txt \
            || ${py_path} -m pip install -q -r ${INSTALL_DIR}/requirements.txt --break-system-packages
            local run_hour
            run_hour=$(grep "OnCalendar=" /etc/systemd/system/euserv-renew.timer 2>/dev/null \
                | sed 's/.*\*-\*-\* \([0-9]*\):00:00/\1/' || echo "3")
            cat > /etc/systemd/system/euserv-renew.service <<SERVICE
[Unit]
Description=EUserv Auto Renew Service (Python 3.12)
After=network.target
[Service]
Type=oneshot
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${CONFIG_FILE}
ExecStart=${py_path} ${INSTALL_DIR}/euser_renew.py
StandardOutput=journal
StandardError=journal
User=root
[Install]
WantedBy=multi-user.target
SERVICE
            systemctl daemon-reload; systemctl enable euserv-renew.timer; systemctl start euserv-renew.timer
            echo "python" > ${MODE_FILE}; print_success "已切换到Python模式"
            read -p "是否立即测试运行? (Y/n): " t
            if [[ $t != "n" && $t != "N" ]]; then
                systemctl start euserv-renew.service; sleep 2
                journalctl -u euserv-renew.service -n 20 --no-pager
            fi
            ;;
        3) show_menu; return ;;
        *) echo "无效选择"; sleep 2; switch_mode; return ;;
    esac
    echo ""; read -p "按回车键返回菜单..."; show_menu
}

uninstall() {
    echo ""
    read -p "确定要卸载? (y/N): " confirm
    if [[ $confirm == "y" || $confirm == "Y" ]]; then
        local compose_cmd=$(get_compose_cmd)
        systemctl stop euserv-renew.timer 2>/dev/null
        systemctl disable euserv-renew.timer 2>/dev/null
        systemctl stop euserv-renew.service 2>/dev/null
        [ -f "${INSTALL_DIR}/docker-compose.yml" ] && cd ${INSTALL_DIR} && ${compose_cmd} down -v 2>/dev/null
        rm -f /etc/systemd/system/euserv-renew.{service,timer}
        systemctl daemon-reload
        rm -rf ${INSTALL_DIR}
        rm -f /usr/local/bin/dj
        echo "卸载完成!"; exit 0
    else
        show_menu
    fi
}

show_menu
SCRIPT_EOF

    chmod +x ${COMMAND_LINK}
    print_success "快捷命令创建完成 (使用 'dj' 命令打开管理面板)"
}

choose_run_mode() {
    echo "" >&2
    print_info "请选择运行模式:" >&2
    echo "1. Docker容器模式 (推荐 2GB+ 内存VPS)" >&2
    echo "2. 本地Python模式 (推荐 512MB-1GB 内存VPS)" >&2
    echo "" >&2
    read -p "请选择运行模式 [1/2]: " mode_choice
    case $mode_choice in
        1) echo "docker" ;;
        2) echo "python" ;;
        *) print_warning "无效选择，默认Python模式" >&2; echo "python" ;;
    esac
}

install() {
    print_info "开始安装EUserv自动续期服务 V2.2..."
    echo ""

    if [ -d "${INSTALL_DIR}" ] || [ -f "${COMMAND_LINK}" ] || \
       systemctl list-unit-files 2>/dev/null | grep -q "euserv-renew"; then
        print_warning "检测到已安装的组件，如需重新安装请先运行 dj 选择卸载"
        read -p "是否强制重新安装? (y/N): " force
        [[ "$force" != "y" && "$force" != "Y" ]] && exit 0
    fi

    check_root
    create_directories
    download_scripts

    run_mode=$(choose_run_mode)
    set_run_mode "$run_mode"

    configure_env

    echo ""
    read -p "请输入每天执行续期的时间(0-23，默认3): " run_hour
    run_hour=${run_hour:-3}
    if ! [[ $run_hour =~ ^[0-9]+$ ]] || [ $run_hour -lt 0 ] || [ $run_hour -gt 23 ]; then
        print_warning "无效时间，使用默认值 3"; run_hour=3
    fi

    if [ "$run_mode" == "docker" ]; then
        install_docker
        create_dockerfile
        create_docker_compose "$run_hour"
        setup_docker_cron "$run_hour"
    else
        install_python
        setup_python_cron "$run_hour"
    fi

    create_command

    echo ""
    print_success "======================================"
    print_success " EUserv 自动续期服务安装完成 V2.2"
    print_success "======================================"
    echo " 运行模式: $(get_run_mode)"
    echo " 执行时间: 每天 ${run_hour}:00"
    echo " 快捷命令: dj"
    echo ""
    read -p "是否立即测试运行? (y/N): " test_now
    if [[ $test_now == "y" || $test_now == "Y" ]]; then
        if [ "$run_mode" == "docker" ]; then
            local compose_cmd
            compose_cmd=$(get_compose_cmd)
            cd ${INSTALL_DIR} && ${compose_cmd} run --rm euserv-renew
        else
            systemctl start euserv-renew.service
            sleep 3
            journalctl -u euserv-renew.service -n 30 --no-pager
        fi
    fi
}

install