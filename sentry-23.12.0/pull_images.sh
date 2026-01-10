#!/bin/bash

# 检查当前目录下是否存在 docker-compose.yml
if [ ! -f "docker-compose.yml" ]; then
    echo "错误: 当前目录下未找到 docker-compose.yml 文件"
    exit 1
fi

echo "开始解析并逐个拉取镜像..."

# 提取镜像名称并去重，然后逐个拉取
images=$(docker compose config | grep 'image:' | awk '{print $2}' | sort | uniq)

for img in $images; do
    echo "------------------------------------------"
    echo "正在拉取镜像: $img"
    docker pull "$img"
    if [ $? -eq 0 ]; then
        echo "成功: $img 已就绪"
    else
        echo "失败: $img 拉取过程中出错"
    fi
done

echo "------------------------------------------"
echo "所有镜像拉取尝试完成！现在可以运行 docker compose up -d 了。"
