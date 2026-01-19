#!/bin/bash

# EUserv 自动续期一键部署脚本 V2.0
# 支持 Docker 和本地 Python 两种运行模式，可自由切换

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置文件路径
INSTALL_DIR="/opt/euserv_renew"
CONFIG_FILE="${INSTALL_DIR}/config.env"
SERVICE_NAME="euserv-renew"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
COMMAND_LINK="/usr/local/bin/dj"
MODE_FILE="${INSTALL_DIR}/.run_mode"
GITHUB_REPO="https://raw.githubusercontent.com/dufei511/euserv_py/dev"

# 打印带颜色的信息
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本必须以root权限运行"
        exit 1
    fi
}

# 获取当前运行模式
get_run_mode() {
    if [ -f "${MODE_FILE}" ]; then
        cat ${MODE_FILE}
    else
        echo "none"
    fi
}

# 设置运行模式
set_run_mode() {
    echo "$1" > ${MODE_FILE}
}

# 创建项目目录
create_directories() {
    print_info "创建项目目录..."
    mkdir -p ${INSTALL_DIR}/{logs,config}
    print_success "目录创建完成"
}

# 下载脚本和依赖文件
download_scripts() {
    print_info "下载EUserv续期脚本和依赖文件..."
    
    # 下载主脚本
    if curl -fsSL ${GITHUB_REPO}/euser_renew.py -o ${INSTALL_DIR}/euser_renew.py; then
        chmod +x ${INSTALL_DIR}/euser_renew.py
        print_success "主脚本下载成功"
    else
        print_error "主脚本下载失败,请检查网络连接或GitHub是否可访问"
        exit 1
    fi
    
    # 下载 requirements.txt
    if curl -fsSL ${GITHUB_REPO}/requirements.txt -o ${INSTALL_DIR}/requirements.txt; then
        print_success "requirements.txt 下载成功"
    else
        print_warning "requirements.txt 下载失败，将使用默认依赖列表"
        # 创建默认的 requirements.txt
        cat > ${INSTALL_DIR}/requirements.txt <<'EOF'
requests
beautifulsoup4
lxml
python-dotenv
EOF
    fi
}

# 配置环境变量
configure_env() {
    print_info "配置环境变量..."
    echo ""
    
    # 必填项
    print_info "=== 必填项 ==="
    read -p "请输入EUserv账号邮箱: " email
    read -sp "请输入EUserv账号密码: " password
    echo ""
    read -sp "请输入邮箱应用专用密码(EMAIL_PASS): " email_pass
    echo ""
    echo ""
    
    # 可选项
    print_info "=== 可选项(推送通知配置，不需要可直接回车跳过) ==="
    read -p "Telegram Bot Token (可选): " tg_bot_token
    read -p "Telegram Chat ID (可选): " tg_chat_id
    read -p "Bark推送URL (可选): " bark_url
    echo ""
    
    # 生成配置文件
    cat > ${CONFIG_FILE} <<EOF
# EUserv账号配置(必填)
EUSERV_EMAIL=${email}
EUSERV_PASSWORD=${password}
EMAIL_PASS=${email_pass}

# Telegram推送配置(可选)
EOF

    # 只有填写了才添加到配置文件
    if [ -n "$tg_bot_token" ]; then
        echo "TG_BOT_TOKEN=${tg_bot_token}" >> ${CONFIG_FILE}
    fi
    
    if [ -n "$tg_chat_id" ]; then
        echo "TG_CHAT_ID=${tg_chat_id}" >> ${CONFIG_FILE}
    fi
    
    if [ -n "$bark_url" ]; then
        echo "BARK_URL=${bark_url}" >> ${CONFIG_FILE}
    fi
    
    chmod 600 ${CONFIG_FILE}
    print_success "环境变量配置完成"
}

