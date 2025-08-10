#!/bin/bash
# shellcheck disable=SC2155
# alist-downloader.sh - 通用 Alist 云盘下载器
#
# 功能：使用 Alist 离线下载功能将文件下载到云存储
# 支持：多种云盘类型、批量下载、实时进度监控
#
# 使用方式：
#   ./alist-downloader.sh <storage_config_json> <target_path> <download_list_file> [options_json]
#
# 参数说明：
#   storage_config_json: 存储配置 JSON 字符串
#   target_path: 目标路径
#   download_list_file: 下载列表文件路径 (格式: URL|filename|size)
#   options_json: 可选配置 JSON (批量模式、线程数、语言等)

set -e

# 默认配置
DEFAULT_ALIST_URL="http://localhost:5244"
DEFAULT_BATCH_MODE="true"
DEFAULT_DOWNLOAD_THREADS="3"
DEFAULT_TRANSFER_THREADS="3"
DEFAULT_LANGUAGE="zh"
DEFAULT_USE_EMOJI="true"
DEFAULT_FORCE_SYNC="false"
DEFAULT_TIMEOUT="1800"
DEFAULT_CHECK_INTERVAL="5"

# 全局变量
ALIST_URL=""
BATCH_MODE=""
DOWNLOAD_THREADS=""
TRANSFER_THREADS=""
LANGUAGE=""
USE_EMOJI=""
FORCE_SYNC=""
TIMEOUT_SECONDS=""
CHECK_INTERVAL=""

# 导入工具函数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/alist-utils.sh" ]; then
    source "$SCRIPT_DIR/alist-utils.sh"
else
    echo "错误: 无法找到工具函数文件 alist-utils.sh" >&2
    exit 1
fi

# 解析配置
parse_config() {
    local storage_config="$1"
    local options_config="$2"
    
    # 解析存储配置 (必需)
    if [ -z "$storage_config" ]; then
        log_error "存储配置不能为空"
        exit 1
    fi
    
    # 解析选项配置 (可选)
    if [ -n "$options_config" ]; then
        ALIST_URL=$(echo "$options_config" | jq -r '.alist_url // "'"$DEFAULT_ALIST_URL"'"')
        BATCH_MODE=$(echo "$options_config" | jq -r '.batch_mode // "'"$DEFAULT_BATCH_MODE"'"')
        DOWNLOAD_THREADS=$(echo "$options_config" | jq -r '.download_threads // "'"$DEFAULT_DOWNLOAD_THREADS"'"')
        TRANSFER_THREADS=$(echo "$options_config" | jq -r '.transfer_threads // "'"$DEFAULT_TRANSFER_THREADS"'"')
        LANGUAGE=$(echo "$options_config" | jq -r '.language // "'"$DEFAULT_LANGUAGE"'"')
        USE_EMOJI=$(echo "$options_config" | jq -r '.use_emoji // "'"$DEFAULT_USE_EMOJI"'"')
        FORCE_SYNC=$(echo "$options_config" | jq -r '.force_sync // "'"$DEFAULT_FORCE_SYNC"'"')
        TIMEOUT_SECONDS=$(echo "$options_config" | jq -r '.timeout // "'"$DEFAULT_TIMEOUT"'"')
        CHECK_INTERVAL=$(echo "$options_config" | jq -r '.check_interval // "'"$DEFAULT_CHECK_INTERVAL"'"')
    else
        # 使用默认值
        ALIST_URL="$DEFAULT_ALIST_URL"
        BATCH_MODE="$DEFAULT_BATCH_MODE"
        DOWNLOAD_THREADS="$DEFAULT_DOWNLOAD_THREADS"
        TRANSFER_THREADS="$DEFAULT_TRANSFER_THREADS"
        LANGUAGE="$DEFAULT_LANGUAGE"
        USE_EMOJI="$DEFAULT_USE_EMOJI"
        FORCE_SYNC="$DEFAULT_FORCE_SYNC"
        TIMEOUT_SECONDS="$DEFAULT_TIMEOUT"
        CHECK_INTERVAL="$DEFAULT_CHECK_INTERVAL"
    fi
    
    # 设置全局环境变量供工具函数使用
    export TABLE_LANGUAGE="$LANGUAGE"
    export USE_EMOJI="$USE_EMOJI"
}

# 部署 Alist 服务
deploy_alist() {
    log_info "部署临时Alist服务..."
    
    # 创建临时目录
    mkdir -p /tmp/alist-data
    
    # 启动Alist容器
    docker run -d \
        --name=temp-alist \
        -p 5244:5244 \
        -v /tmp/alist-data:/opt/alist/data \
        xhofe/alist:latest >/dev/null
    
    # 等待启动完成
    log_info "等待Alist启动..."
    for i in {1..30}; do
        if curl -s "$ALIST_URL/ping" > /dev/null 2>&1; then
            log_success "Alist服务启动成功"
            break
        fi
        log_info "等待服务启动... ($i/30)"
        sleep 3
        
        if [ $i -eq 30 ]; then
            log_error "Alist启动超时"
            docker logs temp-alist
            exit 1
        fi
    done
    
    # 设置固定管理员密码
    local admin_password="temp123456"
    log_info "设置管理员密码..."
    
    docker exec temp-alist ./alist admin set "$admin_password" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        log_error "设置管理员密码失败"
        exit 1
    fi
    
    log_success "管理员密码设置成功"
    echo "$admin_password"
}

