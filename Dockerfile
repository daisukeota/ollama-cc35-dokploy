# === ステージ1: ビルド環境 ===
FROM nvidia/cuda:11.8.0-devel-ubuntu22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

# 必要な依存ツールのインストール
RUN apt-get update && apt-get install -y \
    curl \
    git \
    build-essential \
    cmake \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Go言語のインストール (Ollamaのビルドに必要)
RUN curl -fsSL https://golang.org/dl/go1.22.5.linux-amd64.tar.gz | tar -xz -C /usr/local
ENV PATH=$PATH:/usr/local/go/bin

WORKDIR /build

# 有志のCC3.7対応リポジトリをクローン
RUN git clone https://github.com/dogkeeper886/ollama37.git ollama

WORKDIR /build/ollama

# 【重要】K40c (CC 3.5) 向けにソースコードを置換修正
# 最低マイナーバージョン制限を 7 から 5 に書き換える
RUN sed -i 's/CudaComputeMinorMin = "7"/CudaComputeMinorMin = "5"/g' gpu/gpu.go

# ビルドターゲットを「sm_35 (CC 3.5)」のみに絞る
ENV CMAKE_CUDA_ARCHITECTURES="35"
ENV OLLAMA_CUSTOM_CUDA_ARCH="35"
ENV CGO_ENABLED=1

# 生成とコンパイルの実行
RUN go generate ./...
RUN go build -ldflags "-w -s -X=github.com/ollama/ollama/gpu.CudaMinVersion=3.5" -o /build/ollama_bin .

# === ステージ2: 実行用軽量環境 ===
FROM nvidia/cuda:11.8.0-runtime-ubuntu22.04

RUN apt-get update && apt-get install -y ca-certificates && apt-get clean && rm -rf /var/lib/apt/lists/*

# ビルドしたバイナリだけをコピー
COPY --from=builder /build/ollama_bin /bin/ollama

# 環境変数の設定
ENV OLLAMA_HOST=0.0.0.0:11434
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility
ENV NVIDIA_VISIBLE_DEVICES=all

EXPOSE 11434

ENTRYPOINT ["/bin/ollama"]
CMD ["serve"]