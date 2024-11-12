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