# 创建Dockerfile
create_dockerfile() {
    print_info "创建Dockerfile..."
    cat > ${INSTALL_DIR}/Dockerfile <<'EOF'
FROM python:3.9-slim

# 设置工作目录
RUN mkdir -p /app && chmod 777 /app
WORKDIR /app

# 复制依赖文件
COPY requirements.txt /app/

# 安装依赖
RUN pip install --no-cache-dir -r requirements.txt

# 设置时区
ENV TZ=Asia/Shanghai
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# 复制脚本和配置
COPY euser_renew.py /app/
COPY config.env /app/

CMD ["python", "/app/euser_renew.py"]
EOF
    print_success "Dockerfile创建完成"
}

# 创建docker-compose.yml
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
    restart: unless-stopped
    env_file:
      - config.env
    volumes:
      - ./logs:/app/logs
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

# 安装Docker环境
install_docker() {
    print_info "安装Docker环境..."
    
    # 检查Docker是否安装
    if ! command -v docker &> /dev/null; then
        print_info "Docker未安装,正在安装..."
        curl -fsSL https://get.docker.com | bash
        systemctl enable docker
        systemctl start docker
        print_success "Docker安装完成"
    else
        print_success "Docker已安装"
    fi
    
    # 检查docker-compose是否安装
    if ! command -v docker-compose &> /dev/null; then
        print_info "Docker Compose未安装,正在安装..."
        curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
        print_success "Docker Compose安装完成"
    else
        print_success "Docker Compose已安装"
    fi
}

# 安装Python环境
install_python() {
    print_info "安装Python环境..."
    
    # 检查Python3
    if ! command -v python3 &> /dev/null; then
        print_info "Python3未安装,正在安装..."
        apt-get update -qq
        apt-get install -y python3 -qq
        print_success "Python3安装完成"
    else
        print_success "Python3已安装"
    fi
    
    # 检查pip3
    if ! command -v pip3 &> /dev/null; then
        print_info "pip3未安装,正在安装..."
        apt-get update -qq
        apt-get install -y python3-pip -qq
        print_success "pip3安装完成"
    else
        print_success "pip3已安装"
    fi
    
    # 安装Python依赖
    print_info "从requirements.txt安装Python依赖..."
    if [ -f "${INSTALL_DIR}/requirements.txt" ]; then
        pip3 install --quiet -r ${INSTALL_DIR}/requirements.txt 2>/dev/null || \
        pip3 install -r ${INSTALL_DIR}/requirements.txt
        print_success "Python依赖安装完成"
    else
        print_error "requirements.txt 文件不存在"
        exit 1
    fi
}

# 创建systemd定时器（Docker模式）
setup_docker_cron() {
    local run_hour=$1
    
    print_info "设置Docker模式定时任务(每天${run_hour}点执行)..."
    
    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=EUserv Auto Renew Service (Docker)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/local/bin/docker-compose -f ${COMPOSE_FILE} up --build
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
    
    print_success "Docker模式定时任务设置完成"
}

# 创建systemd定时器（Python模式）
setup_python_cron() {
    local run_hour=$1
    
    print_info "设置Python模式定时任务(每天${run_hour}点执行)..."
    
    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=EUserv Auto Renew Service (Python)
After=network.target

[Service]
Type=oneshot
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${CONFIG_FILE}
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/euser_renew.py
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
    
    print_success "Python模式定时任务设置完成"
}