# 获取 Alist token
get_alist_token() {
    local admin_password="$1"
    
    log_info "获取管理员Token..."
    
    # 先测试基本连通性
    local ping_result=$(curl -s -w "%{http_code}" -o /dev/null "$ALIST_URL/ping" || echo "000")
    
    local response=$(curl -s -w "HTTP_CODE:%{http_code}" -X POST "$ALIST_URL/api/auth/login" \
        -H "Content-Type: application/json" \
        -d "{
            \"username\": \"admin\",
            \"password\": \"$admin_password\"
        }")
    
    # 分离HTTP状态码和响应体
    local http_code=$(echo "$response" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
    local response_body=$(echo "$response" | sed 's/HTTP_CODE:[0-9]*$//')
    
    if [ "$http_code" != "200" ]; then
        log_error "HTTP请求失败，状态码: $http_code"
        log_error "Alist可能未正确启动，检查容器状态："
        docker logs temp-alist --tail 20
        exit 1
    fi
    
    # 检查响应是否为有效JSON
    if ! check_api_response "$response_body" "登录"; then
        log_error "Alist可能未正确启动，检查容器状态："
        docker logs temp-alist --tail 20
        exit 1
    fi
    
    local token=$(echo "$response_body" | jq -r '.data.token // empty')
    
    if [ -n "$token" ] && [ "$token" != "null" ]; then
        log_success "Token获取成功"
        echo "$token"
    else
        log_error "Token获取失败: $response_body"
        exit 1
    fi
}

# 挂载云盘存储
mount_storage() {
    local alist_token="$1"
    local storage_config="$2"
    
    log_info "挂载云盘存储..."
    
    # 解析存储配置
    local mount_path=$(echo "$storage_config" | jq -r '.mount_path')
    local driver=$(echo "$storage_config" | jq -r '.driver')
    local addition=$(echo "$storage_config" | jq -r '.addition')
    local remark=$(echo "$storage_config" | jq -r '.remark // "Alist Downloader"')
    
    if [ -z "$mount_path" ] || [ -z "$driver" ] || [ -z "$addition" ]; then
        log_error "存储配置不完整，需要 mount_path, driver, addition"
        exit 1
    fi
    
    local mount_response=$(curl -s -w "HTTP_CODE:%{http_code}" -X POST "$ALIST_URL/api/admin/storage/create" \
        -H "Authorization: $alist_token" \
        -H "Content-Type: application/json" \
        -d "{
            \"mount_path\": \"$mount_path\",
            \"driver\": \"$driver\", 
            \"order\": 0,
            \"remark\": \"$remark\",
            \"addition\": \"$addition\"
        }")
    
    # 分离HTTP状态码和响应体
    local http_code=$(echo "$mount_response" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
    local response_body=$(echo "$mount_response" | sed 's/HTTP_CODE:[0-9]*$//')
    
    if [ "$http_code" != "200" ]; then
        log_error "挂载HTTP请求失败，状态码: $http_code"
        log_error "响应内容: $response_body"
        exit 1
    fi
    
    # 检查响应是否为有效JSON
    if ! check_api_response "$response_body" "挂载云盘"; then
        exit 1
    fi
    
    if echo "$response_body" | jq -e '.code == 200' > /dev/null; then
        local storage_id=$(echo "$response_body" | jq -r '.data.id')
        log_success "云盘挂载成功 (ID: $storage_id)"
        echo "$storage_id"
    else
        log_error "云盘挂载失败: $(echo "$response_body" | jq -r '.message // "未知错误"')"
        exit 1
    fi
}

# 配置 Alist 线程数
configure_alist_threads() {
    local alist_token="$1"
    local download_threads="$2"
    local transfer_threads="$3"
    
    if [ "$BATCH_MODE" != "true" ]; then
        log_info "单文件下载模式，跳过线程配置"
        return 0
    fi
    
    log_info "配置Alist线程数 (下载:$download_threads, 传输:$transfer_threads)..."
    
    # 获取当前配置
    local current_config=$(curl -s -X GET "$ALIST_URL/api/admin/setting/list" \
        -H "Authorization: $alist_token")
    
    if ! echo "$current_config" | jq -e '.code == 200' > /dev/null; then
        log_warning "无法获取当前配置，跳过线程设置"
        return 0
    fi
    
    # 保存原始配置
    local offline_threads=$(echo "$current_config" | jq -r '.data[] | select(.key == "offline_download_task_threads_num") | .value')
    local offline_type=$(echo "$current_config" | jq -r '.data[] | select(.key == "offline_download_task_threads_num") | .type')
    local offline_help=$(echo "$current_config" | jq -r '.data[] | select(.key == "offline_download_task_threads_num") | .help')
    local offline_group=$(echo "$current_config" | jq -r '.data[] | select(.key == "offline_download_task_threads_num") | .group')
    local offline_flag=$(echo "$current_config" | jq -r '.data[] | select(.key == "offline_download_task_threads_num") | .flag')
    
    local transfer_threads_orig=$(echo "$current_config" | jq -r '.data[] | select(.key == "offline_download_transfer_task_threads_num") | .value')
    local transfer_type=$(echo "$current_config" | jq -r '.data[] | select(.key == "offline_download_transfer_task_threads_num") | .type')
    local transfer_help=$(echo "$current_config" | jq -r '.data[] | select(.key == "offline_download_transfer_task_threads_num") | .help')
    local transfer_group=$(echo "$current_config" | jq -r '.data[] | select(.key == "offline_download_transfer_task_threads_num") | .group')
    local transfer_flag=$(echo "$current_config" | jq -r '.data[] | select(.key == "offline_download_transfer_task_threads_num") | .flag')
    
    # 保存原始配置供后续恢复使用
    echo "offline_threads=$offline_threads" > /tmp/alist_original_threads.env
    echo "offline_type=$offline_type" >> /tmp/alist_original_threads.env
    echo "offline_help=$offline_help" >> /tmp/alist_original_threads.env
    echo "offline_group=$offline_group" >> /tmp/alist_original_threads.env
    echo "offline_flag=$offline_flag" >> /tmp/alist_original_threads.env
    echo "transfer_threads_orig=$transfer_threads_orig" >> /tmp/alist_original_threads.env
    echo "transfer_type=$transfer_type" >> /tmp/alist_original_threads.env
    echo "transfer_help=$transfer_help" >> /tmp/alist_original_threads.env
    echo "transfer_group=$transfer_group" >> /tmp/alist_original_threads.env
    echo "transfer_flag=$transfer_flag" >> /tmp/alist_original_threads.env
    
    # 设置新的线程数
    local set_offline_response=$(curl -s -X POST "$ALIST_URL/api/admin/setting/save" \
        -H "Authorization: $alist_token" \
        -H "Content-Type: application/json" \
        -d "[{
            \"key\": \"offline_download_task_threads_num\", 
            \"value\": \"$download_threads\",
            \"type\": \"$offline_type\",
            \"help\": \"$offline_help\",
            \"group\": $offline_group,
            \"flag\": $offline_flag
        }]")
    
    local set_transfer_response=$(curl -s -X POST "$ALIST_URL/api/admin/setting/save" \
        -H "Authorization: $alist_token" \
        -H "Content-Type: application/json" \
        -d "[{
            \"key\": \"offline_download_transfer_task_threads_num\", 
            \"value\": \"$transfer_threads\",
            \"type\": \"$transfer_type\",
            \"help\": \"$transfer_help\",
            \"group\": $transfer_group,
            \"flag\": $transfer_flag
        }]")
    
    if echo "$set_offline_response" | jq -e '.code == 200' > /dev/null && \
       echo "$set_transfer_response" | jq -e '.code == 200' > /dev/null; then
        log_success "线程数配置成功 (下载:$download_threads, 传输:$transfer_threads)"
    else
        log_warning "线程数配置可能失败，但继续执行"
    fi
}

