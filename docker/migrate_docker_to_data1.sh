#!/bin/bash

# Docker 存储迁移到 /data1 的一键脚本
# 使用方法: sudo bash migrate_docker_to_data1.sh

set -e  # 遇到错误时退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否以root权限运行
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行"
        log_info "请使用: sudo bash $0"
        exit 1
    fi
}

# 检查/data1是否存在且可写
check_data1() {
    if [[ ! -d "/data1" ]]; then
        log_error "/data1 目录不存在"
        exit 1
    fi
    
    if [[ ! -w "/data1" ]]; then
        log_error "/data1 目录不可写"
        exit 1
    fi
    
    log_success "/data1 目录检查通过"
}

# 检查磁盘空间
check_disk_space() {
    local current_docker_size=$(du -s /var/lib/docker 2>/dev/null | cut -f1 || echo "0")
    local data1_available=$(df /data1 | awk 'NR==2 {print $4}')
    
    if [[ $current_docker_size -gt $data1_available ]]; then
        log_error "/data1 空间不足以存储现有Docker数据"
        log_info "需要空间: ${current_docker_size}KB，可用空间: ${data1_available}KB"
        exit 1
    fi
    
    log_success "磁盘空间检查通过"
}

# 备份当前配置
backup_config() {
    local backup_dir="/tmp/docker_migration_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    
    # 备份daemon.json（如果存在）
    if [[ -f "/etc/docker/daemon.json" ]]; then
        cp "/etc/docker/daemon.json" "$backup_dir/"
        log_info "已备份现有daemon.json到 $backup_dir"
    fi
    
    echo "$backup_dir" > /tmp/docker_backup_location
    log_success "配置备份完成: $backup_dir"
}

# 停止Docker服务
stop_docker() {
    log_info "停止Docker服务..."
    systemctl stop docker.service
    systemctl stop docker.socket
    log_success "Docker服务已停止"
}

# 启动Docker服务
start_docker() {
    log_info "启动Docker服务..."
    systemctl start docker.service
    systemctl enable docker.service
    log_success "Docker服务已启动"
}

# 创建新的Docker数据目录
create_docker_dir() {
    log_info "在/data1创建Docker数据目录..."
    mkdir -p /data1/docker
    chown root:root /data1/docker
    chmod 711 /data1/docker
    log_success "Docker数据目录创建完成"
}

# 迁移Docker数据
migrate_docker_data() {
    log_info "迁移Docker数据..."
    
    if [[ -d "/var/lib/docker" ]] && [[ "$(ls -A /var/lib/docker)" ]]; then
        log_info "发现现有Docker数据，正在迁移..."
        rsync -avxHAX --progress /var/lib/docker/ /data1/docker/
        log_success "Docker数据迁移完成"
        
        # 重命名旧目录作为备份
        mv /var/lib/docker /var/lib/docker.backup.$(date +%Y%m%d_%H%M%S)
        log_info "旧Docker数据已重命名为备份"
    else
        log_info "未发现现有Docker数据，跳过数据迁移"
    fi
}

# 配置Docker daemon
configure_docker_daemon() {
    log_info "配置Docker daemon..."
    
    # 创建Docker配置目录
    mkdir -p /etc/docker
    
    # 创建或更新daemon.json
    if [[ -f "/etc/docker/daemon.json" ]]; then
        # 如果文件存在，更新data-root配置
        python3 -c "
import json
import sys

config_file = '/etc/docker/daemon.json'
try:
    with open(config_file, 'r') as f:
        config = json.load(f)
except:
    config = {}

config['data-root'] = '/data1/docker'

with open(config_file, 'w') as f:
    json.dump(config, f, indent=2)

print('Docker daemon配置已更新')
" || {
        # 如果Python方法失败，使用简单的方法
        echo '{
  "data-root": "/data1/docker"
}' > /etc/docker/daemon.json
    }
    else
        # 创建新的daemon.json
        echo '{
  "data-root": "/data1/docker"
}' > /etc/docker/daemon.json
    fi
    
    log_success "Docker daemon配置完成"
}

