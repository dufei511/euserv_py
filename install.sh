#!/bin/bash

# EUserv 自动续期一键部署脚本
# 支持安装、配置、卸载功能

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

# 检查并安装依赖
install_dependencies() {
    print_info "检查并安装必要依赖..."
    
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

# 创建项目目录
create_directories() {
    print_info "创建项目目录..."
    mkdir -p ${INSTALL_DIR}/{logs,config}
    print_success "目录创建完成"
}

# 创建Dockerfile
create_dockerfile() {
    print_info "创建Dockerfile..."
    cat > ${INSTALL_DIR}/Dockerfile <<'EOF'
FROM python:3.9-slim

# 设置工作目录（避免权限问题）
RUN mkdir -p /app && chmod 777 /app
WORKDIR /app

# 安装依赖
RUN pip install --no-cache-dir requests beautifulsoup4 lxml

# 设置时区
ENV TZ=Asia/Shanghai
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# 复制脚本
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

# 下载脚本
download_script() {
    print_info "下载EUserv续期脚本..."
    
    # 从GitHub下载脚本
    if curl -fsSL https://raw.githubusercontent.com/dufei511/euserv_py/dev/euser_renew.py -o ${INSTALL_DIR}/euser_renew.py; then
        chmod +x ${INSTALL_DIR}/euser_renew.py
        print_success "脚本下载成功"
    else
        print_error "脚本下载失败,请检查网络连接或GitHub是否可访问"
        exit 1
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

# 创建cron任务
setup_cron() {
    local run_hour=$1
    
    print_info "设置定时任务(每天${run_hour}点执行)..."
    
    # 创建systemd timer
    cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=EUserv Auto Renew Service
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
    
    print_success "定时任务设置完成"
}

# 创建快捷命令
create_command() {
    print_info "创建快捷命令..."
    
    cat > ${COMMAND_LINK} <<'EOF'
#!/bin/bash

INSTALL_DIR="/opt/euserv_renew"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"

show_menu() {
    clear
    echo "======================================"
    echo "    EUserv 自动续期管理面板"
    echo "======================================"
    echo "1. 查看服务状态"
    echo "2. 查看日志"
    echo "3. 立即执行续期"
    echo "4. 重启服务"
    echo "5. 修改执行时间"
    echo "6. 修改账号配置"
    echo "7. 更新续期脚本"
    echo "8. 修复Docker权限问题"
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
        8) fix_docker_permission ;;
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
    
    # 检查运行模式
    if [ -f "${INSTALL_DIR}/.no_docker" ]; then
        # 直接运行模式
        echo "===== 立即执行续期任务 (直接运行模式) ====="
        systemctl start euserv-renew.service
        sleep 2
        echo ""
        echo "===== 执行日志 ====="
        journalctl -u euserv-renew.service -n 50 --no-pager
    else
        # Docker模式
        echo "===== 立即执行续期任务 (Docker模式) ====="
        echo ""
        echo "⚠️  检测到正在使用Docker模式"
        echo ""
        
        # 先尝试运行
        cd ${INSTALL_DIR}
        if ! docker-compose up --build 2>&1 | tee /tmp/docker_run.log | grep -q "disk quota exceeded\|operation not permitted"; then
            # 成功运行
            read -p "按回车键返回菜单..." 
            show_menu
            return
        fi
        
        # 检测到错误
        echo ""
        echo "❌ Docker运行失败！"
        echo ""
        echo "错误原因: VPS磁盘配额/inode不足，不支持Docker"
        echo ""
        echo "解决方案:"
        echo "1. 立即切换到直接运行模式 (推荐)"
        echo "2. 返回菜单手动修复"
        echo ""
        read -p "请选择 [1-2]: " auto_fix
        
        if [[ $auto_fix == "1" ]]; then
            echo ""
            echo "正在自动切换到直接运行模式..."
            auto_switch_to_direct_mode
        fi
    fi
    
    read -p "按回车键返回菜单..." 
    show_menu
}

auto_switch_to_direct_mode() {
    echo ""
    echo "===== 自动切换到直接运行模式 ====="
    echo ""
    
    # 停止并清理Docker容器
    cd ${INSTALL_DIR}
    docker-compose down -v 2>/dev/null
    echo "✓ 已停止Docker容器"
    
    # 检查Python
    if ! command -v python3 &> /dev/null; then
        echo "安装Python3..."
        apt-get update -qq
        apt-get install -y python3 python3-pip -qq
    fi
    
    # 安装Python依赖
    echo "安装Python依赖库..."
    # 检查并安装 python3-pip（Debian/Ubuntu 系）
    if ! command -v pip3 &> /dev/null; then
        echo "[INFO] pip3 未找到，正在安装 python3-pip..."
        apt update -qq
        apt install -y python3-pip python3-venv
    fi

    # 验证 pip3 路径并加到 PATH（防 /usr/local/bin/pip3 不在 PATH）
    PIP3_PATH=$(which pip3 || echo "")
    if [ -z "$PIP3_PATH" ]; then
        echo "[ERROR] 安装 pip3 失败，请手动检查 apt"
        exit 1
    fi
    export PATH=$PATH:/usr/local/bin:/usr/bin
    echo 'export PATH=$PATH:/usr/local/bin:/usr/bin' >> /etc/profile.d/pip.sh  # 永久加 PATH

    pip3 install --quiet requests beautifulsoup4 lxml Pillow python-dotenv ddddocr imap-tools 2>/dev/null || \
    pip3 install requests beautifulsoup4 lxml Pillow python-dotenv ddddocr imap-tools
    
    echo "✓ Python依赖安装完成"
    
    # 修改systemd服务为直接运行
    echo "配置系统服务..."
    cat > /etc/systemd/system/euserv-renew.service <<'SVCEOF'
[Unit]
Description=EUserv Auto Renew Service
After=network.target

[Service]
Type=oneshot
WorkingDirectory=/opt/euserv_renew
EnvironmentFile=/opt/euserv_renew/config.env
ExecStart=/usr/bin/python3 /opt/euserv_renew/euser_renew.py
StandardOutput=journal
StandardError=journal
User=root

[Install]
WantedBy=multi-user.target
SVCEOF
    
    systemctl daemon-reload
    systemctl enable euserv-renew.service
    
    # 标记为直接运行模式
    touch ${INSTALL_DIR}/.no_docker
    
    echo "✓ 已切换为直接运行模式"
    echo ""
    
    # 立即测试运行
    echo "===== 测试运行 ====="
    systemctl start euserv-renew.service
    sleep 2
    echo ""
    journalctl -u euserv-renew.service -n 30 --no-pager
    echo ""
    echo "✓ 切换完成！"
}

restart_service() {
    echo ""
    echo "===== 重启服务 ====="
    
    # 检查是否使用Docker模式
    if [ -f "${INSTALL_DIR}/docker-compose.yml" ] && docker ps &> /dev/null; then
        # Docker模式
        cd ${INSTALL_DIR}
        docker-compose down
        docker-compose up -d --build
        echo "✓ Docker服务已重启"
    else
        # 直接运行模式
        systemctl restart euserv-renew.timer
        echo "✓ 定时服务已重启"
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
    cat > ${INSTALL_DIR}/config.env <<EOL
# EUserv账号配置(必填)
EUSERV_EMAIL=${email}
EUSERV_PASSWORD=${password}
EMAIL_PASS=${email_pass}

# Telegram推送配置(可选)
EOL

    # 只有填写了才添加到配置文件
    if [ -n "$tg_bot_token" ]; then
        echo "TG_BOT_TOKEN=${tg_bot_token}" >> ${INSTALL_DIR}/config.env
    fi
    
    if [ -n "$tg_chat_id" ]; then
        echo "TG_CHAT_ID=${tg_chat_id}" >> ${INSTALL_DIR}/config.env
    fi
    
    if [ -n "$bark_url" ]; then
        echo "BARK_URL=${bark_url}" >> ${INSTALL_DIR}/config.env
    fi
    
    chmod 600 ${INSTALL_DIR}/config.env
    echo "配置已更新"
    sleep 2
    show_menu
}

update_script() {
    echo ""
    echo "===== 更新续期脚本 ====="
    echo ""
    
    # 显示当前脚本信息
    if [ -f "${INSTALL_DIR}/euser_renew.py" ]; then
        echo "当前脚本修改时间: $(stat -c %y ${INSTALL_DIR}/euser_renew.py 2>/dev/null || stat -f %Sm ${INSTALL_DIR}/euser_renew.py 2>/dev/null)"
    fi
    echo ""
    
    read -p "确定要从GitHub更新脚本吗? (y/N): " confirm
    
    if [[ $confirm == "y" || $confirm == "Y" ]]; then
        echo "正在备份当前脚本..."
        if [ -f "${INSTALL_DIR}/euser_renew.py" ]; then
            cp ${INSTALL_DIR}/euser_renew.py ${INSTALL_DIR}/euser_renew.py.bak.$(date +%Y%m%d_%H%M%S)
            echo "备份完成: ${INSTALL_DIR}/euser_renew.py.bak.$(date +%Y%m%d_%H%M%S)"
        fi
        
        echo "正在下载最新脚本..."
        if curl -fsSL https://raw.githubusercontent.com/dufei511/euserv_py/dev/euser_renew.py -o ${INSTALL_DIR}/euser_renew.py.new; then
            mv ${INSTALL_DIR}/euser_renew.py.new ${INSTALL_DIR}/euser_renew.py
            chmod +x ${INSTALL_DIR}/euser_renew.py
            echo ""
            echo "✓ 脚本更新成功!"
            echo "新脚本修改时间: $(stat -c %y ${INSTALL_DIR}/euser_renew.py 2>/dev/null || stat -f %Sm ${INSTALL_DIR}/euser_renew.py 2>/dev/null)"
            echo ""
            
            read -p "是否立即重启服务以应用更新? (Y/n): " restart_confirm
            if [[ $restart_confirm != "n" && $restart_confirm != "N" ]]; then
                echo "正在重启服务..."
                cd ${INSTALL_DIR}
                docker-compose down
                docker-compose up --build -d
                echo "✓ 服务已重启，更新已生效"
            else
                echo "提示: 记得稍后手动重启服务以应用更新"
            fi
        else
            echo ""
            echo "✗ 脚本下载失败，可能原因:"
            echo "  1. 网络连接问题"
            echo "  2. GitHub无法访问"
            echo "  3. 脚本路径已变更"
            echo ""
            if [ -f "${INSTALL_DIR}/euser_renew.py.bak.$(date +%Y%m%d_%H%M%S)" ]; then
                echo "备份文件已保留，原脚本未受影响"
            fi
        fi
    else
        echo "取消更新"
    fi
    
    echo ""
    read -p "按回车键返回菜单..." 
    show_menu
}

fix_docker_permission() {
    echo ""
    echo "===== 修复Docker权限问题 ====="
    echo ""
    echo "正在诊断问题..."
    echo ""
    
    # 检查Docker版本
    echo "Docker版本:"
    docker --version 2>/dev/null || echo "未安装"
    echo ""
    
    # 检查存储驱动
    echo "当前存储驱动:"
    docker info 2>/dev/null | grep "Storage Driver" || echo "无法获取存储驱动信息"
    echo ""
    
    # 检查磁盘空间
    echo "磁盘使用情况:"
    df -h / | tail -1
    echo ""
    
    # 检查当前模式
    if [ -f "${INSTALL_DIR}/.no_docker" ]; then
        echo "📌 当前模式: 直接运行模式 (已禁用Docker)"
        echo ""
        echo "如需切换回Docker模式:"
        echo "1. 删除标记文件: rm ${INSTALL_DIR}/.no_docker"
        echo "2. 确保Docker可用"
        echo "3. 重启服务"
        echo ""
        read -p "按回车键返回菜单..." 
        show_menu
        return
    fi
    
    echo "📌 当前模式: Docker模式"
    echo ""
    echo "检测到的问题类型:"
    echo "- overlay/权限错误 → 方案1可能有效"
    echo "- 磁盘配额/inode不足 → 必须使用方案2"
    echo ""
    echo "可用的修复方案:"
    echo "1. 切换Docker存储驱动为vfs (需要足够空间)"
    echo "2. 切换到直接运行模式 (推荐,节省空间)"
    echo "3. 返回菜单"
    echo ""
    read -p "请选择修复方案 [1-3]: " fix_choice
    
    case $fix_choice in
        1)
            echo ""
            echo "正在切换Docker存储驱动为vfs..."
            echo ""
            
            # 停止Docker
            systemctl stop docker
            
            # 备份Docker配置
            if [ -f /etc/docker/daemon.json ]; then
                cp /etc/docker/daemon.json /etc/docker/daemon.json.bak.$(date +%Y%m%d_%H%M%S)
            fi
            
            # 创建或更新daemon.json
            mkdir -p /etc/docker
            cat > /etc/docker/daemon.json <<'DOCKEREOF'
{
  "storage-driver": "vfs"
}
DOCKEREOF
            
            # 清理旧数据
            echo "清理Docker旧数据..."
            rm -rf /var/lib/docker/*
            
            # 重启Docker
            systemctl start docker
            
            echo "✓ Docker存储驱动已切换为vfs"
            echo ""
            echo "正在重建容器..."
            cd ${INSTALL_DIR}
            docker-compose down 2>/dev/null
            
            echo "尝试构建容器..."
            if docker-compose up --build -d 2>&1 | grep -q "disk quota exceeded\|operation not permitted"; then
                echo ""
                echo "❌ 方案1失败: VPS资源限制太严格"
                echo "建议使用方案2 (直接运行模式)"
                echo ""
                read -p "是否立即切换到方案2? (Y/n): " switch_to_2
                if [[ $switch_to_2 != "n" && $switch_to_2 != "N" ]]; then
                    auto_switch_to_direct_mode
                fi
            else
                echo "✓ 修复完成!"
            fi
            ;;
        2)
            auto_switch_to_direct_mode
            ;;
        3)
            show_menu
            return
            ;;
        *)
            echo "无效选择"
            sleep 2
            fix_docker_permission
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
        
        # 停止并禁用服务
        if systemctl list-unit-files | grep -q "euserv-renew.timer"; then
            systemctl stop euserv-renew.timer 2>/dev/null
            systemctl disable euserv-renew.timer 2>/dev/null
            echo "✓ 已停止定时器服务"
        fi
        
        if systemctl list-unit-files | grep -q "euserv-renew.service"; then
            systemctl stop euserv-renew.service 2>/dev/null
            systemctl disable euserv-renew.service 2>/dev/null
            echo "✓ 已停止执行服务"
        fi
        
        # 删除服务文件
        if [ -f /etc/systemd/system/euserv-renew.service ]; then
            rm -f /etc/systemd/system/euserv-renew.service
            echo "✓ 已删除服务文件"
        fi
        
        if [ -f /etc/systemd/system/euserv-renew.timer ]; then
            rm -f /etc/systemd/system/euserv-renew.timer
            echo "✓ 已删除定时器文件"
        fi
        
        systemctl daemon-reload
        
        # 停止并删除Docker容器
        if [ -d "${INSTALL_DIR}" ]; then
            if [ -f "${INSTALL_DIR}/docker-compose.yml" ]; then
                cd ${INSTALL_DIR}
                docker-compose down -v 2>/dev/null && echo "✓ 已停止Docker容器"
            fi
            
            rm -rf ${INSTALL_DIR}
            echo "✓ 已删除安装目录"
        else
            echo "! 安装目录不存在，跳过"
        fi
        
        # 删除快捷命令
        if [ -f /usr/local/bin/dj ]; then
            rm -f /usr/local/bin/dj
            echo "✓ 已删除快捷命令"
        fi
        
        echo ""
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
    
    # 执行安装步骤
    check_root
    install_dependencies
    create_directories
    download_script
    configure_env
    create_dockerfile
    
    # 设置执行时间
    read -p "请输入每天执行的小时数(0-23,默认3点): " run_hour
    run_hour=${run_hour:-3}
    
    if ! [[ $run_hour =~ ^[0-9]+$ ]] || [ $run_hour -lt 0 ] || [ $run_hour -gt 23 ]; then
        print_warning "无效的小时数,使用默认值3"
        run_hour=3
    fi
    
    create_docker_compose $run_hour
    setup_cron $run_hour
    create_command
    
    echo ""
    print_success "========================================="
    print_success "EUserv自动续期服务安装完成!"
    print_success "========================================="
    print_info "服务将在每天 ${run_hour}:00 自动执行"
    print_info "使用以下命令管理服务:"
    print_info "  dj                - 打开管理面板"
    print_info "  systemctl status euserv-renew.timer - 查看定时器状态"
    print_success "========================================="
    echo ""
    print_info "提示: 如果遇到Docker权限问题，请运行 'dj' 选择选项8进行修复"
    echo ""
}

# 卸载函数
uninstall_service() {
    print_info "开始卸载EUserv自动续期服务..."
    
    # 停止并禁用服务
    if systemctl list-unit-files | grep -q "euserv-renew.timer"; then
        systemctl stop ${SERVICE_NAME}.timer 2>/dev/null
        systemctl disable ${SERVICE_NAME}.timer 2>/dev/null
        print_info "已停止定时器服务"
    fi
    
    if systemctl list-unit-files | grep -q "euserv-renew.service"; then
        systemctl stop ${SERVICE_NAME}.service 2>/dev/null
        systemctl disable ${SERVICE_NAME}.service 2>/dev/null
        print_info "已停止执行服务"
    fi
    
    # 删除服务文件
    if [ -f /etc/systemd/system/${SERVICE_NAME}.service ]; then
        rm -f /etc/systemd/system/${SERVICE_NAME}.service
        print_info "已删除服务文件"
    fi
    
    if [ -f /etc/systemd/system/${SERVICE_NAME}.timer ]; then
        rm -f /etc/systemd/system/${SERVICE_NAME}.timer
        print_info "已删除定时器文件"
    fi
    
    systemctl daemon-reload
    
    # 停止并删除Docker容器
    if [ -d "${INSTALL_DIR}" ]; then
        if [ -f "${COMPOSE_FILE}" ]; then
            cd ${INSTALL_DIR}
            docker-compose down -v 2>/dev/null
            print_info "已停止Docker容器"
        fi
        
        # 删除安装目录
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
    echo "EUserv 自动续期一键部署脚本"
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