# 恢复原始线程数
restore_alist_threads() {
    local alist_token="$1"
    
    if [ "$BATCH_MODE" != "true" ] || [ ! -f "/tmp/alist_original_threads.env" ]; then
        return 0
    fi
    
    log_info "恢复原始线程配置..."
    
    # 加载原始配置
    source /tmp/alist_original_threads.env
    
    # 恢复原始线程数
    if [ -n "$offline_threads" ]; then
        curl -s -X POST "$ALIST_URL/api/admin/setting/save" \
            -H "Authorization: $alist_token" \
            -H "Content-Type: application/json" \
            -d "[{
                \"key\": \"offline_download_task_threads_num\", 
                \"value\": \"$offline_threads\",
                \"type\": \"$offline_type\",
                \"help\": \"$offline_help\",
                \"group\": $offline_group,
                \"flag\": $offline_flag
            }]" > /dev/null
    fi
    
    if [ -n "$transfer_threads_orig" ]; then
        curl -s -X POST "$ALIST_URL/api/admin/setting/save" \
            -H "Authorization: $alist_token" \
            -H "Content-Type: application/json" \
            -d "[{
                \"key\": \"offline_download_transfer_task_threads_num\", 
                \"value\": \"$transfer_threads_orig\",
                \"type\": \"$transfer_type\",
                \"help\": \"$transfer_help\",
                \"group\": $transfer_group,
                \"flag\": $transfer_flag
            }]" > /dev/null
    fi
    
    # 清理临时文件
    rm -f /tmp/alist_original_threads.env
    log_success "原始线程配置已恢复"
}

