FROM golang:1.14-buster

# Remove the default $PS1 manipulation
RUN rm /etc/bash.bashrc

RUN apt-get update \
 && apt-get -y --no-install-recommends install \
    bash-completion \
    bats \
    gettext \
    groff \
    jq \
    less \
    python3 \
    python3-pip \
    python3-dev

# Default to python3, update setuptools and install wheel
RUN ln -fs /usr/bin/python3 /usr/local/bin/python \
 && ln -fs /usr/bin/pip3 /usr/local/bin/pip \
 && pip install --no-cache-dir setuptools==46.4.0 wheel==0.34.2

# This can take a bit of time, so we do it earlier in the build process
RUN go get -u -v sigs.k8s.io/aws-iam-authenticator/cmd/aws-iam-authenticator

# Update all needed tool versions here

ARG DOCKER_VERSION=18.09.7
RUN curl -L -o- https://download.docker.com/linux/static/stable/x86_64/docker-$DOCKER_VERSION.tgz | tar -zxvf - && cp docker/docker \
    /usr/bin/docker && chmod 755 /usr/bin/docker

ARG KUBE_VERSION=1.15.6
RUN	curl -L -o /bin/kubectl https://storage.googleapis.com/kubernetes-release/release/v$KUBE_VERSION/bin/linux/amd64/kubectl \
	&& chmod 755 /bin/kubectl

ARG HELM_VERSION=2.16.1
RUN	curl -L -o- https://storage.googleapis.com/kubernetes-helm/helm-v$HELM_VERSION-linux-amd64.tar.gz | tar -zxvf - && cp linux-amd64/helm \
	/bin/helm && chmod 755 /bin/helm && helm init --client-only

ARG KOPS_VERSION=1.15.0
RUN	curl -L -o /bin/kops https://github.com/kubernetes/kops/releases/download/$KOPS_VERSION/kops-linux-amd64 \
	&& chmod 755 /bin/kops

# Install edgectl
RUN curl -fL https://metriton.datawire.io/downloads/linux/edgectl -o /usr/local/bin/edgectl && chmod a+x /usr/local/bin/edgectl

# On some images "sh" is aliased to "dash" which does not support "set -o pipefail".
# We use the "exec" form of RUN to delegate this command to bash instead.
# This is all because we have a pipe in this command and we wish to fail the build
# if any command in the pipeline fails.
ARG POETRY_VERSION=1.0.10
RUN ["/bin/bash", "-c", "set -o pipefail && curl -sSL https://raw.githubusercontent.com/python-poetry/poetry/master/get-poetry.py | python"]
ENV PATH="/root/.poetry/bin:${PATH}"
COPY poetry.toml /root/.config/pypoetry/config.toml

# Add datawire helm repo
RUN helm repo add datawire https://www.getambassador.io

WORKDIR /root/aladdin

# Install aladdin python requirements
COPY pyproject.toml poetry.lock ./
COPY lib/build-components /root/aladdin/lib/build-components
RUN poetry install --no-root

# Install aladdin
COPY . /root/aladdin
ENV PATH="/root/.local/bin:/root:${PATH}"
