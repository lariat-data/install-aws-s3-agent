FROM --platform=linux/amd64 lariatdata/install-aws-base:latest

RUN pip3 install --no-deps ruamel.yaml
WORKDIR /workspace

COPY . /workspace

RUN chmod +x /workspace/init-and-apply.sh

ENTRYPOINT ["/workspace/init-and-apply.sh"]