# 创建目标目录
create_target_directory() {
    local alist_token="$1"
    local target_path="$2"
    
    log_info "创建目标目录: $target_path"
    
    local mkdir_response=$(curl -s -w "HTTP_CODE:%{http_code}" -X POST "$ALIST_URL/api/fs/mkdir" \
        -H "Authorization: $alist_token" \
        -H "Content-Type: application/json" \
        -d "{\"path\": \"$target_path\"}")
    
    # 分离HTTP状态码和响应体
    local http_code=$(echo "$mkdir_response" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
    local response_body=$(echo "$mkdir_response" | sed 's/HTTP_CODE:[0-9]*$//')
    
    if [ "$http_code" != "200" ]; then
        log_error "创建目录HTTP请求失败，状态码: $http_code"
        log_error "响应内容: $response_body"
        exit 1
    fi
    
    if ! check_api_response "$response_body" "创建目录"; then
        exit 1
    fi
    
    if echo "$response_body" | jq -e '.code == 200' > /dev/null || echo "$response_body" | jq -r '.message' | grep -q "already exists"; then
        log_success "目标目录准备完成"
        return 0
    else
        log_error "目标目录创建失败: $(echo "$response_body" | jq -r '.message // "未知错误"')"
        exit 1
    fi
}

# 检查已存在文件
check_existing_files() {
    local alist_token="$1"
    local target_path="$2"
    local download_list_file="$3"
    
    log_info "检查已存在的文件..."
    
    local list_response=$(curl -s -w "HTTP_CODE:%{http_code}" -X POST "$ALIST_URL/api/fs/list" \
        -H "Authorization: $alist_token" \
        -H "Content-Type: application/json" \
        -d "{\"path\": \"$target_path\"}")
    
    # 分离HTTP状态码和响应体
    local http_code=$(echo "$list_response" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
    local response_body=$(echo "$list_response" | sed 's/HTTP_CODE:[0-9]*$//')
    
    if [ "$http_code" != "200" ]; then
        log_error "列出文件HTTP请求失败，状态码: $http_code"
        log_error "响应内容: $response_body"
        exit 1
    fi
    
    if ! check_api_response "$response_body" "列出文件"; then
        exit 1
    fi
    
    if echo "$response_body" | jq -e '.code == 200' > /dev/null; then
        local existing_files=$(echo "$response_body" | jq -r '.data.content[]?.name // empty')
        local existing_count=$(echo "$existing_files" | wc -w)
        
        log_info "云盘中已存在 $existing_count 个文件"
        
        # 获取要同步的文件列表
        local sync_files=""
        if [ -f "$download_list_file" ]; then
            sync_files=$(awk -F'|' '{print $2}' "$download_list_file" | tr '\n' ' ')
        fi
        
        # 检查要同步的文件是否已存在
        local conflicted_files=""
        if [ -n "$sync_files" ] && [ "$existing_count" -gt 0 ]; then
            for sync_file in $sync_files; do
                if echo "$existing_files" | grep -q "^$sync_file$"; then
                    if [ -z "$conflicted_files" ]; then
                        conflicted_files="$sync_file"
                    else
                        conflicted_files="$conflicted_files $sync_file"
                    fi
                fi
            done
        fi
        
        local conflict_count=$(echo "$conflicted_files" | wc -w)
        local total_sync_files=$(echo "$sync_files" | wc -w)
        
        if [ "$conflict_count" -gt 0 ] && [ "$FORCE_SYNC" != "true" ]; then
            log_warning "检测到 $conflict_count 个文件已存在，将跳过这些文件"
            for file in $conflicted_files; do
                echo "  📄 $file"
            done
            
            # 如果所有文件都冲突，则完全跳过
            if [ "$conflict_count" -eq "$total_sync_files" ]; then
                echo "所有文件都已存在，如需重新同步，请启用 force_sync 参数"
                return 1
            fi
            
            # 从下载列表中移除冲突文件
            local temp_file="/tmp/download_list_filtered.txt"
            true > "$temp_file"
            while IFS='|' read -r url filename filesize; do
                local is_conflicted=false
                for conflicted_file in $conflicted_files; do
                    if [ "$filename" = "$conflicted_file" ]; then
                        is_conflicted=true
                        break
                    fi
                done
                if [ "$is_conflicted" = false ]; then
                    echo "$url|$filename|$filesize" >> "$temp_file"
                fi
            done < "$download_list_file"
            
            # 替换原文件
            mv "$temp_file" "$download_list_file"
            
            local remaining_count=$((total_sync_files - conflict_count))
            log_info "将继续同步剩余的 $remaining_count 个新文件"
        fi
        
        if [ "$FORCE_SYNC" = "true" ] && [ "$conflict_count" -gt 0 ]; then
            log_info "强制同步模式，清理冲突的文件..."
            for file in $conflicted_files; do
                if [ -n "$file" ]; then
                    echo "删除: $file"
                    curl -s -X POST "$ALIST_URL/api/fs/remove" \
                        -H "Authorization: $alist_token" \
                        -H "Content-Type: application/json" \
                        -d "{\"names\":[\"$target_path/$file\"]}" > /dev/null
                fi
            done
            log_success "已清理冲突文件"
        fi
        
        if [ "$conflict_count" -eq 0 ] && [ "$existing_count" -gt 0 ]; then
            log_info "云盘中的文件与当前同步任务无冲突，继续执行"
        fi
    fi
    
    return 0
}

# 监控下载任务
monitor_download_task() {
    local alist_token="$1"
    local filename="$2"
    
    local max_wait=$TIMEOUT_SECONDS
    local wait_time=0
    local download_completed=false
    
    while [ $wait_time -lt $max_wait ]; do
        # 检查未完成的任务
        local undone_tasks=$(curl -s -X GET "$ALIST_URL/api/admin/task/offline_download/undone" \
            -H "Authorization: $alist_token")
        
        # 检查已完成的任务  
        local done_tasks=$(curl -s -X GET "$ALIST_URL/api/admin/task/offline_download/done" \
            -H "Authorization: $alist_token")
        
        # 查找我们的任务
        local current_undone=$(echo "$undone_tasks" | jq -r --arg filename "$filename" \
            '.data[]? | select(.name | contains($filename)) | .state')
        
        if [ -n "$current_undone" ]; then
            local progress=$(echo "$undone_tasks" | jq -r --arg filename "$filename" \
                '.data[]? | select(.name | contains($filename)) | .progress // 0')
            # 格式化百分比为1位小数
            local formatted_progress=$(printf "%.1f" "$progress")
            
            if [ "$current_undone" = "0" ]; then
                log_progress "等待任务开始... (${formatted_progress}%)"
            elif [ "$current_undone" = "1" ]; then
                log_progress "正在下载到Alist... (${formatted_progress}%)"
            fi
        else
            # 检查是否在已完成列表中
            local current_done=$(echo "$done_tasks" | jq -r --arg filename "$filename" \
                '.data[]? | select(.name | contains($filename)) | .state')
            
            if [ -n "$current_done" ]; then
                if [ "$current_done" = "2" ]; then
                    # 只在第一次检测到下载完成时输出消息
                    if [ "$download_completed" = false ]; then
                        log_progress "下载到Alist完成，检查传输到云盘..."
                        download_completed=true
                    fi
                    
                    # 检查传输任务
                    local transfer_undone=$(curl -s -X GET "$ALIST_URL/api/admin/task/offline_download_transfer/undone" \
                        -H "Authorization: $alist_token")
                    local transfer_done=$(curl -s -X GET "$ALIST_URL/api/admin/task/offline_download_transfer/done" \
                        -H "Authorization: $alist_token")
                    
                    # 检查是否有进行中的传输任务
                    local transfer_active=$(echo "$transfer_undone" | jq -r --arg filename "$filename" \
                        '.data[]? | select(.name | contains($filename)) | .state')
                    
                    if [ -n "$transfer_active" ]; then
                        local transfer_progress=$(echo "$transfer_undone" | jq -r --arg filename "$filename" \
                            '.data[]? | select(.name | contains($filename)) | .progress // 0')
                        # 格式化百分比为1位小数
                        local formatted_progress=$(printf "%.1f" "$transfer_progress")
                        log_progress "正在传输到云盘... (${formatted_progress}%)"
                        # 继续等待传输完成
                    else
                        # 检查传输是否已完成
                        local transfer_completed=$(echo "$transfer_done" | jq -r --arg filename "$filename" \
                            '.data[]? | select(.name | contains($filename)) | .state')
                        
                        if [ -n "$transfer_completed" ]; then
                            if [ "$transfer_completed" = "2" ]; then
                                echo "success"
                                return 0
                            else
                                local transfer_error=$(echo "$transfer_done" | jq -r --arg filename "$filename" \
                                    '.data[]? | select(.name | contains($filename)) | .error // "传输失败"')
                                echo "failed:$transfer_error"
                                return 1
                            fi
                        else
                            # 可能传输任务还没有开始，继续等待
                            log_progress "等待传输任务开始..."
                        fi
                    fi
                elif [ "$current_done" = "7" ]; then
                    local error_msg=$(echo "$done_tasks" | jq -r --arg filename "$filename" \
                        '.data[]? | select(.name | contains($filename)) | .error // "未知错误"')
                    echo "failed:$error_msg"
                    return 1
                else
                    echo "unknown:$current_done"
                    return 1
                fi
            fi
        fi
        
        sleep $CHECK_INTERVAL
        wait_time=$((wait_time + CHECK_INTERVAL))
    done
    
    echo "timeout"
    return 1
}

# 上传文件到云盘 (单文件模式)
upload_files_single() {
    local alist_token="$1"
    local target_path="$2"
    local download_list_file="$3"
    
    log_info "开始上传文件到云盘 (单文件模式)..."
    
    local file_index=0
    local success_count=0
    local fail_count=0
    local total_files=$(cat "$download_list_file" | wc -l)
    
    while IFS='|' read -r download_url filename filesize; do
        if [ -z "$download_url" ]; then
            continue
        fi
        
        file_index=$((file_index + 1))
        local size_mb=$((filesize / 1024 / 1024))
        
        echo ""
        log_info "[$file_index/$total_files] 处理文件: $filename (${size_mb}MB)"
        
        # 检查runner剩余空间
        local available_space=$(df /tmp --output=avail | tail -1)
        local available_gb=$((available_space / 1024 / 1024))
        local file_gb=$((filesize / 1024 / 1024 / 1024 + 1))
        
        echo "💾 可用空间: ${available_gb}GB, 文件大小: ${file_gb}GB"
        
        if [ $available_gb -lt $((file_gb + 2)) ]; then
            log_warning "空间不足，跳过大文件: $filename"
            fail_count=$((fail_count + 1))
            continue
        fi
        
        # 添加离线下载任务
        log_info "提交离线下载任务到Alist..."
        local download_response=$(curl -s -X POST "$ALIST_URL/api/fs/add_offline_download" \
            -H "Authorization: $alist_token" \
            -H "Content-Type: application/json" \
            -d "{
                \"path\": \"$target_path\",
                \"urls\": [\"$download_url\"],
                \"tool\": \"SimpleHttp\",
                \"delete_policy\": \"delete_on_upload_succeed\"
            }")
        
        if echo "$download_response" | jq -e '.code == 200' > /dev/null; then
            log_success "离线下载任务已提交，开始传输到云盘"
        else
            log_error "下载任务提交失败: $(echo "$download_response" | jq -r '.message // "未知错误"')"
            fail_count=$((fail_count + 1))
            continue
        fi
        
        # 监控下载进度
        log_info "监控下载进度..."
        local result=$(monitor_download_task "$alist_token" "$filename")
        
        case "$result" in
            "success")
                log_success "[$file_index] $filename 下载成功！"
                success_count=$((success_count + 1))
                ;;
            "failed:"*)
                local error_msg="${result#failed:}"
                log_error "[$file_index] $filename 下载失败: $error_msg"
                fail_count=$((fail_count + 1))
                ;;
            "timeout")
                log_warning "[$file_index] $filename 下载超时"
                fail_count=$((fail_count + 1))
                ;;
            *)
                log_warning "[$file_index] $filename 下载未完成，最终状态: $result"
                fail_count=$((fail_count + 1))
                ;;
        esac
        
        # 短暂休息避免过载
        sleep 2
        
    done < "$download_list_file"
    
    echo ""
    log_info "上传完成统计:"
    echo "  ✅ 成功: $success_count"
    echo "  ❌ 失败: $fail_count"
    echo "  📁 总计: $total_files"
    
    # 返回成功文件数
    echo "$success_count"
}

