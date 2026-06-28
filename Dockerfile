# === ステージ1: 基本ビルド環境 (AlmaLinux 8) ===
FROM almalinux:8 AS base

ARG CMAKEVERSION=3.31.2
ENV PATH=/usr/local/bin:$PATH

# 必要なツールのインストール
RUN dnf install -y yum-utils epel-release wget git make gcc-toolset-11-gcc gcc-toolset-11-gcc-c++ \
    && dnf clean all
ENV PATH=/opt/rh/gcc-toolset-11/root/usr/bin:$PATH

# CMake のインストール
RUN curl -fsSL https://github.com/Kitware/CMake/releases/download/v${CMAKEVERSION}/cmake-${CMAKEVERSION}-linux-$(uname -m).tar.gz | tar xz -C /usr/local --strip-components 1

WORKDIR /go/src/github.com/ollama/ollama

# 有志のベースリポジトリをクローン
RUN git clone https://github.com/dogkeeper886/ollama37.git .

# 【超重要】K40c (CC 3.5) 向けに、C/C++ソース(ml/)を完全に避けて、設定ファイルとGoソースのみ安全に置換
RUN find . -path "./ml" -prune -o -type f \( -name "*.go" -o -name "*.json" -o -name "*.txt" -o -name "CMakeLists.txt" \) -print | \
    xargs sed -i -e 's/3\.7/3.5/g' -e 's/\b37\b/35/g' -e 's/sm_37/sm_35/g' || true

# === ステージ2: CPU用ランナーのビルド ===
FROM base AS cpu
RUN cmake --preset 'CPU' \
    && cmake --build --parallel 4 --preset 'CPU' \
    && cmake --install build --component CPU --strip --parallel 4

# === ステージ3: CUDA 11用ランナーのビルド (K40cターゲット) ===
FROM base AS cuda-11
# 【強化】ダウンロード失敗を防ぐため、リトライ回数を20回、タイムアウトを300秒に延長する設定を追加
RUN echo "retries=20" >> /etc/dnf/dnf.conf \
    && echo "timeout=300" >> /etc/dnf/dnf.conf \
    && yum-config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel8/x86_64/cuda-rhel8.repo \
    && dnf install -y cuda-toolkit-11-8 \
    && dnf clean all
ENV PATH=/usr/local/cuda-11.8/bin:$PATH
RUN cmake --preset 'CUDA 11' -DOLLAMA_RUNNER_DIR="cuda_v11" \
    && cmake --build --parallel 4 --preset 'CUDA 11' \
    && cmake --install build --component CUDA --strip --parallel 4

# === ステージ4: Goバイナリ(本体)のビルド ===
FROM base AS build
# Go言語のインストール
RUN curl -fsSL https://golang.org/dl/go1.22.5.linux-amd64.tar.gz | tar xz -C /usr/local
ENV PATH=/usr/local/go/bin:$PATH
RUN go mod download
ENV CGO_ENABLED=1
RUN go build -trimpath -buildmode=pie -o /bin/ollama .

# === ステージ5: 最終イメージの作成 (Ubuntu 24.04) ===
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y ca-certificates && apt-get clean && rm -rf /var/lib/apt/lists/*

# 各ステージでビルドした成果物だけを集約
COPY --from=build /bin/ollama /usr/bin/ollama
COPY --from=cpu /go/src/github.com/ollama/ollama/dist/lib/ollama /usr/lib/ollama
COPY --from=cuda-11 /go/src/github.com/ollama/ollama/dist/lib/ollama /usr/lib/ollama

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV LD_LIBRARY_PATH=/usr/local/nvidia/lib:/usr/local/nvidia/lib64
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility
ENV NVIDIA_VISIBLE_DEVICES=all
ENV OLLAMA_HOST=0.0.0.0:11434

EXPOSE 11434
ENTRYPOINT ["/usr/bin/ollama"]
CMD ["serve"]