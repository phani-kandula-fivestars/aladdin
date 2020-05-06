#!/usr/bin/env bash

# set -x
set -a
set -eu -o pipefail
# if user presses control-c, exit from script
function ctrl_trap(){ exit 1 ; }
trap ctrl_trap INT

# Set defaults on command line args
DEV=false
INIT=false
CLUSTER_CODE=minikube
NAMESPACE=default
IS_TERMINAL=true
SKIP_PROMPTS=false
KUBERNETES_VERSION="1.15.6"

# Set key directory paths
ALADDIN_DIR="$(cd "$(dirname "$0")" ; pwd)"
SCRIPT_DIR="$ALADDIN_DIR/scripts"
ALADDIN_PLUGIN_DIR=

ALADDIN_BIN="$HOME/.aladdin/bin"
PATH="$ALADDIN_BIN":"$PATH"

# Minikube defaults
DEFAULT_MINIKUBE_VM_DRIVER="virtualbox"
DEFAULT_MINIKUBE_MEMORY=4096
USING_HOST_DOCKER=false

source "$SCRIPT_DIR/shared.sh"

function get_config_path() {
    if [[ ! -f "$HOME/.aladdin/config/config.json" ]]; then
        echo "Unable to find config directory. Please use 'aladdin config set config_dir <config path location>' to set config directory"
        exit 1
    fi
    ALADDIN_CONFIG_DIR=$(jq -r .config_dir $HOME/.aladdin/config/config.json)
    if [[ "$ALADDIN_CONFIG_DIR" == null ]]; then
        echo "Unable to find config directory. Please use 'aladdin config set config_dir <config path location>' to set config directory"
        exit 1
    fi
    ALADDIN_CONFIG_FILE="$ALADDIN_CONFIG_DIR/config.json"
    ALADDIN_IMAGE="${IMAGE:-"$(jq -r '.aladdin.repo' "$ALADDIN_CONFIG_FILE"):$(jq -r '.aladdin.tag' "$ALADDIN_CONFIG_FILE")"}"
}

function get_plugin_dir() {
    if [[ -f "$HOME/.aladdin/config/config.json" ]]; then
        ALADDIN_PLUGIN_DIR=$(jq -r .plugin_dir $HOME/.aladdin/config/config.json)
        if [[ "$ALADDIN_PLUGIN_DIR" == null ]]; then
            ALADDIN_PLUGIN_DIR=
        fi
    fi
}

# Check for cluster name aliases and alias them accordingly
function check_cluster_alias() {
    cluster_alias=$(jq -r ".cluster_aliases[\"$CLUSTER_CODE\"]" "$ALADDIN_CONFIG_FILE")
    if [[ $cluster_alias != null ]]; then
        export CLUSTER_CODE=$cluster_alias
    fi
}

function check_and_handle_init() {
    # Check if we need to force initialization
    if ! test -f "$HOME/.aladdin/infra/installed"; then
        INIT=true
    fi
    if $INIT; then
        clear_cache_file
        "$SCRIPT_DIR"/infra_k8s_check.sh --force
        readonly repo_login_command="$(jq -r '.aladdin.repo_login_command' "$ALADDIN_CONFIG_FILE")"
        if [[ "$repo_login_command" != "null" ]]; then
            eval "$repo_login_command"
        fi
    else
        "$SCRIPT_DIR"/infra_k8s_check.sh
    fi
    if test -z $(docker images -q "$ALADDIN_IMAGE") || test -z "$(get_or_set_cache "${ALADDIN_IMAGE}")"; then
        docker pull "$ALADDIN_IMAGE"
        get_or_set_cache "${ALADDIN_IMAGE}" $(time_plus_offset 3600*24)
    fi

    # Use host docker if available
    if docker info > /dev/null 2>/dev/null; then
        case "$OSTYPE" in
            darwin*) USING_HOST_DOCKER=true ;;
        esac
        if $USING_HOST_DOCKER; then
            echo "Using host docker engine for aladdin"
        fi
    fi
    if [[ $CLUSTER_CODE == "minikube" || $USING_HOST_DOCKER == "false" ]]; then
        check_or_start_minikube
    fi
}

function set_minikube_config(){
    minikube config set kubernetes-version v$KUBERNETES_VERSION > /dev/null

    for key in vm_driver memory disk_size cpus; do
        local minikube_key=$(tr _ - <<< "$key")  # e.g., vm-driver
        local default_var="DEFAULT_MINIKUBE_$(tr a-z A-Z <<< "$key")"  # e.g., DEFAULT_MINIKUBE_VM_DRIVER

        local value=$(aladdin config get "minikube.$key" "${!default_var:-}")

        if test -n "$value"; then
            minikube config set "$minikube_key" "$value" > /dev/null
        fi
    done
}

