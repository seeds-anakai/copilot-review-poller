FROM public.ecr.aws/lambda/python:3.13

RUN microdnf install -y tar gzip && \
    curl -LO https://github.com/cli/cli/releases/download/v2.74.0/gh_2.74.0_linux_arm64.tar.gz && \
    tar -xf gh_2.74.0_linux_arm64.tar.gz && \
    mv gh_*/bin/gh /usr/local/bin && \
    rm -rf gh_*

ENV GH_CONFIG_DIR=/tmp/.config/gh

COPY app.py ${LAMBDA_TASK_ROOT}

CMD ["app.handler"]