# 批量上传文件到云盘 (多线程模式)
upload_files_batch() {
    local alist_token="$1"
    local target_path="$2"
    local download_list_file="$3"
    
    log_info "开始批量上传文件到云盘（多线程模式）..."
    
    local total_files=$(cat "$download_list_file" | wc -l)
    if [ "$total_files" -eq 0 ]; then
        log_warning "没有文件需要上传"
        echo "0"
        return 0
    fi
    
    # 准备所有URL
    local urls=""
    local filenames=""
    local max_filename_len=8  # 最小文件名列宽
    
    while IFS='|' read -r download_url filename filesize; do
        if [ -n "$download_url" ]; then
            if [ -z "$urls" ]; then
                urls="\"$download_url\""
                filenames="$filename"
            else
                urls="$urls,\"$download_url\""
                filenames="$filenames $filename"
            fi
            
            # 计算最大文件名宽度
            local name_width=$(get_display_width "$filename")
            if [ $name_width -gt $max_filename_len ]; then
                max_filename_len=$name_width
            fi
        fi
    done < "$download_list_file"
    
    if [ -z "$urls" ]; then
        log_warning "没有有效的下载URL"
        echo "0"
        return 0
    fi
    
    log_info "提交 $total_files 个文件的批量下载任务..."
    
    # 提交批量离线下载任务
    local batch_response=$(curl -s -X POST "$ALIST_URL/api/fs/add_offline_download" \
        -H "Authorization: $alist_token" \
        -H "Content-Type: application/json" \
        -d "{
            \"path\": \"$target_path\",
            \"urls\": [$urls],
            \"tool\": \"SimpleHttp\",
            \"delete_policy\": \"delete_on_upload_succeed\"
        }")
    
    if ! echo "$batch_response" | jq -e '.code == 200' > /dev/null; then
        log_error "批量下载任务提交失败: $(echo "$batch_response" | jq -r '.message // "未知错误"')"
        echo "0"
        return 1
    fi
    
    log_success "批量下载任务已提交，开始监控进度..."
    
    # 动态表格监控
    local max_wait=1800  # 30分钟超时
    local wait_time=0
    local check_interval=3
    
    # 创建临时文件用于存储任务状态
    local undone_file="/tmp/undone_tasks.txt"
    local done_file="/tmp/done_tasks.txt"
    local transfer_undone_file="/tmp/transfer_undone.txt"
    local transfer_done_file="/tmp/transfer_done.txt"
    
    while [ $wait_time -lt $max_wait ]; do
        # 获取任务状态
        curl -s -X GET "$ALIST_URL/api/admin/task/offline_download/undone" \
            -H "Authorization: $alist_token" | \
            jq -r '.data[]? | select(.name | contains("'$target_path'")) | "\(.name)|\(.state)|\(.progress)"' > "$undone_file"
        
        curl -s -X GET "$ALIST_URL/api/admin/task/offline_download/done" \
            -H "Authorization: $alist_token" | \
            jq -r '.data[]? | select(.name | contains("'$target_path'")) | "\(.name)|\(.state)|\(.progress)"' > "$done_file"
        
        curl -s -X GET "$ALIST_URL/api/admin/task/offline_download_transfer/undone" \
            -H "Authorization: $alist_token" | \
            jq -r '.data[]? | "\(.name)|\(.state)|\(.progress)"' > "$transfer_undone_file"
        
        curl -s -X GET "$ALIST_URL/api/admin/task/offline_download_transfer/done" \
            -H "Authorization: $alist_token" | \
            jq -r '.data[]? | "\(.name)|\(.state)|\(.progress)"' > "$transfer_done_file"
        
        # 显示表格
        echo "" >&2
        echo "📋 批量下载进度监控 [$(get_timestamp)]" >&2
        echo "" >&2
        
        # 重新计算当前循环中的最大文件名宽度
        local current_max_width=$(get_display_width "$(get_text "filename")")  # 表头宽度
        
        # 检查所有文件名的宽度
        for filename in $filenames; do
            if [ -n "$filename" ]; then
                local name_width=$(get_display_width "$filename")
                if [ $name_width -gt $current_max_width ]; then
                    current_max_width=$name_width
                fi
            fi
        done
        
        local filename_col_width=$((current_max_width + 4))
        
        # 计算状态列的实际宽度
        local download_status_width=$(get_display_width "$(get_text "download_status")")
        local transfer_status_width=$(get_display_width "$(get_text "transfer_status")")
        
        # 确保状态列至少能容纳状态文本
        local min_download_width=16
        local min_transfer_width=16
        if [ $download_status_width -gt $min_download_width ]; then
            min_download_width=$download_status_width
        fi
        if [ $transfer_status_width -gt $min_transfer_width ]; then
            min_transfer_width=$transfer_status_width
        fi
        
        printf "%s | %s | %s\n" \
            "$(pad_to_width "$(get_text "filename")" $filename_col_width)" \
            "$(pad_to_width "$(get_text "download_status")" $min_download_width)" \
            "$(pad_to_width "$(get_text "transfer_status")" $min_transfer_width)" >&2
        
        # 分隔线 - 使用实际列宽
        local sep_line=""
        for i in $(seq 1 $filename_col_width); do sep_line="${sep_line}-"; done
        sep_line="${sep_line}-|-"
        for i in $(seq 1 $min_download_width); do sep_line="${sep_line}-"; done
        sep_line="${sep_line}-|-"
        for i in $(seq 1 $min_transfer_width); do sep_line="${sep_line}-"; done
        echo "$sep_line" >&2
        
        # 显示每个文件的状态
        local completed_count=0
        for filename in $filenames; do
            local download_status="$(get_text "waiting_download")"
            local transfer_status="$(get_text "waiting_transfer")"
            
            # 检查下载状态
            if grep -q "$filename" "$undone_file"; then
                local task_state=$(grep "$filename" "$undone_file" | cut -d'|' -f2)
                local task_progress=$(grep "$filename" "$undone_file" | cut -d'|' -f3)
                local formatted_progress=$(printf "%.1f" "${task_progress:-0}")
                
                if [ "$task_state" = "1" ]; then
                    download_status="$(get_text "downloading") ${formatted_progress}%"
                else
                    download_status="$(get_text "waiting_download")"
                fi
            elif grep -q "$filename" "$done_file"; then
                local task_state=$(grep "$filename" "$done_file" | cut -d'|' -f2)
                if [ "$task_state" = "2" ]; then
                    download_status="$(get_text "download_complete")"
                else
                    download_status="$(get_text "download_failed")"
                fi
            fi
            
            # 检查传输状态 - 使用更灵活的匹配
            local transfer_found=false
            if [ -s "$transfer_undone_file" ]; then
                local transfer_line=$(grep "/$filename" "$transfer_undone_file" | head -1)
                if [ -n "$transfer_line" ]; then
                    transfer_found=true
                    local transfer_state=$(echo "$transfer_line" | cut -d'|' -f2)
                    local transfer_progress=$(echo "$transfer_line" | cut -d'|' -f3)
                    local formatted_progress=$(printf "%.1f" "${transfer_progress:-0}")
                    
                    if [ "$transfer_state" = "1" ]; then
                        transfer_status="$(get_text "transferring") ${formatted_progress}%"
                    else
                        transfer_status="$(get_text "waiting_transfer")"
                    fi
                fi
            fi
            
            if [ "$transfer_found" = false ] && [ -s "$transfer_done_file" ]; then
                local transfer_line=$(grep "/$filename" "$transfer_done_file" | head -1)
                if [ -n "$transfer_line" ]; then
                    local transfer_state=$(echo "$transfer_line" | cut -d'|' -f2)
                    if [ "$transfer_state" = "2" ]; then
                        transfer_status="$(get_text "transfer_complete")"
                        completed_count=$((completed_count + 1))
                    else
                        transfer_status="$(get_text "transfer_failed")"
                    fi
                fi
            fi
            
            # 显示文件状态行
            printf "%s | %s | %s\n" \
                "$(pad_to_width "$filename" $filename_col_width)" \
                "$(pad_to_width "$download_status" $min_download_width)" \
                "$(pad_to_width "$transfer_status" $min_transfer_width)" >&2
        done
        
        echo "" >&2
        echo "📊 进度统计: $completed_count/$total_files 已完成" >&2
        
        # 检查是否全部完成
        if [ $completed_count -eq $total_files ]; then
            echo "" >&2
            log_success "所有文件批量下载完成！"
            break
        fi
        
        sleep $check_interval
        wait_time=$((wait_time + check_interval))
        
        # 清屏准备下次显示
        if [ $wait_time -lt $max_wait ]; then
            for i in $(seq 1 $((total_files + 8))); do echo -ne "\033[A\033[K" >&2; done
        fi
    done
    
    # 清理临时文件
    rm -f "$undone_file" "$done_file" "$transfer_undone_file" "$transfer_done_file"
    
    if [ $wait_time -ge $max_wait ]; then
        log_warning "批量下载监控超时"
        echo "$completed_count"
    else
        echo "$completed_count"
    fi
}

