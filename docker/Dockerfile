# InkyOS Buildroot builder.
# Bookworm matches Buildroot's own CI base, so host-tool compatibility is well tested.
# Pin by digest (debian:bookworm-slim@sha256:...) if you want full reproducibility.
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      bc \
      build-essential \
      ca-certificates \
      ccache \
      cmake \
      cpio \
      file \
      g++ \
      git \
      libncurses-dev \
      locales \
      make \
      patch \
      perl \
      python3 \
      rsync \
      sed \
      unzip \
      wget \
      which \
 && localedef -i en_US -c -f UTF-8 en_US.UTF-8 \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# A UTF-8 locale keeps menuconfig and glibc-toolchain builds happy.
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Buildroot refuses to run as root; the `br` wrapper passes --user with your host UID.
# Bookworm ships tar 1.34; if a package needs >= 1.35, Buildroot builds its own host-tar.
WORKDIR /work