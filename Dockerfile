# Copyright 2019 Marko Kohtala <marko.kohtala@okoko.fi>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# ARG usage documentation
# https://docs.docker.com/engine/reference/builder/#understand-how-arg-and-from-interact
ARG cpp=1.39.0
ARG proton=0.29.0
ARG qpidpython=1.37.0
ARG mirror=http://www.nic.funet.fi/pub/mirrors/apache.org/qpid
ARG upstream=https://www-eu.apache.org/dist/qpid
ARG home=/var/lib/qpidd
ARG CREATED
ARG SOURCE_COMMIT

# This can be a common base for all build dependencies
FROM buildpack-deps:buster AS builddeps

RUN set -ex; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends \
        cmake uuid-dev libboost-program-options-dev libboost-system-dev \
        libdb++-dev libaio-dev ruby libnss3-dev libsasl2-dev libxqilla-dev \
        libibverbs-dev librdmacm-dev \
        swig libjsoncpp-dev python-dev

COPY KEYS .
RUN gpg --import KEYS

WORKDIR /usr/src

# See https://github.com/opencontainers/image-spec/blob/master/annotations.md
LABEL fi.okoko.image.authors="Marko Kohtala <marko.kohtala@okoko.fi>"
LABEL fi.okoko.image.url="https://hub.docker.com/r/okoko/qpid-build"
LABEL fi.okoko.image.documentation="https://github.com/okoko/qpid-cpp-docker"
LABEL fi.okoko.image.source="https://github.com/okoko/qpid-cpp-docker"
LABEL fi.okoko.image.vendor="Software Consulting Kohtala Ltd"
LABEL fi.okoko.image.licenses="Apache-2.0"
LABEL fi.okoko.image.title="Apache Qpid C++ Broker"
LABEL fi.okoko.image.description="Apache Qpid build dependencies for development"


FROM builddeps AS build
ARG mirror
ARG upstream
ARG qpidpython
RUN set -ex ;\
    curl -fLOsS ${upstream}/python/${qpidpython}/qpid-python-${qpidpython}.tar.gz.asc ;\
    curl -fLOsS ${mirror}/python/${qpidpython}/qpid-python-${qpidpython}.tar.gz ;\
    gpg --verify qpid-python-${qpidpython}.tar.gz.asc qpid-python-${qpidpython}.tar.gz ;\
    tar zxf qpid-python-${qpidpython}.tar.gz

ARG proton
RUN set -ex ;\
    curl -fLOsS ${upstream}/proton/${proton}/qpid-proton-${proton}.tar.gz.asc ;\
    curl -fLOsS ${mirror}/proton/${proton}/qpid-proton-${proton}.tar.gz ;\
    gpg --verify qpid-proton-${proton}.tar.gz.asc qpid-proton-${proton}.tar.gz ;\
    tar zxf qpid-proton-${proton}.tar.gz

ARG cpp
RUN set -ex ;\
    curl -fLOsS ${upstream}/cpp/${cpp}/qpid-cpp-${cpp}.tar.gz.asc ;\
    curl -fLOsS ${mirror}/cpp/${cpp}/qpid-cpp-${cpp}.tar.gz ;\
    gpg --verify qpid-cpp-${cpp}.tar.gz.asc qpid-cpp-${cpp}.tar.gz ;\
    tar zxf qpid-cpp-${cpp}.tar.gz

RUN set -ex; \
    cd qpid-python-${qpidpython}; \
    python setup.py install

RUN set -ex; \
    cd qpid-proton-${proton}; \
    mkdir bld && cd bld; \
    cmake -DINCLUDE_INSTALL_DIR=/usr/include -DCMAKE_BUILD_TYPE=Release -DBUILD_CPP=OFF -DBUILD_TESTING=OFF -DSYSINSTALL_BINDINGS=ON .. ; \
    make -j $(($(nproc)+1)) all; \
    make install

COPY QPID-7709-cpp-uninit.patch .
RUN set -ex; \
    patch -p1 -d qpid-cpp-${cpp} < QPID-7709-cpp-uninit.patch ;\
    cd qpid-cpp-${cpp}; \
    mkdir bld && cd bld; \
    cmake -DSYSCONF_INSTALL_DIR=/etc -DCMAKE_BUILD_TYPE=Release -DBUILD_BINDING_PERL=OFF -DBUILD_DOCS=OFF -DBUILD_TESTING=OFF .. ; \
    make -j $(($(nproc)+1)) all; \
    make install
