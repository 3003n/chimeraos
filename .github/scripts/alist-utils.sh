#!/bin/bash
# alist-utils.sh - Alist 下载器工具函数库
#
# 包含日志、界面显示、API 响应检查等通用工具函数
# 被 alist-downloader.sh 引用

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GRAY='\033[0;37m'
NC='\033[0m' # No Color

# 获取当前时间戳
get_timestamp() {
    date '+%H:%M:%S'
}

# 日志函数
log_info() {
    echo -e "${GRAY}[$(get_timestamp)]${NC} ${BLUE}ℹ️  $1${NC}" >&2
}

log_success() {
    echo -e "${GRAY}[$(get_timestamp)]${NC} ${GREEN}✅ $1${NC}" >&2
}

log_warning() {
    echo -e "${GRAY}[$(get_timestamp)]${NC} ${YELLOW}⚠️  $1${NC}" >&2
}

log_error() {
    echo -e "${GRAY}[$(get_timestamp)]${NC} ${RED}❌ $1${NC}" >&2
}

# 进度日志 (带时间戳)
log_progress() {
    echo -e "${GRAY}[$(get_timestamp)]${NC} ${BLUE}⏳ $1${NC}" >&2
}

# 计算字符串的显示宽度（使用wcswidth思路）
get_display_width() {
    local text="$1"
    
    # 使用python计算显示宽度（如果可用）
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import sys
import unicodedata

def display_width(s):
    width = 0
    for char in s:
        if unicodedata.east_asian_width(char) in ('F', 'W'):
            width += 2  # 全角字符
        elif unicodedata.category(char).startswith('M'):
            width += 0  # 合成字符（不占显示宽度）
        else:
            width += 1  # 半角字符
    return width

print(display_width('$text'))
" 2>/dev/null
    else
        # 降级方案：简单的字节数分析
        local char_count=$(echo -n "$text" | wc -m)
        local byte_count=$(echo -n "$text" | wc -c)
        
        # 如果字节数是字符数的2倍以上，很可能包含较多中文
        if [ $byte_count -gt $((char_count * 2)) ]; then
            # 估算：大多数是中文，按1.8倍计算
            echo $((char_count * 18 / 10))
        elif [ $byte_count -gt $((char_count + char_count / 3)) ]; then
            # 估算：部分中文，按1.4倍计算
            echo $((char_count * 14 / 10))
        else
            # 主要是ASCII
            echo $char_count
        fi
    fi
}

# 生成指定长度的空格，用于对齐
pad_to_width() {
    local text="$1"
    local target_width="$2"
    local display_width
    display_width=$(get_display_width "$text")
    local padding=$((target_width - display_width))
    
    if [ $padding -gt 0 ]; then
        printf "%s%*s" "$text" $padding ""
    else
        printf "%s" "$text"
    fi
}

# 获取本地化文本（支持中英文和emoji）
get_text() {
    local key="$1"
    
    # 使用环境变量，如果没有设置则使用默认值
    local table_language="${TABLE_LANGUAGE:-zh}"
    local use_emoji="${USE_EMOJI:-true}"
    
    if [ "$use_emoji" = "true" ]; then
        # emoji版本
        case "$table_language" in
            "zh")
                case "$key" in
                    "filename") echo "📁 文件名" ;;
                    "download_status") echo "⬇️ 下载状态" ;;
                    "transfer_status") echo "☁️ 传输状态" ;;
                    "progress") echo "📊 进度" ;;
                    "waiting_download") echo "⏳ 等待下载" ;;
                    "downloading") echo "⬇️ 下载中" ;;
                    "download_complete") echo "✅ 下载完成" ;;
                    "download_failed") echo "❌ 下载失败" ;;
                    "waiting_transfer") echo "⏳ 等待传输" ;;
                    "transferring") echo "☁️ 传输中" ;;
                    "transfer_complete") echo "✅ 传输完成" ;;
                    "transfer_failed") echo "❌ 传输失败" ;;
                    "not_started") echo "⭕ 未开始" ;;
                    "unknown") echo "❓ 未知" ;;
                    *) echo "$key" ;;
                esac
                ;;
            "en")
                case "$key" in
                    "filename") echo "📁 Filename" ;;
                    "download_status") echo "⬇️ Download" ;;
                    "transfer_status") echo "☁️ Transfer" ;;
                    "progress") echo "📊 Progress" ;;
                    "waiting_download") echo "⏳ Waiting" ;;
                    "downloading") echo "⬇️ Pulling" ;;
                    "download_complete") echo "✅ Complete" ;;
                    "download_failed") echo "❌ Failed" ;;
                    "waiting_transfer") echo "⏳ Queued" ;;
                    "transferring") echo "☁️ Pushing" ;;
                    "transfer_complete") echo "✅ Stored" ;;
                    "transfer_failed") echo "❌ Error" ;;
                    "not_started") echo "⭕ Pending" ;;
                    "unknown") echo "❓ Unknown" ;;
                    *) echo "$key" ;;
                esac
                ;;
            *) echo "$key" ;;
        esac
    else
        # 纯文本版本
        case "$table_language" in
            "zh")
                case "$key" in
                    "filename") echo "文件名" ;;
                    "download_status") echo "下载状态" ;;
                    "transfer_status") echo "传输状态" ;;
                    "progress") echo "进度" ;;
                    "waiting_download") echo "等待下载" ;;
                    "downloading") echo "下载中" ;;
                    "download_complete") echo "下载完成" ;;
                    "download_failed") echo "下载失败" ;;
                    "waiting_transfer") echo "等待传输" ;;
                    "transferring") echo "传输中" ;;
                    "transfer_complete") echo "传输完成" ;;
                    "transfer_failed") echo "传输失败" ;;
                    "not_started") echo "未开始" ;;
                    "unknown") echo "未知" ;;
                    *) echo "$key" ;;
                esac
                ;;
            "en")
                case "$key" in
                    "filename") echo "Filename" ;;
                    "download_status") echo "Download" ;;
                    "transfer_status") echo "Transfer" ;;
                    "progress") echo "Progress" ;;
                    "waiting_download") echo "Waiting" ;;
                    "downloading") echo "Pulling" ;;
                    "download_complete") echo "Complete" ;;
                    "download_failed") echo "Failed" ;;
                    "waiting_transfer") echo "Queued" ;;
                    "transferring") echo "Pushing" ;;
                    "transfer_complete") echo "Stored" ;;
                    "transfer_failed") echo "Error" ;;
                    "not_started") echo "Pending" ;;
                    "unknown") echo "Unknown" ;;
                    *) echo "$key" ;;
                esac
                ;;
            *) echo "$key" ;;
        esac
    fi
}

# 检查API响应是否为有效JSON
check_api_response() {
    local response="$1"
    local operation="$2"
    
    if [ -z "$response" ]; then
        log_error "$operation API响应为空"
        return 1
    fi
    
    if ! echo "$response" | jq . > /dev/null 2>&1; then
        log_error "$operation API响应不是有效JSON"
        log_error "原始响应内容: '$response'"
        log_error "响应的十六进制: $(echo "$response" | xxd -l 100)"
        return 1
    fi
    return 0
}
