# 第一阶段：编译阶段
FROM debian:bookworm-slim AS builder

# 设置工作目录
WORKDIR /usr/local/src

# 定义版本变量，方便后续维护
#NGINX最新稳定版 1.30.1，最新为主线版 1.31.0，这里请手动修改版本号
ARG NGINX_VERSION=1.31.0
ARG CRS_VERSION=4.26.0
ARG PCRE_VERSION=10.47
ARG MODSEC_VERSION=3.0.15
#从https://www.maxmind.com/注册用户获取 MAXMIND_ACCOUNT_ID 和 MAXMIND_LICENSE_KEY 的值
ARG MAXMIND_ACCOUNT_ID=111111
ARG MAXMIND_LICENSE_KEY=XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
# 安装编译所需的依赖
RUN apt-get update && apt-get install -y \
    git g++ make libtool automake autoconf \
    libcurl4-openssl-dev libxml2 libxml2-dev libxslt1-dev libgd-dev \
    libyajl-dev pkgconf liblmdb-dev libgeoip-dev libmaxminddb-dev \
    libfuzzy-dev liblua5.3-dev zlib1g-dev wget \
    ca-certificates curl\
    && rm -rf /var/lib/apt/lists/*

# 1. 编译 PCRE2
RUN wget https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE_VERSION}/pcre2-${PCRE_VERSION}.tar.gz && \
    tar -zxf pcre2-${PCRE_VERSION}.tar.gz && \
    cd pcre2-${PCRE_VERSION} && \
    ./configure --prefix=/usr/local --enable-unicode-properties --enable-jit && \
    make -j$(nproc) && make install

# 2. 克隆所有模块及源码 (自动获取最新版)
RUN git clone --recursive https://github.com/google/ngx_brotli.git && \
    git clone --depth 1 https://github.com/leev/ngx_http_geoip2_module.git && \
    git clone https://github.com/FRiCKLE/ngx_cache_purge.git && \
    git clone https://github.com/yaoweibin/ngx_http_substitutions_filter_module.git && \
    git clone https://github.com/arut/nginx-dav-ext-module.git && \
    git clone --depth 1 https://github.com/nginx/njs.git && \
    git clone --depth 1 https://github.com/openssl/openssl.git && \
    git clone --recursive --depth 1 https://github.com/owasp-modsecurity/ModSecurity.git && \
    git clone --depth 1 https://github.com/owasp-modsecurity/ModSecurity-nginx.git

# 3. 编译 ModSecurity 核心库
RUN cd ModSecurity && \
    ./build.sh && \
    ./configure --with-maxmind --with-yajl --with-lmdb --with-ssdeep --with-lua && \
    make -j$(nproc) && \
    make install

# 4. 下载并编译 Nginx 
RUN wget http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz && \
    tar -zxf nginx-${NGINX_VERSION}.tar.gz && \
    cd nginx-${NGINX_VERSION} && \
    ./configure \
        --user=nginx \
        --group=nginx \
        --prefix=/usr/local/nginx \
        --with-pcre=/usr/local/src/pcre2-${PCRE_VERSION} \
        --with-openssl=/usr/local/src/openssl \
        --add-module=/usr/local/src/ModSecurity-nginx \
        --add-module=/usr/local/src/ngx_brotli \
        --add-module=/usr/local/src/ngx_cache_purge \
        --add-module=/usr/local/src/ngx_http_geoip2_module \
        --add-module=/usr/local/src/ngx_http_substitutions_filter_module \
        --add-module=/usr/local/src/njs/nginx \
        --add-module=/usr/local/src/nginx-dav-ext-module \
        --with-mail \
        --with-mail_ssl_module \
        --with-stream \
        --with-stream_realip_module \
        --with-stream_ssl_module \
        --with-stream_ssl_preread_module \
        --with-http_stub_status_module \
        --with-http_ssl_module \
        --with-http_image_filter_module \
        --with-http_gzip_static_module \
        --with-http_gunzip_module \
        --with-http_sub_module \
        --with-http_flv_module \
        --with-http_addition_module \
        --with-http_realip_module \
        --with-http_mp4_module \
        --with-http_dav_module \
        --with-http_auth_request_module \
        --with-http_random_index_module \
        --with-http_secure_link_module \
        --with-http_slice_module \
        --with-http_v2_module \
        --with-http_v3_module \
        --with-threads \
        --with-file-aio \
        --with-compat \
    && make -j$(nproc) && make install

# 5. 下载 GeoIP 数据库
RUN mkdir -p /tmp/geoip && \
    curl -o /tmp/geoip/asn.tar.gz -L -u ${MAXMIND_ACCOUNT_ID}:${MAXMIND_LICENSE_KEY} 'https://download.maxmind.com/geoip/databases/GeoLite2-ASN/download?suffix=tar.gz' && \
    curl -o /tmp/geoip/city.tar.gz -L -u ${MAXMIND_ACCOUNT_ID}:${MAXMIND_LICENSE_KEY} 'https://download.maxmind.com/geoip/databases/GeoLite2-City/download?suffix=tar.gz' && \
    tar -zxf /tmp/geoip/asn.tar.gz -C /tmp/geoip --strip-components=1 --wildcards '*.mmdb' && \
    tar -zxf /tmp/geoip/city.tar.gz -C /tmp/geoip --strip-components=1 --wildcards '*.mmdb'

# 6. 拉取自定义配置仓库并整理
RUN git clone --depth 1 https://github.com/skyfzl/nginxconf.git /tmp/nginxconf && \
    mkdir -p /tmp/final_conf/scripts /tmp/final_conf/www /tmp/final_conf/modsec/crs && \
    cp /tmp/nginxconf/init.js /tmp/nginxconf/test.js /tmp/final_conf/scripts/ && \
    cp /tmp/nginxconf/default.conf /tmp/nginxconf/closeip.conf /tmp/nginxconf/examplehttps.conf.example /tmp/final_conf/www/ && \
    cp /tmp/nginxconf/nginx.conf /tmp/final_conf/ && \
    cp /tmp/nginxconf/modsecurity.conf /tmp/final_conf/modsec/

# 7. 获取 OWASP CRS (使用变量) 和 unicode.mapping
RUN wget https://github.com/coreruleset/coreruleset/archive/refs/tags/v${CRS_VERSION}.tar.gz && \
    tar -zxf v${CRS_VERSION}.tar.gz && \
    cp -r coreruleset-${CRS_VERSION}/rules /tmp/final_conf/modsec/crs/ && \
    cp coreruleset-${CRS_VERSION}/crs-setup.conf.example /tmp/final_conf/modsec/crs/crs-setup.conf && \
    cp /usr/local/src/ModSecurity/unicode.mapping /tmp/final_conf/modsec/

# 8. 创建 SSL 目录并生成自签名证书 (有效期 10 年)
RUN mkdir -p /tmp/final_conf/ssl && \
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /tmp/final_conf/ssl/fake.key \
    -out /tmp/final_conf/ssl/fake.crt \
    -subj "/C=CN/ST=Default/L=Default/O=Default/CN=localhost"

# --- 第二阶段：运行阶段 ---
FROM debian:bookworm-slim

ARG MODSEC_VERSION

# 1. 这里的合并是关键：安装 + 用户 + 目录 + 清理
RUN groupadd nginx && useradd -g nginx nginx && \
    apt-get update && apt-get install -y --no-install-recommends \
    libxml2 libxslt1.1 libgd3 libmaxminddb0 libgeoip1 \
    libyajl2 liblmdb0 libfuzzy2 liblua5.3-0 \
    curl ca-certificates binutils && \
    mkdir -p /usr/local/nginx/logs \
             /usr/local/nginx/proxy_temp/nginx_cache \
             /usr/local/nginx/conf/GeoIP \
             /usr/local/nginx/stream && \
    # 清理缓存是减小层体积的核心
    apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. 拷贝核心组件
COPY --from=builder --chown=nginx:nginx /usr/local/nginx /usr/local/nginx
COPY --from=builder /usr/local/lib/libpcre2-8.so* /usr/local/lib/
# 拷贝时使用变量
COPY --from=builder /usr/local/modsecurity/lib/libmodsecurity.so.${MODSEC_VERSION} /usr/local/lib/

# 3. 整理后的配置一键拷贝（假设你在 builder 整理到了 /tmp/dist）
# COPY --from=builder --chown=nginx:nginx /tmp/dist/ /usr/local/nginx/conf/

# 4. 执行瘦身与配置刷新
RUN ln -s /usr/local/lib/libmodsecurity.so.${MODSEC_VERSION} /usr/local/lib/libmodsecurity.so.3 && \
    strip --strip-unneeded /usr/local/lib/libmodsecurity.so.${MODSEC_VERSION} && \
    echo "/usr/local/lib" > /etc/ld.so.conf.d/custom.conf && \
    ldconfig && \
    ln -sf /dev/stdout /usr/local/nginx/logs/access.log && \
    ln -sf /dev/stderr /usr/local/nginx/logs/error.log && \
    # 彻底清理没用的工具
    apt-get purge -y binutils && apt-get autoremove -y

ENV PATH="/usr/local/nginx/sbin:$PATH"
WORKDIR /usr/local/nginx
EXPOSE 80 443
CMD ["nginx", "-g", "daemon off;"]
