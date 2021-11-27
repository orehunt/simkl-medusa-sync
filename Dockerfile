FROM julia:alpine
    MAINTAINER orehunt <basso.bassista@gmail.com>

WORKDIR /project
VOLUME /config
ENV XDG_CACHE_HOME=/config

ADD . /project/
RUN julia --project=. build.jl

CMD julia --project=. run.jl
