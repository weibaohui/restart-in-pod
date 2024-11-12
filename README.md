@[TOC](目录)

# 问题
程序运行在k8s Pod内，在开发时，如何进行快速更新调试？也就是不重启Pod的情况如何，如何热更新应用程序？
使用k8s环境进行应用部署，每次都需要打包成镜像，上传到镜像仓库，然后更新Deployment，等待Pod启动，整个过程较为繁琐，远不如在本机进行开发调试方便。如果遇到必须在Pod内运行的应用，那么这个等待过程难以缩减，即便是使用了CICD的自动化工具，也依然要等待很长时间。

## 思路

在开发调试新的逻辑时，我们的核心诉求，往往是对程序快速更新，快速验证。
关键要具备有如下几点：
1. **运行容器** ：有个稳定的运行**外壳**。Deployment可以胜任这个工作，它可以提供运行shell、网络访问端口，pvc挂载等；
2. 能够轻松的将编译的二进制文件，传到**运行容器**内
3. 能够自动检测到二进制文件的更新， 检测文件变更，然后重启二进制应用；
4. 能够方便快捷的看到运行日志。
   具备以上几点后，那么我们就可以第一次部署应用程序到k8s上，后续的更新程序时，就是上传文件到Pod内，自动重启，测试验证，调整代码，编译二进制，上传二进制，再测试验证。
   那么从第二次更新开始，这个过程非常简单了，能够节省大量的等待时间。


下面我们以开发一个golang应用为示例，进行实战。
假设开发的程序名称为demo，编译二进制文件名为demo，
打包镜像使用名称weibh/restart-in-pod:latest，部署到k8s中运行。
在开发过程中，不断进行编译，更新，看如何应对频繁、快速更新。
## 解决问题
下面我们逐个解决这几个关键点
1. 运行容器
2. 上传文件
3. 自动重启

### 1、运行容器

运行容器要求镜像内包含shell、ls、cat、tar等基础工具。为方便后面的检测二进制文件更新以及自动重启，我们需要安装几个组件。下面给出示例Dockerfile。
#### 镜像打包
```dockerfile
FROM golang:alpine as builder
WORKDIR /build
COPY .  .
RUN ls
RUN go build -o demo .

FROM alpine
WORKDIR /app
RUN sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories
RUN apk add --no-cache curl bash inotify-tools
ADD reload.sh /app/reload.sh
RUN chmod +x /app/reload.sh
COPY --from=builder /build/demo /app/demo

ENTRYPOINT ["/app/reload.sh","demo","/app"]

```
其中，使用了两阶段构建，第一阶段，构建Demo应用，第二阶段，将其放入alpine的运行环境中。此外涉及一个关键文件：reload.sh，它负责实现对二进制文件的监控。
#### reload脚本
reload.sh原理就是监控文件变更，当写入完成后，关闭正在运行的应用，重新启动新的应用。
reload.sh内如如下：
```reload.sh
#!/bin/bash

# 检查是否传入了必要的参数
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 <binary_name> <watch_directory>"
    exit 1
fi

APP_NAME="$1"                      # 要监控的二进制文件名（如 demo）
WATCH_PATH="$2"                    # 监控的目录（如 /app）
APP_PATH="${WATCH_PATH}/${APP_NAME}"         # 上传的新文件路径
CURRENT_PATH="${WATCH_PATH}/${APP_NAME}.current"  # 运行中的文件路径


# 启动应用程序
start_app() {
    echo "Starting ${APP_NAME}..."
    mv "$APP_PATH" "$CURRENT_PATH"        # 将新上传的文件重命名
    chmod +x "$CURRENT_PATH"              # 确保文件可执行
    sleep 1
    "$CURRENT_PATH" &
    APP_PID=$!
    echo "${APP_NAME} started with PID: $APP_PID"
}

# 停止应用程序
stop_app() {
    if [ -n "$APP_PID" ]; then
        echo "Stopping ${APP_NAME} with PID: $APP_PID"
        kill "$APP_PID"
        wait "$APP_PID" 2>/dev/null
        echo "${APP_NAME} stopped"
    fi
}

# 初次启动程序
start_app

# 使用 inotifywait 监控 APP_PATH 的 close_write 事件，确保只在新的文件写入完成后触发
while true; do
    # 监听 close_write 事件，排除文件重命名的误触发
    inotifywait -e close_write --exclude "${APP_NAME}.current" "$WATCH_PATH"
    sleep 1
    # 检查是否是新的文件写入完成
    if [ -f "$APP_PATH" ]; then
        echo "Detected new version of ${APP_NAME}, restarting..."
        # 删除旧文件并启动新程序
        rm -f "$CURRENT_PATH"
        stop_app
        sleep 1
        start_app
    fi
done
```
#### Deployment部署yaml
接下来构建我们的k8s Deployment
```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: demo
  labels:
    app: demo
spec:
  ports:
    - name: web
      protocol: TCP
      port: 80
      targetPort: 80
  selector:
    app: demo
  type: ClusterIP
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo
  labels:
    app: demo
spec:
  selector:
    matchLabels:
      app: demo
  template:
    metadata:
      labels:
        app: demo
    spec:
      containers:
        - name: demo
          image: weibh/restart-in-pod:latest
          ports:
            - containerPort: 80
              protocol: TCP
              name: web
          imagePullPolicy: Always
```
都准备好后执行命令，制作镜像，上传并部署。
```shell
docker build -t weibh/restart-in-pod -f Dockerfile .
docker push weibh/restart-in-pod
kubectl apply -f deploy.yaml
```
### 2、上传文件到容器内
我们选择使用k8m程序提供的Pod文件管理功能。可以通过界面的方式，管理Pod内的容器，可以浏览目录、查看文件、在线编辑、上传文件、下载文件以及删除文件等常规操作。非常方便。
**假设我们修改了需求，重新编译了demo二进制。那么接下来需要上传了。**
#### 安装k8m

