
# =========================
# MyRAG Python 应用镜像
# =========================
# 大白话：
# Dockerfile 只负责“把 Python RAG 程序打包成镜像”。
# 它不负责启动 MySQL，也不负责启动 Milvus；那些由 docker-compose.yaml 负责。

# 使用 Python 3.11 的轻量 Linux 镜像。
# slim 镜像比较小，但还保留 apt，可以安装 pdftotext 等系统工具。
FROM python:3.11-slim

# 让 Python 日志立刻输出，方便 docker logs 看到实时内容。
ENV PYTHONUNBUFFERED=1

# 让 Python 能直接 import app.xxx。
ENV PYTHONPATH=/app

# HuggingFace 模型缓存目录。
# compose 里会把 ./volumes/model_cache 挂到这个目录，避免每次重下 embedding 模型。
ENV HF_HOME=/root/.cache/huggingface

# 容器里的项目目录。
WORKDIR /app

# 安装系统依赖。
# poppler-utils 提供 pdftotext，项目入库 PDF 时会用到它。
# curl 用于简单排查网络/健康检查，不是业务核心。
RUN apt-get update \
    && apt-get install -y --no-install-recommends poppler-utils curl \
    && rm -rf /var/lib/apt/lists/*

# 先复制依赖文件，再安装依赖。
# 这样 Docker 可以利用缓存：只要 requirements.txt 不变，就不用每次重装依赖。
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r /app/requirements.txt

# 复制项目代码。
# 注意：这里不复制 data/ 和 volumes/。
# 原始文档和数据库数据应该通过 docker-compose 的 volume 挂载进来，不应该打进镜像。
COPY app /app/app
COPY scripts /app/scripts
COPY configs /app/configs
COPY README_ENGINEERING.md /app/README_ENGINEERING.md

# 默认命令：让 rag-app 容器保持运行，方便你进入容器或用 docker compose run 执行脚本。
# 真正入库/聊天时，推荐手动运行：
# docker compose run --rm rag-app python scripts/ingest_documents.py
# docker compose run --rm rag-app python scripts/rag_chat_memory.py
CMD ["tail", "-f", "/dev/null"]