# 验证上传结果
verify_upload() {
    local alist_token="$1"
    local target_path="$2"
    local download_list_file="$3"
    
    log_info "验证本次上传的文件..."
    
    # 获取本次上传的文件列表
    local expected_files=""
    if [ -f "$download_list_file" ]; then
        expected_files=$(awk -F'|' '{print $2}' "$download_list_file")
    fi
    
    if [ -z "$expected_files" ]; then
        log_warning "没有需要验证的文件"
        echo "0"
        return 0
    fi
    
    local result=$(curl -s -X POST "$ALIST_URL/api/fs/list" \
        -H "Authorization: $alist_token" \
        -H "Content-Type: application/json" \
        -d "{\"path\": \"$target_path\"}")
    
    if echo "$result" | jq -e '.code == 200' > /dev/null; then
        local verified_count=0
        local failed_files=""
        
        log_success "目标目录: $target_path"
        
        # 使用for循环避免子shell问题
        for expected_file in $expected_files; do
            if [ -n "$expected_file" ]; then
                local file_exists=$(echo "$result" | jq -r --arg name "$expected_file" \
                    '.data.content[] | select(.name == $name) | .name // empty')
                
                if [ -n "$file_exists" ]; then
                    local file_info=$(echo "$result" | jq -r --arg name "$expected_file" \
                        '.data.content[] | select(.name == $name) | "大小: \(.size) bytes, 修改时间: \(.modified)"')
                    
                    echo "  ✅ $expected_file - $file_info" >&2
                    verified_count=$((verified_count + 1))
                else
                    echo "  ❌ $expected_file - 文件未找到！" >&2
                    if [ -z "$failed_files" ]; then
                        failed_files="$expected_file"
                    else
                        failed_files="$failed_files $expected_file"
                    fi
                fi
            fi
        done
        
        local expected_count=$(echo "$expected_files" | wc -w)
        log_success "验证完成: $verified_count/$expected_count 个文件成功上传"
        
        if [ -n "$failed_files" ]; then
            log_error "以下文件上传失败:"
            for failed_file in $failed_files; do
                echo "  📄 $failed_file" >&2
            done
        fi
        
        echo "$verified_count"
    else
        log_error "无法获取上传结果: $(echo "$result" | jq -r '.message // "未知错误"')"
        echo "0"
    fi
}