# 验证配置
verify_migration() {
    log_info "验证Docker配置..."
    
    # 等待Docker完全启动
    sleep 5
    
    # 检查Docker root目录
    local docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "")
    
    if [[ "$docker_root" == "/data1/docker" ]]; then
        log_success "Docker存储已成功迁移到 /data1/docker"
        
        # 显示磁盘使用情况
        log_info "当前磁盘使用情况:"
        df -h /data1 | grep -E "(Filesystem|/data1)"
        
        return 0
    else
        log_error "迁移验证失败，Docker root目录: $docker_root"
        return 1
    fi
}

# 清理备份文件（可选）
cleanup_old_backup() {
    log_info "检测到Docker备份文件..."
    local backup_dirs=$(find /var/lib -maxdepth 1 -name "docker.backup.*" -type d 2>/dev/null || echo "")
    
    if [[ -n "$backup_dirs" ]]; then
        echo
        log_warning "发现以下备份目录:"
        echo "$backup_dirs"
        echo
        read -p "是否删除这些备份目录？这将释放磁盘空间。(y/N): " -n 1 -r
        echo
        
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "$backup_dirs" | while read -r backup_dir; do
                if [[ -n "$backup_dir" ]]; then
                    log_info "删除备份目录: $backup_dir"
                    rm -rf "$backup_dir"
                fi
            done
            log_success "备份清理完成"
        else
            log_info "保留备份文件"
        fi
    fi
}

# 错误处理和回滚
rollback() {
    log_error "迁移过程中出现错误，尝试回滚..."
    
    # 停止Docker
    systemctl stop docker.service || true
    
    # 恢复备份配置
    local backup_location=$(cat /tmp/docker_backup_location 2>/dev/null || echo "")
    if [[ -n "$backup_location" ]] && [[ -f "$backup_location/daemon.json" ]]; then
        cp "$backup_location/daemon.json" /etc/docker/daemon.json
        log_info "已恢复daemon.json配置"
    fi
    
    # 如果存在备份目录，恢复它
    local backup_dir=$(find /var/lib -maxdepth 1 -name "docker.backup.*" -type d | head -1)
    if [[ -n "$backup_dir" ]]; then
        rm -rf /var/lib/docker
        mv "$backup_dir" /var/lib/docker
        log_info "已恢复Docker数据目录"
    fi
    
    # 启动Docker
    systemctl start docker.service || true
    
    log_error "回滚完成，请检查Docker状态"
    exit 1
}

# 主函数
main() {
    echo "=========================================="
    echo "    Docker 存储迁移到 /data1 脚本"
    echo "=========================================="
    echo
    
    # 设置错误处理
    trap rollback ERR
    
    # 执行检查
    check_root
    check_data1
    check_disk_space
    
    # 显示当前状态
    log_info "当前Docker信息:"
    if systemctl is-active --quiet docker; then
        docker info --format "Root Dir: {{.DockerRootDir}}" 2>/dev/null || echo "无法获取Docker信息"
    else
        log_warning "Docker服务未运行"
    fi
    
    echo
    log_info "当前磁盘使用情况:"
    df -h | grep -E "(Filesystem|/dev/root|/data1)"
    echo
    
    # 确认操作
    read -p "确认要将Docker存储迁移到/data1吗？(y/N): " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "操作已取消"
        exit 0
    fi
    
    # 执行迁移
    backup_config
    stop_docker
    create_docker_dir
    migrate_docker_data
    configure_docker_daemon
    start_docker
    
    # 验证结果
    if verify_migration; then
        echo
        log_success "=========================================="
        log_success "    Docker存储迁移完成！"
        log_success "=========================================="
        
        # 清理备份
        cleanup_old_backup
        
        # 清理临时文件
        rm -f /tmp/docker_backup_location
        
        echo
        log_info "你现在可以正常使用Docker了"
        log_info "Docker数据现在存储在: /data1/docker"
    else
        rollback
    fi
}

# 运行主函数
main "$@"
