#!/bin/bash

APP_PATH="/app/demo"           # 上传的新文件名始终为 demo
CURRENT_PATH="/app/demo.current" # 运行中的文件名为 demo.current
WATCH_PATH="/app"                  # 监控的目录



# 启动 demo 程序
start_app() {
    echo "Starting demo..."
    mv $APP_PATH $CURRENT_PATH          # 将 demo 重命名为 demo.current
    chmod +x $CURRENT_PATH              # 确保文件可执行
    sleep 1
    $CURRENT_PATH &
    APP_PID=$!
    echo "demo started with PID: $APP_PID"
}
# 停止 demo
stop_app() {
    if [ -n "$APP_PID" ]; then
        echo "Stopping demo with PID: $APP_PID"
        kill "$APP_PID"
        wait "$APP_PID" 2>/dev/null
        echo "demo stopped"
    fi
}



# 初次启动程序
start_app

# 使用 inotifywait 监控 APP_PATH 的 close_write 事件，确保只在新的文件写入完成后触发
while true; do
    # 监听 close_write 事件，且排除文件重命名可能带来的误触发
    inotifywait -e close_write --exclude "demo.current" $WATCH_PATH
    sleep 1
    # 检查是否是新的 demo 文件写入完成
    if [ -f "$APP_PATH" ]; then
        echo "Detected new demo version, restarting..."
        # 删除旧的 demo.current 文件并启动新的程序
        rm -f $CURRENT_PATH
        stop_app
        sleep 1
        start_app
    fi
done