# 创建快捷命令
create_command() {
    print_info "创建快捷命令..."
    
    cat > ${COMMAND_LINK} <<'EOF'
#!/bin/bash

INSTALL_DIR="/opt/euserv_renew"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
MODE_FILE="${INSTALL_DIR}/.run_mode"
CONFIG_FILE="${INSTALL_DIR}/config.env"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# 获取当前运行模式
get_run_mode() {
    if [ -f "${MODE_FILE}" ]; then
        cat ${MODE_FILE}
    else
        echo "unknown"
    fi
}

show_menu() {
    clear
    local mode=$(get_run_mode)
    local mode_display="未知"
    case $mode in
        docker) mode_display="Docker容器" ;;
        python) mode_display="本地Python" ;;
        *) mode_display="未配置" ;;
    esac
    
    echo "======================================"
    echo "    EUserv 自动续期管理面板"
    echo "======================================"
    echo "当前运行模式: ${mode_display}"
    echo "======================================"
    echo "1. 查看服务状态"
    echo "2. 查看日志"
    echo "3. 立即执行续期"
    echo "4. 重启服务"
    echo "5. 修改执行时间"
    echo "6. 修改账号配置"
    echo "7. 更新续期脚本"
    echo "8. 切换运行模式"
    echo "9. 卸载服务"
    echo "0. 退出"
    echo "======================================"
    read -p "请选择操作 [0-9]: " choice
    
    case $choice in
        1) show_status ;;
        2) show_logs ;;
        3) run_now ;;
        4) restart_service ;;
        5) change_schedule ;;
        6) change_config ;;
        7) update_script ;;
        8) switch_mode ;;
        9) uninstall ;;
        0) exit 0 ;;
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
    
    if [ "$mode" == "docker" ]; then
        echo "===== 立即执行续期任务 (Docker模式) ====="
        cd ${INSTALL_DIR}
        docker-compose up --build
    elif [ "$mode" == "python" ]; then
        echo "===== 立即执行续期任务 (Python模式) ====="
        systemctl start euserv-renew.service
        sleep 2
        echo ""
        echo "===== 执行日志 ====="
        journalctl -u euserv-renew.service -n 50 --no-pager
    else
        echo "未知的运行模式，请重新配置"
    fi
    
    read -p "按回车键返回菜单..." 
    show_menu
}

restart_service() {
    echo ""
    echo "===== 重启服务 ====="
    
    local mode=$(get_run_mode)
    if [ "$mode" == "docker" ]; then
        cd ${INSTALL_DIR}
        docker-compose down
        docker-compose up -d --build
        echo "✓ Docker服务已重启"
    elif [ "$mode" == "python" ]; then
        systemctl restart euserv-renew.timer
        echo "✓ Python定时服务已重启"
    fi
    
    sleep 2
    show_menu
}

change_schedule() {
    echo ""
    read -p "请输入新的执行时间(0-23): " new_hour
    
    if [[ $new_hour =~ ^[0-9]+$ ]] && [ $new_hour -ge 0 ] && [ $new_hour -le 23 ]; then
        sed -i "s/OnCalendar=\*-\*-\* [0-9]\{1,2\}:00:00/OnCalendar=*-*-* ${new_hour}:00:00/" /etc/systemd/system/euserv-renew.timer
        systemctl daemon-reload
        systemctl restart euserv-renew.timer
        echo "执行时间已修改为每天 ${new_hour}:00"
    else
        echo "无效的时间,请输入0-23之间的数字"
    fi
    
    sleep 2
    show_menu
}

change_config() {
    echo ""
    echo "===== 修改账号配置 ====="
    echo ""
    
    print_info "=== 必填项 ==="
    read -p "请输入EUserv账号邮箱: " email
    read -sp "请输入EUserv账号密码: " password
    echo ""
    read -sp "请输入邮箱应用专用密码(EMAIL_PASS): " email_pass
    echo ""
    echo ""
    
    print_info "=== 可选项(推送通知配置，不需要可直接回车跳过) ==="
    read -p "Telegram Bot Token (可选): " tg_bot_token
    read -p "Telegram Chat ID (可选): " tg_chat_id
    read -p "Bark推送URL (可选): " bark_url
    echo ""
    
    cat > ${CONFIG_FILE} <<EOL
# EUserv账号配置(必填)
EUSERV_EMAIL=${email}
EUSERV_PASSWORD=${password}
EMAIL_PASS=${email_pass}

# Telegram推送配置(可选)
EOL

    if [ -n "$tg_bot_token" ]; then
        echo "TG_BOT_TOKEN=${tg_bot_token}" >> ${CONFIG_FILE}
    fi
    
    if [ -n "$tg_chat_id" ]; then
        echo "TG_CHAT_ID=${tg_chat_id}" >> ${CONFIG_FILE}
    fi
    
    if [ -n "$bark_url" ]; then
        echo "BARK_URL=${bark_url}" >> ${CONFIG_FILE}
    fi
    
    chmod 600 ${CONFIG_FILE}
    echo "配置已更新"
    sleep 2
    show_menu
}