# 清理资源
cleanup_alist() {
    local alist_token="$1"
    local storage_id="$2"
    
    log_info "清理临时资源..."
    
    # 恢复原始线程配置
    restore_alist_threads "$alist_token"
    
    # 删除云盘存储
    if [ -n "$storage_id" ]; then
        log_info "删除临时存储..."
        curl -s -X POST "$ALIST_URL/api/admin/storage/delete" \
            -H "Authorization: $alist_token" \
            -H "Content-Type: application/json" \
            -d "{\"id\": $storage_id}" > /dev/null || log_warning "存储删除失败"
    fi
    
    # 停止并删除容器
    docker stop temp-alist || true
    docker rm temp-alist || true
    
    # 清理临时文件（使用sudo处理权限问题）
    if [ -d "/tmp/alist-data" ]; then
        sudo rm -rf /tmp/alist-data || rm -rf /tmp/alist-data || log_warning "无法删除 /tmp/alist-data，可能需要手动清理"
    fi
    rm -f /tmp/undone_tasks.txt /tmp/done_tasks.txt /tmp/transfer_undone.txt /tmp/transfer_done.txt || true
    
    log_success "清理完成"
}

# 主入口函数
main() {
    local storage_config="$1"
    local target_path="$2" 
    local download_list_file="$3"
    local options_config="$4"
    
    # 检查必需参数
    if [ $# -lt 3 ]; then
        echo "Usage: $0 <storage_config_json> <target_path> <download_list_file> [options_json]"
        echo ""
        echo "参数说明:"
        echo "  storage_config_json: 存储配置 JSON"
        echo "  target_path: 目标路径"
        echo "  download_list_file: 下载列表文件"
        echo "  options_json: 可选配置 JSON"
        echo ""
        echo "存储配置示例:"
        echo '  {"mount_path":"/移动云盘","driver":"139Yun","addition":"{\"authorization\":\"xxx\"}"}'
        echo ""
        echo "选项配置示例:"
        echo '  {"batch_mode":true,"download_threads":3,"language":"zh","use_emoji":true}'
        exit 1
    fi
    
    # 检查下载列表文件
    if [ ! -f "$download_list_file" ]; then
        log_error "下载列表文件不存在: $download_list_file"
        exit 1
    fi
    
    local file_count=$(cat "$download_list_file" | wc -l)
    if [ "$file_count" -eq 0 ]; then
        log_warning "下载列表为空"
        echo "0"
        return 0
    fi
    
    # 解析配置
    parse_config "$storage_config" "$options_config"
    
    echo "🚀 Alist云盘下载器启动"
    echo "================================================"
    
    if [ "$BATCH_MODE" = "true" ]; then
        log_info "使用多线程批量下载模式 (下载:${DOWNLOAD_THREADS}线程, 传输:${TRANSFER_THREADS}线程)"
    else
        log_info "使用单文件下载模式"
    fi
    
    # 部署Alist
    local admin_password=$(deploy_alist)
    
    # 获取token
    local alist_token=$(get_alist_token "$admin_password")
    
    # 挂载云盘
    local storage_id=$(mount_storage "$alist_token" "$storage_config")
    
    # 配置线程数（仅在批量模式下）
    configure_alist_threads "$alist_token" "$DOWNLOAD_THREADS" "$TRANSFER_THREADS"
    
    # 创建目标目录
    create_target_directory "$alist_token" "$target_path"
    
    # 检查已存在文件
    if ! check_existing_files "$alist_token" "$target_path" "$download_list_file"; then
        cleanup_alist "$alist_token" "$storage_id"
        log_warning "所有文件已存在，跳过下载"
        echo "0"
        return 0
    fi
    
    # 上传文件（根据配置选择模式）
    local success_count
    if [ "$BATCH_MODE" = "true" ]; then
        success_count=$(upload_files_batch "$alist_token" "$target_path" "$download_list_file")
    else
        success_count=$(upload_files_single "$alist_token" "$target_path" "$download_list_file")
    fi
    
    # 验证结果
    local final_count=$(verify_upload "$alist_token" "$target_path" "$download_list_file")
    
    # 清理资源
    cleanup_alist "$alist_token" "$storage_id"
    
    echo ""
    echo "================================================"
    log_success "Alist云盘下载完成！"
    log_success "📁 目标路径: $target_path"
    log_success "📊 成功文件数: $final_count"
    if [ "$BATCH_MODE" = "true" ]; then
        log_success "⚡ 下载模式: 多线程批量 (${DOWNLOAD_THREADS}+${TRANSFER_THREADS}线程)"
    else
        log_success "📝 下载模式: 单文件下载"
    fi
    
    # 返回成功下载的文件数
    echo "$final_count"
}

# 如果直接运行此脚本（非被source）
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