# This is some MS-SQL plugin selector that just gives annoying warning
RUN rm -f /usr/local/lib/qpid/daemon/store.so
# These Windows BAT files are a nuisance on command line completion
RUN rm -f /usr/local/bin/*.bat
# These are not needed after build, remove so they do not copy to production image
RUN rm -rf /usr/local/share/proton-*
RUN rm -rf /usr/local/include
RUN rm -rf /usr/local/share/qpid/examples

# List depended libraries in Debian
RUN ldd /usr/local/sbin/qpidd $(find /usr/local -name '*.so') | \
    sed -ne '\,\(/usr/local/\|not found\),!s/.* => \([^ ]*\) (.*/\1/p' | \
    sort -u | while read n ; do dpkg-query -S "$n" ; done | \
    sed 's/^\([^:]\+\):.*$/\1/' | sort -u > dependency.lst


FROM debian:10.1-slim AS qpid-cpp

ARG proton
ARG qpidpython
ARG cpp
ARG home
ENV QPID_PROTON_VERSION=${proton} \
    QPID_PYTHON_VERSION=${qpidpython} \
    QPID_CPP_VERSION=${cpp} \
# The scripts have hard coded default for QPID_TOOLS_HOME to /usr/share/qpid-tools
    QPID_TOOLS_HOME=/usr/local/share/qpid-tools \
# QPID_ prefix is reserved for overriding qpidd.conf settings
# https://github.com/scholzj/docker-qpid-cpp introduced these
    QPIDD_VERSION=${cpp} \
    QPIDD_HOME=${home} \
    QPIDD_DATA_DIR=${home}/work

# Add our user and group first to make sure their IDs get assigned
# consistently, regardless of whatever dependencies get added
RUN useradd --no-log-init --system --user-group --create-home --home-dir ${QPIDD_HOME} qpidd

# We need python for management tools like qpid-config
COPY --from=build /usr/src/dependency.lst .
RUN set -ex; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends --no-upgrade \
# Qpid CPP dependencies
        python-minimal $(cat dependency.lst) \
        ca-certificates libsasl2-modules \
# The docker-entrypoint.sh uses these
        libnss3-tools sasl2-bin \
    ; rm -rf dependency.lst /var/lib/apt/lists/*

# /usr/src/qpid-*/bld/install_manifext.txt contain most, but not all files to copy.
# Similarly I tried to use make install DESTDIR=/usr/src/install to gather
# files to one location to copy, but DESTDIR is not respected for all files installed.
COPY --from=build /usr/local /usr/local/
COPY --from=build /usr/lib/python2.7/dist-packages/*cproton* /usr/lib/python2.7/dist-packages/
COPY --from=build /usr/lib/python2.7/dist-packages/proton /usr/lib/python2.7/dist-packages/proton/
COPY --from=build /etc/qpid /etc/qpid/
COPY --from=build /etc/sasl2 /etc/sasl2/
COPY docker-entrypoint.sh /
# Update /etc/ld.so.cache so new libraries are found
RUN ldconfig

USER qpidd
RUN mkdir -p ${QPIDD_DATA_DIR}
VOLUME ["${QPIDD_HOME}"]
EXPOSE 5671 5672
ENTRYPOINT ["/docker-entrypoint.sh"]
# For AMQP 1.0 provide some simple policies for ease of use.
# The patterns are POSIX Basic regular expressions matching the address.
# Use ^ and $ to avoid match anywhere in middle of string.
CMD ["--topic-patterns", "^/topic/", "--queue-patterns", "^[^/]"]

ARG CREATED
ARG SOURCE_COMMIT
# See https://github.com/opencontainers/image-spec/blob/master/annotations.md
LABEL fi.okoko.image.authors="Marko Kohtala <marko.kohtala@okoko.fi>"
LABEL fi.okoko.image.url="https://hub.docker.com/r/okoko/qpid-cpp"
LABEL fi.okoko.image.documentation="https://github.com/okoko/qpid-cpp-docker"
LABEL fi.okoko.image.source="https://github.com/okoko/qpid-cpp-docker"
LABEL fi.okoko.image.vendor="Software Consulting Kohtala Ltd"
LABEL fi.okoko.image.licenses="Apache-2.0"
LABEL fi.okoko.image.title="Apache Qpid C++ Broker"
LABEL fi.okoko.image.description="Apache Qpid C++ AMQP Broker"
LABEL fi.okoko.image.created="${CREATED}"
LABEL fi.okoko.image.version="${cpp}"
LABEL fi.okoko.image.revision="${SOURCE_COMMIT}"
