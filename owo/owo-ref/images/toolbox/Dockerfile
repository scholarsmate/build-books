ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY

ARG CI_UID=10001
ARG CI_GID=10001

ENV http_proxy="${HTTP_PROXY}" \
    https_proxy="${HTTPS_PROXY}" \
    no_proxy="${NO_PROXY}" \
    HTTP_PROXY="${HTTP_PROXY}" \
    HTTPS_PROXY="${HTTPS_PROXY}" \
    NO_PROXY="${NO_PROXY}" \
    DEBIAN_FRONTEND=noninteractive \
    SHELL="/bin/bash"

COPY squidCA.crt /usr/local/share/ca-certificates/
COPY ubuntu.sources /etc/apt/sources.list.d/
COPY pip.conf /etc/

SHELL ["/bin/bash", "-lc"]

RUN set -eux; \
    rm -f /etc/apt/sources.list; \
    echo 'APT::Install-Recommends "0";' > /etc/apt/apt.conf.d/01norecommend; \
    echo 'APT::Install-Suggests "0";'   >> /etc/apt/apt.conf.d/01norecommend; \
    \
    # If your internal apt endpoints are HTTPS via proxy MITM, help apt trust your CA early.
    # (This is harmless even if the mirror is plain HTTP.)
    mkdir -p /usr/local/share/ca-certificates; \
    chmod 755 /usr/local/share/ca-certificates; \
    \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates; \
    update-ca-certificates; \
    \
    apt-get install -y --no-install-recommends \
      bash \
      curl \
      docker.io \
      jq \
      git \
      openssl \
      coreutils \
      util-linux \
      findutils \
      grep \
      sed \
      strace \
      tar \
      tree \
      unzip \
      uuid-runtime \
      p7zip-full \
      python3 \
      python3-venv \
      python3-pip \
      build-essential \
      python3-dev \
      xz-utils \
      tzdata; \
    \
    groupadd -g "${CI_GID}" ci; \
    useradd --uid "${CI_UID}" --gid "${CI_GID}" --create-home --home-dir /home/ci --shell /bin/bash ci; \
    mkdir -p /workspace; \
    chown -R ci:ci /workspace; \
    \
    apt-get autoremove -y; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /root/.cache

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 TZ=UTC
WORKDIR /workspace
USER ci

CMD ["bash"]