function _start_minikube() {
    local minikube_cmd="minikube start"

    if test "$OSTYPE" = "linux-gnu"; then
        if test $(minikube config get vm-driver) = "none"; then
            # If we're running on native docker on a linux host, minikube start must happen as root
            # due to limitations in minikube.  Specifying CHANGE_MINIKUBE_NONE_USER causes minikube
            # to switch users to $SUDO_USER (the user that called sudo) before writing out
            # configuration.
            minikube_cmd="sudo -E CHANGE_MINIKUBE_NONE_USER=true '$(which minikube)' start"

        else
            # On linux, /home gets mounted on /hosthome in the minikube vm, so as not to
            # override /home/docker.  We still want the user's home directory to be in the
            # same path both in and outside the minikube vm though, so symlink it into place.
            minikube_cmd="$minikube_cmd &&\
                          minikube ssh \"sudo mkdir '$HOME' && \
                                         sudo mount --bind '${HOME/\/home//hosthome}' '$HOME'\""
        fi
    fi

    bash -c "$minikube_cmd"
}

# Start minikube if we need to
function check_or_start_minikube() {
    if ! minikube status | grep Running > /dev/null; then

        echo "Starting minikube... (this will take a moment)"
        set_minikube_config

        _start_minikube

        # Determine if we've installed our bootlocal.sh script to replace the vboxsf mounts with nfs mounts
        if ! "$(minikube ssh -- "test -x /var/lib/boot2docker/bootlocal.sh && echo -n true || echo -n false")"; then
            if test $(minikube config get vm-driver) != "none"; then
                echo "Installing NFS mounts from host..."
                "$SCRIPT_DIR"/install_nfs_mounts.sh
                echo "NFS mounts installed"
            fi
        fi
        echo "Minikube started"
    else
        if ! kubectl version | grep "Server" | grep "$KUBERNETES_VERSION" > /dev/null; then
            echo "Minikube detected on the incorrect version, stopping and restarting"
            minikube stop > /dev/null
            minikube delete > /dev/null
            set_minikube_config
            check_or_start_minikube
        fi
    fi
    if ! minikube addons list | grep "ingress " | grep enabled > /dev/null; then
        minikube addons enable ingress > /dev/null
    fi
    copy_ssh_to_minikube
    eval "$(minikube docker-env)"
}

function copy_ssh_to_minikube() {
    # Some systems fail when we directly mount the host's ~/.ssh directory into the aladdin container.
    # This allows us to move the ~/.ssh directory into minikube and later mount that directory (with
    # the adjusted ownernship and permissions) such that the container can leverage the user's
    # credentials for ssh operations.
    case "$OSTYPE" in
        cygwin*) # Cygwin under windows
            echo "Copying ~/.ssh into minikube"
            (
                minikube mount --ip 192.168.99.1 "$(cygpath -w ~/.ssh):/tmp/.ssh" &
                minikube ssh -- 'sudo rm -rf /.ssh && sudo cp -r /tmp/.ssh /.ssh && sudo chmod -R 600 /.ssh'
                kill $!
            ) >/dev/null
        ;;
    esac
}

function set_cluster_helper_vars() {
    IS_LOCAL="$(_extract_cluster_config_value is_local)"
    if [[ -z "$IS_LOCAL" ]]; then
        IS_LOCAL=false
    fi

    IS_PROD="$(_extract_cluster_config_value is_prod)"
    if [[ -z "$IS_PROD" ]]; then
        IS_PROD=false
    fi

    IS_TESTING="$(_extract_cluster_config_value is_testing)"
    if [[ -z "$IS_TESTING" ]]; then
        IS_TESTING=false
    fi
}

function exec_host_command() {
    local command_path

    command_path="$ALADDIN_DIR/commands/bash/host/$command/$command"
    if [[ -x "$command_path" ]]; then
        exec "$command_path" "$@"
    fi
}

function exec_host_plugin() {
    local plugin_path

    if [[ -n "$ALADDIN_PLUGIN_DIR" ]]; then
        plugin_path="$ALADDIN_PLUGIN_DIR/host/$command/$command"
        if [[ -x "$plugin_path" ]]; then
            exec "$plugin_path" "$@"
        fi
    fi
}

function pathnorm(){
    # Normalize the path, the path should exist
    typeset path="$1"
    echo "$(cd "$path" ; pwd)"
}

function confirm_production() {
    if $IS_TERMINAL ; then  # if this is an interactive shell and not jenkins or piped input, then verify
        echo "Script is running in a terminal. Let us make user aware that this is production";
        echo -ne '\033[;31mYou are on production. Please type "production" to continue: \033[0m'; read -r
        if [[ ! $REPLY = "production" ]]; then
            echo 'Exiting since you did not type production'
            exit 0
        fi
    else
        echo "This is production environment. This script is NOT running in a terminal, hence supressing user prompt to type 'production'";
    fi
}

