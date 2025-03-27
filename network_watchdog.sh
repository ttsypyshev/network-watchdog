#!/bin/bash

# Конфигурация (настройки)

# Загружаем переменные BOT_TOKEN и CHAT_IDS из .env файла
if [[ -f .env ]]; then
    set -o allexport
    source .env
    set +o allexport
else
    echo ".env файл не найден!"
    exit 1
fi

# Проверяем, что BOT_TOKEN и CHAT_IDS заданы в .env файле.
if [[ -z "$BOT_TOKEN" || -z "$CHAT_IDS" ]]; then
    echo "err" "Ошибка: BOT_TOKEN или CHAT_IDS не заданы в .env файле!"
    exit 1
fi

# Преобразуем CHAT_IDS в массив
IFS=',' read -ra CHAT_IDS <<< "$CHAT_IDS"

IP_SERVERS=("8.8.8.8" "1.1.1.1")    # Массив DNS серверов для пинга
LOG_DIR="log"                       # Папка для логов
CHECK_INTERVAL=10                   # Интервал проверки в секундах

# Создаем папку для логов, если её нет
mkdir -p "$LOG_DIR"

# Логирование событий
log_event() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_file="$LOG_DIR/$(date '+%Y-%m-%d').log"  # Лог-файл на основе текущей даты
    echo "$timestamp - [$level] - $message" >> "$log_file"
}

# Проверка доступности интернета
check_internet() {
    for server in "${IP_SERVERS[@]}"; do
        if timeout 1 ping -c 1 "$server" &>/dev/null; then
            log_event "debug" "Есть доступ в интернет."
            return 0
        else
            log_event "warn" "Ошибка пинга к серверу $server. Сервер недоступен."
        fi
    done
    log_event "debug" "Все серверы недоступны."
    return 1
}

# Отправка уведомления в Telegram
send_telegram_notification() {
    local message="$1"
    log_event "debug" "Отправка уведомления в Telegram..."
    for CHAT_ID in "${CHAT_IDS[@]}"; do
        curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
            -d chat_id="$CHAT_ID" \
            -d text="$(echo -e "$message")" \
            -d parse_mode="Markdown" &>/dev/null &&
        log_event "info" "Уведомление отправлено chat_id=$CHAT_ID" ||
        log_event "err" "Ошибка отправки уведомления chat_id=$CHAT_ID"
    done
}

# Получение информации о сети
get_network_info() {
    for iface in $(ip -o link show | awk -F': ' '{print $2}'); do
        if [[ -e "/sys/class/net/$iface" && $(cat /sys/class/net/$iface/operstate) == "up" ]]; then
            case "$iface" in
                en*|eth*)
                    ip_addr=$(ip -4 addr show dev $iface | awk '/inet / {print $2}')
                    [[ -n "$ip_addr" ]] && echo "$ip_addr" && return ;;
                wlan*|wlo*)
                    wifi_info=$(iw dev $iface link | awk -F'SSID: ' '/SSID/ {print $2}');;
            esac
        fi
    done
    echo "${wifi_info:-Неизвестно}"
}

# Очищаем старые логи (старше месяца)
cleanup_logs() {
    log_event "debug" "Очистка логов..."
    find "$LOG_DIR" -type f -name "*.log" -mtime +30 -exec sh -c '
        for file; do
            log_event "info" "Удалён файл: $file"
            rm -f "$file"
        done
    ' sh {} +
}

# Основной цикл
previous_status="unknown"
previous_network="unknown"
disconnected_time=""

# Запуск очистки логов
cleanup_logs

while true; do
    if check_internet; then
        network_info=$(get_network_info)
        if [[ "$previous_status" != "connected" ]]; then
            if [[ -n "$disconnected_time" ]]; then
                downtime_duration=$(( $(date +%s) - $(date -d "$disconnected_time" +%s) ))
                downtime_formatted=$(date -u -d @$downtime_duration +"%H:%M:%S")

                log_event "info" "Интернет восстановлен. Время простоя: $downtime_formatted. Подключение: $network_info."
                send_telegram_notification "🔥 Интернет восстановлен на сервере \`$(hostname)\`. \nВремя потери соединения: \`$(date -d "$disconnected_time" +"%a %d %b %Y %H:%M:%S %Z")\` \nВремя простоя: \`$downtime_formatted\` \nАктуальное подключение: \`$network_info\`"
            else
                log_event "info" "Интернет подключен. Подключение: $network_info."
                send_telegram_notification "✅ Интернет подключен на сервере \`$(hostname)\`. \nАктуальное подключение: \`$network_info\`"
            fi
            previous_status="connected"
            previous_network="$network_info"
            disconnected_time=""
        fi
        if [[ "$previous_network" != "$network_info" ]]; then
            log_event "info" "Изменение сети на $network_info."
            send_telegram_notification "🔄 Изменение сети на сервере \`$(hostname)\`. \nНовое подключение: \`$network_info\`"
            previous_network="$network_info"
        fi
    else
        if [[ "$previous_status" != "disconnected" ]]; then
            disconnected_time=$(date '+%Y-%m-%d %H:%M:%S')
            log_event "err" "Интернет недоступен с $disconnected_time."
            send_telegram_notification "❌ Интернет недоступен на сервере \`$(hostname)\`.\nВремя отключения: \`$disconnected_time\`"
            previous_status="disconnected"
        fi
    fi
    sleep "$CHECK_INTERVAL"
done
