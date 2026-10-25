# This Dockerfile is for using the safe_docker scripts
#FROM ubuntu:22.04
FROM debian:12-slim

LABEL maintainer="Falk Herwig"

# one layer, so that a cached build never installs from a stale package list;
# emacs-nox is emacs without the GTK and X11 libraries, which we do not need
RUN apt-get update && \
    apt-get -y install --no-install-recommends emacs-nox openssl && \
    apt-get autoremove --yes && apt-get clean all && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# bd and crypt.sh, owned by root: on the PATH in the container, and the
# user cannot change them
COPY --chmod=755 safe_tools/bd safe_tools/crypt.sh /usr/local/bin/

RUN useradd -d /home/user -m -c "" user
RUN chown -R user:user /home/user && \
    chmod -R 775 /home/user/
USER user
ENV HOME=/home/user
WORKDIR /home/user