function handle_ostypes() {
    case "$OSTYPE" in
        jenkins*|linux*|darwin*) # Running on jenkins/linux/osx
            true # use the default pathnorm
        ;;
        cygwin*) # Cygwin under windows
            function pathnorm(){
                # Normalize the path, the path should exist
                typeset path="$1"
                typeset abspath="$(cd "$path" ; pwd)"
                cygpath --mixed "$abspath" | sed 's%^C:/%/c/%g'
            }
        ;;
        win*|bsd*|solaris*) # Windows
            echo "Not sure how to launch docker here. Exiting ..."
            return 1
        ;;
        *)
            echo "unknown OS: $OSTYPE"
            echo "Not sure how to launch docker here. Exiting ..."
            return 1
        ;;
    esac
}

function enter_docker_container() {

    # if this is not production or staging, we are mounting kubernetes folder so that
    # config maps and other settings can be customized by developers
    local mounts=""
    if "$DEV"; then
        mounts="$mounts -v $(pathnorm "$ALADDIN_DIR"):/root/aladdin"
    fi
    if "$IS_LOCAL"; then
        mounts="$mounts -v $(pathnorm ~/.minikube):/root/.minikube"
    fi
    if "$IS_LOCAL" || "$DEV"; then
        mounts="$mounts -v /:/aladdin_root" # mount the whole minikube system
        mounts="$mounts --workdir /aladdin_root$(pathnorm "$PWD")"
    fi

    if [[ -n "$ALADDIN_PLUGIN_DIR" ]]; then
        ALADDIN_PLUGIN_CMD="-v $(pathnorm $ALADDIN_PLUGIN_DIR):/root/aladdin-plugins"
    fi

    if "$IS_PROD" && ! "$SKIP_PROMPTS"; then
        confirm_production
    fi

    FLAGS="--privileged --rm -i"
    # Set pseudo-tty only if aladdin is being run from a terminal
    if $IS_TERMINAL ; then
        FLAGS+="t"
    fi

    local ssh_src

    case "$OSTYPE" in
        cygwin*) ssh_src="/.ssh" ;;
        *)       ssh_src="$(pathnorm ~/.ssh)" ;;
    esac

    # How to mount docker parts
    mounts="$mounts -v /var/run/docker.sock:/var/run/docker.sock"
    if $USING_HOST_DOCKER ; then
        # Special case mounting host docker on linux/win?
        case "$OSTYPE" in
            *) true ;;
        esac
    fi

    docker run $FLAGS \
        `# Environment` \
        -e "DEV=$DEV" \
        -e "INIT=$INIT" \
        -e "CLUSTER_CODE=$CLUSTER_CODE" \
        -e "NAMESPACE=$NAMESPACE" \
        -e "IS_LOCAL=$IS_LOCAL" \
        -e "IS_PROD=$IS_PROD" \
        -e "IS_TESTING=$IS_TESTING" \
        -e "SKIP_PROMPTS=$SKIP_PROMPTS" \
        -e "command=$command" \
        `# Mount host credentials` \
        `# Mount destination for aws creds will not be /root/.aws because we will possibly make` \
        `# changes there that we don't want propagated on the host's ~/.aws` \
        -v "$(pathnorm ~/.aws):/root/tmp/.aws" \
        -v "${ssh_src}:/root/.ssh" \
        -v "$(pathnorm ~/.kube):/root/.kube_local" \
        -v "$(pathnorm ~/.aladdin):/root/.aladdin" \
        -v "$(pathnorm $ALADDIN_CONFIG_DIR):/root/aladdin-config" \
        `# Specific command` \
        $mounts ${ALADDIN_PLUGIN_CMD:-} \
        "$ALADDIN_IMAGE" \
        `# Finally, launch the command` \
        /root/aladdin/aladdin-container.sh "$@"
}

command="-h" # default command is help
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--cluster)
            CLUSTER_CODE="$2"
            shift # past argument
        ;;
        -n|--namespace)
            NAMESPACE="$2"
            shift # past argument
        ;;
        --image)
            IMAGE="$2"
            shift # past argument
        ;;
        -i|--init)
            INIT=true
        ;;
        --dev)
            DEV=true
        ;;
        --non-terminal)
            IS_TERMINAL=false
        ;;
        --skip-prompts)
            SKIP_PROMPTS=true
        ;;
        *)
            command="$1"
            shift
            break
        ;;
    esac
    shift # past argument or value
done

handle_ostypes
exec_host_command "$@"
get_config_path
get_plugin_dir
exec_host_plugin "$@"
check_cluster_alias
check_and_handle_init
set_cluster_helper_vars
enter_docker_container "$@"