1. **下载**：从 [GitHub](https://github.com/weibaohui/k8m) 下载最新版本。
2. **运行**：使用 `./k8m` 命令启动,访问[http://127.0.0.1:3618](http://127.0.0.1:3618)
3. **访问**：
   ![Pod](https://i-blog.csdnimg.cn/direct/55da6acc30eb4808943fcd3ce7cffb79.png)
4. **文件管理**：选择文件管理器
   ![文件管理器](https://i-blog.csdnimg.cn/direct/cdc0305c4e064bb882959b603482c7d3.png)
   点击上传按钮![点击上传按钮](https://i-blog.csdnimg.cn/direct/eb46731d24d94ee1b25ce4455686c17b.png)
   点击上传文件
   ![点击上传文件](https://i-blog.csdnimg.cn/direct/0bc77f3ef8584b0d91edb533d789616d.png)
   选择文件，上传
   提示上传成功
   ![提示上传成功](https://i-blog.csdnimg.cn/direct/d3b83aa19c894b39a12132790d4fe11c.png)
   至此我们最新版的软件就已经上传完毕了。

### 3、自动重启
此时我们的reload.sh文件中的监控开始生效。当文件上传完成的那一刻，会触发重启。
我们通过日志来看下效果。
#### 查看日志
Pod列表中的日志按钮
![查看日志](https://i-blog.csdnimg.cn/direct/ce805ddb00eb4de599d53ecf41f0b598.png)
点击查看日志
![点击查看日志](https://i-blog.csdnimg.cn/direct/b5db00e5e5854d1981e9f444453f8979.png)
查看启动日志及程序运行信息
![运行信息](https://i-blog.csdnimg.cn/direct/b4713c437b3f4c6db7f8d9739ad2c674.png)
当文件上传后，会看到日志信息变化，首先原先的进程被杀死，启动了新的进程，并答应了程序输出。
![重启过程](https://i-blog.csdnimg.cn/direct/22515340ed9f41acaa85e72ab301508f.png)
至此完成二进制文件的热升级。
### 总结
通过制作一个带有reload脚本的容器镜像，结合[k8m](https://github.com/weibaohui/k8m)提供的Pod内文件管理功能，我们可以非常轻松的实现k8s内应用开发的快速更新，极大的降低了等待时间，欢迎各位尝试。

### 演示项目地址
为方便大家体验，特将相关源码开放，如有需要请自行获取。
[https://github.com/weibaohui/restart-in-pod](https://github.com/weibaohui/restart-in-pod)

#### 引用
[https://github.com/weibaohui/k8m](https://github.com/weibaohui/k8m)
[https://github.com/weibaohui/kom](https://github.com/weibaohui/kom)