update_script() {
    echo ""
    echo "===== 更新续期脚本 ====="
    echo ""
    
    if [ -f "${INSTALL_DIR}/euser_renew.py" ]; then
        echo "当前脚本修改时间: $(stat -c %y ${INSTALL_DIR}/euser_renew.py 2>/dev/null || stat -f %Sm ${INSTALL_DIR}/euser_renew.py 2>/dev/null)"
    fi
    echo ""
    
    read -p "确定要从GitHub更新脚本吗? (y/N): " confirm
    
    if [[ $confirm == "y" || $confirm == "Y" ]]; then
        echo "正在备份当前脚本..."
        if [ -f "${INSTALL_DIR}/euser_renew.py" ]; then
            cp ${INSTALL_DIR}/euser_renew.py ${INSTALL_DIR}/euser_renew.py.bak.$(date +%Y%m%d_%H%M%S)
        fi
        
        echo "正在下载最新脚本..."
        if curl -fsSL https://raw.githubusercontent.com/dufei511/euserv_py/dev/euser_renew.py -o ${INSTALL_DIR}/euser_renew.py.new; then
            mv ${INSTALL_DIR}/euser_renew.py.new ${INSTALL_DIR}/euser_renew.py
            chmod +x ${INSTALL_DIR}/euser_renew.py
            echo ""
            print_success "脚本更新成功!"
            
            # 同时更新 requirements.txt
            if curl -fsSL https://raw.githubusercontent.com/dufei511/euserv_py/dev/requirements.txt -o ${INSTALL_DIR}/requirements.txt.new; then
                mv ${INSTALL_DIR}/requirements.txt.new ${INSTALL_DIR}/requirements.txt
                print_success "requirements.txt 更新成功!"
                
                # 如果是Python模式，重新安装依赖
                local mode=$(get_run_mode)
                if [ "$mode" == "python" ]; then
                    echo "正在更新Python依赖..."
                    pip3 install --quiet -r ${INSTALL_DIR}/requirements.txt 2>/dev/null || \
                    pip3 install -r ${INSTALL_DIR}/requirements.txt
                    print_success "依赖更新完成"
                fi
            fi
            
            echo ""
            read -p "是否立即重启服务以应用更新? (Y/n): " restart_confirm
            if [[ $restart_confirm != "n" && $restart_confirm != "N" ]]; then
                local mode=$(get_run_mode)
                if [ "$mode" == "docker" ]; then
                    cd ${INSTALL_DIR}
                    docker-compose down
                    docker-compose up --build -d
                elif [ "$mode" == "python" ]; then
                    systemctl restart euserv-renew.timer
                fi
                print_success "服务已重启，更新已生效"
            fi
        else
            echo "✗ 脚本下载失败"
        fi
    else
        echo "取消更新"
    fi
    
    echo ""
    read -p "按回车键返回菜单..." 
    show_menu
}

switch_mode() {
    echo ""
    echo "===== 切换运行模式 ====="
    echo ""
    
    local current_mode=$(get_run_mode)
    echo "当前模式: $current_mode"
    echo ""
    echo "可选模式:"
    echo "1. Docker容器模式 (隔离环境，推荐配置较高的VPS)"
    echo "2. 本地Python模式 (直接运行，推荐配置较低的VPS)"
    echo "3. 返回菜单"
    echo ""
    read -p "请选择要切换的模式 [1-3]: " mode_choice
    
    case $mode_choice in
        1)
            if [ "$current_mode" == "docker" ]; then
                echo "当前已是Docker模式"
                sleep 2
                show_menu
                return
            fi
            
            echo ""
            echo "正在切换到Docker模式..."
            
            # 检查Docker
            if ! command -v docker &> /dev/null; then
                echo "Docker未安装，正在安装..."
                curl -fsSL https://get.docker.com | bash
                systemctl enable docker
                systemctl start docker
            fi
            
            if ! command -v docker-compose &> /dev/null; then
                echo "Docker Compose未安装，正在安装..."
                curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
                chmod +x /usr/local/bin/docker-compose
            fi
            
            # 停止Python模式服务
            systemctl stop euserv-renew.timer 2>/dev/null
            systemctl stop euserv-renew.service 2>/dev/null
            
            # 获取当前执行时间
            local run_hour=$(grep "OnCalendar=" /etc/systemd/system/euserv-renew.timer 2>/dev/null | sed 's/.*\*-\*-\* \([0-9]*\):00:00/\1/' || echo "3")
            
            # 创建Docker配置
            cd ${INSTALL_DIR}
            
            # 创建Dockerfile
            cat > Dockerfile <<'DOCKERFILE'
FROM python:3.9-slim

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

            # 创建docker-compose.yml
            cat > docker-compose.yml <<COMPOSE
services:
  euserv-renew:
    build: 
      context: .
      dockerfile: Dockerfile
    container_name: euserv-renew
    restart: unless-stopped
    env_file:
      - config.env
    volumes:
      - ./logs:/app/logs
      - ./config.env:/app/config.env:ro
      - ./euser_renew.py:/app/euser_renew.py:ro
    environment:
      - TZ=Asia/Shanghai
    security_opt:
      - no-new-privileges:true
COMPOSE

            # 更新systemd服务
            cat > /etc/systemd/system/euserv-renew.service <<SERVICE
[Unit]
Description=EUserv Auto Renew Service (Docker)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/local/bin/docker-compose -f ${INSTALL_DIR}/docker-compose.yml up --build
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE

            systemctl daemon-reload
            systemctl enable euserv-renew.timer
            systemctl start euserv-renew.timer
            
            echo "docker" > ${MODE_FILE}
            print_success "已切换到Docker模式"
            ;;
            
        2)
            if [ "$current_mode" == "python" ]; then
                echo "当前已是Python模式"
                sleep 2
                show_menu
                return
            fi
            
            echo ""
            echo "正在切换到Python模式..."
            
            # 停止Docker容器
            cd ${INSTALL_DIR}
            docker-compose down -v 2>/dev/null
            
            # 检查Python和pip
            if ! command -v python3 &> /dev/null; then
                echo "安装Python3..."
                apt-get update -qq
                apt-get install -y python3 -qq
            fi
            
            if ! command -v pip3 &> /dev/null; then
                echo "安装pip3..."
                apt-get update -qq
                apt-get install -y python3-pip -qq
            fi
            
            # 安装依赖
            echo "安装Python依赖..."
            pip3 install --quiet -r ${INSTALL_DIR}/requirements.txt 2>/dev/null || \
            pip3 install -r ${INSTALL_DIR}/requirements.txt
            
            # 获取当前执行时间
            local run_hour=$(grep "OnCalendar=" /etc/systemd/system/euserv-renew.timer 2>/dev/null | sed 's/.*\*-\*-\* \([0-9]*\):00:00/\1/' || echo "3")
            
            # 更新systemd服务
            cat > /etc/systemd/system/euserv-renew.service <<SERVICE
[Unit]
Description=EUserv Auto Renew Service (Python)
After=network.target

[Service]
Type=oneshot
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${CONFIG_FILE}
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/euser_renew.py
StandardOutput=journal
StandardError=journal
User=root

[Install]
WantedBy=multi-user.target
SERVICE

            systemctl daemon-reload
            systemctl enable euserv-renew.timer
            systemctl start euserv-renew.timer
            
            echo "python" > ${MODE_FILE}
            print_success "已切换到Python模式"
            
            # 测试运行
            read -p "是否立即测试运行? (Y/n): " test_run
            if [[ $test_run != "n" && $test_run != "N" ]]; then
                echo ""
                systemctl start euserv-renew.service
                sleep 2
                journalctl -u euserv-renew.service -n 20 --no-pager
            fi
            ;;
            
        3)
            show_menu
            return
            ;;
            
        *)
            echo "无效选择"
            sleep 2
            switch_mode
            return
            ;;
    esac
    
    echo ""
    read -p "按回车键返回菜单..." 
    show_menu
}

uninstall() {
    echo ""
    read -p "确定要卸载EUserv自动续期服务吗? (y/N): " confirm
    
    if [[ $confirm == "y" || $confirm == "Y" ]]; then
        echo "正在卸载..."
        
        # 停止服务
        systemctl stop euserv-renew.timer 2>/dev/null
        systemctl disable euserv-renew.timer 2>/dev/null
        systemctl stop euserv-renew.service 2>/dev/null
        
        # 停止Docker容器
        if [ -d "${INSTALL_DIR}" ] && [ -f "${INSTALL_DIR}/docker-compose.yml" ]; then
            cd ${INSTALL_DIR}
            docker-compose down -v 2>/dev/null
        fi
        
        # 删除服务文件
        rm -f /etc/systemd/system/euserv-renew.service
        rm -f /etc/systemd/system/euserv-renew.timer
        systemctl daemon-reload
        
        # 删除安装目录
        rm -rf ${INSTALL_DIR}
        
        echo "卸载完成!"
        exit 0
    else
        show_menu
    fi
}

show_menu
EOF
    
    chmod +x ${COMMAND_LINK}
    print_success "快捷命令创建完成 (使用 'dj' 命令打开管理面板)"
}

# 选择运行模式
choose_run_mode() {
    echo ""
    print_info "请选择运行模式:"
    echo ""
    echo "1. Docker容器模式"
    echo "   优点: 环境隔离，依赖管理方便"
    echo "   缺点: 需要一定的磁盘空间和资源"
    echo "   推荐: 配置较高的VPS (2GB+ 内存)"
    echo ""
    echo "2. 本地Python模式"
    echo "   优点: 资源占用少，启动快"
    echo "   缺点: 依赖直接安装在系统上"
    echo "   推荐: 配置较低的VPS (512MB-1GB 内存)"
    echo ""
    read -p "请选择运行模式 [1/2]: " mode_choice
    
    case $mode_choice in
        1)
            echo "docker"
            ;;
        2)
            echo "python"
            ;;
        *)
            print_warning "无效选择，默认使用Python模式"
            echo "python"
            ;;
    esac
}

# 安装主函数
install() {
    print_info "开始安装EUserv自动续期服务..."
    echo ""
    
    # 检查是否已安装
    if [ -d "${INSTALL_DIR}" ] || [ -f "${COMMAND_LINK}" ] || systemctl list-unit-files | grep -q "euserv-renew"; then
        print_warning "检测到已安装的组件:"
        [ -d "${INSTALL_DIR}" ] && echo "  - 安装目录: ${INSTALL_DIR}"
        [ -f "${COMMAND_LINK}" ] && echo "  - 快捷命令: ${COMMAND_LINK}"
        systemctl list-unit-files | grep -q "euserv-renew" && echo "  - 系统服务: euserv-renew"
        echo ""
        read -p "是否先卸载后重新安装? (y/N): " reinstall
        if [[ $reinstall =~ ^[Yy]$ ]]; then
            uninstall_service
            echo ""
            print_info "继续安装..."
        else
            print_info "取消安装"
            exit 0
        fi
    fi
    
    # 执行基础安装步骤
    check_root
    create_directories
    download_scripts
    configure_env
    
    # 设置执行时间
    read -p "请输入每天执行的小时数(0-23,默认3点): " run_hour
    run_hour=${run_hour:-3}
    
    if ! [[ $run_hour =~ ^[0-9]+$ ]] || [ $run_hour -lt 0 ] || [ $run_hour -gt 23 ]; then
        print_warning "无效的小时数,使用默认值3"
        run_hour=3
    fi
    
    # 选择运行模式
    run_mode=$(choose_run_mode)
    
    echo ""
    print_info "正在配置 ${run_mode} 模式..."
    
    if [ "$run_mode" == "docker" ]; then
        install_docker
        create_dockerfile
        create_docker_compose $run_hour
        setup_docker_cron $run_hour
        set_run_mode "docker"
    else
        install_python
        setup_python_cron $run_hour
        set_run_mode "python"
    fi
    
    create_command
    
    echo ""
    print_success "========================================="
    print_success "EUserv自动续期服务安装完成!"
    print_success "========================================="
    print_info "运行模式: ${run_mode}"
    print_info "服务将在每天 ${run_hour}:00 自动执行"
    print_info "使用以下命令管理服务:"
    print_info "  dj                - 打开管理面板"
    print_info "  systemctl status euserv-renew.timer - 查看定时器状态"
    print_success "========================================="
    echo ""
    
    if [ "$run_mode" == "python" ]; then
        read -p "是否立即测试运行? (Y/n): " test_now
        if [[ $test_now != "n" && $test_now != "N" ]]; then
            systemctl start euserv-renew.service
            sleep 2
            journalctl -u euserv-renew.service -n 30 --no-pager
        fi
    fi
}

# 卸载函数
uninstall_service() {
    print_info "开始卸载EUserv自动续期服务..."
    
    # 停止并禁用服务
    if systemctl list-unit-files | grep -q "euserv-renew.timer"; then
        systemctl stop euserv-renew.timer 2>/dev/null
        systemctl disable euserv-renew.timer 2>/dev/null
        print_info "已停止定时器服务"
    fi
    
    if systemctl list-unit-files | grep -q "euserv-renew.service"; then
        systemctl stop euserv-renew.service 2>/dev/null
        systemctl disable euserv-renew.service 2>/dev/null
        print_info "已停止执行服务"
    fi
    
    # 停止Docker容器
    if [ -d "${INSTALL_DIR}" ] && [ -f "${INSTALL_DIR}/docker-compose.yml" ]; then
        cd ${INSTALL_DIR}
        docker-compose down -v 2>/dev/null
        print_info "已停止Docker容器"
    fi
    
    # 删除服务文件
    if [ -f /etc/systemd/system/euserv-renew.service ]; then
        rm -f /etc/systemd/system/euserv-renew.service
        print_info "已删除服务文件"
    fi
    
    if [ -f /etc/systemd/system/euserv-renew.timer ]; then
        rm -f /etc/systemd/system/euserv-renew.timer
        print_info "已删除定时器文件"
    fi
    
    systemctl daemon-reload
    
    # 删除安装目录
    if [ -d "${INSTALL_DIR}" ]; then
        rm -rf ${INSTALL_DIR}
        print_info "已删除安装目录"
    fi
    
    # 删除快捷命令
    if [ -f ${COMMAND_LINK} ]; then
        rm -f ${COMMAND_LINK}
        print_info "已删除快捷命令"
    fi
    
    print_success "卸载完成!"
}

# 显示帮助信息
show_help() {
    echo "EUserv 自动续期一键部署脚本 V2.0"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  install     安装服务"
    echo "  uninstall   卸载服务"
    echo "  help        显示此帮助信息"
    echo ""
}

# 主函数
main() {
    case "${1:-install}" in
        install)
            install
            ;;
        uninstall)
            check_root
            uninstall_service
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_error "未知选项: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"