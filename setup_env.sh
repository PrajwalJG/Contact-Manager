#!/usr/bin/env bash

# Resolve workspace root (absolute path to directory of this script)
# Supports both bash/zsh and sourced/executed scenarios
if [ -n "$BASH_SOURCE" ]; then
    WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
elif [ -n "$ZSH_NAME" ]; then
    WORKSPACE_ROOT="$(cd "$(dirname "${(%):-%x}")" && pwd)"
else
    WORKSPACE_ROOT="$(cd "$(dirname "$0")" && pwd)"
fi

# Constants
DOCKERHUB_USER="${DOCKERHUB_USER:-pjgooli}"
IMAGE_NAME="devops-lab:latest"
REMOTE_IMAGE="docker.io/${DOCKERHUB_USER}/devops-lab:latest"
CONTAINER_NAME="devops-lab"
VOLUME_NAME="devops-jenkins-home"

# Determine if the script is being sourced
(return 0 2>/dev/null) && sourced=1 || sourced=0

install_container_engine() {
    echo "Neither podman nor docker was found on this system."
    
    # Check if we have sudo or are root
    local has_sudo=0
    if [ "$EUID" -eq 0 ]; then
        has_sudo=1
    elif command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
        has_sudo=1
    elif command -v sudo &>/dev/null; then
        has_sudo=2
    fi

    if [ "$has_sudo" -eq 0 ]; then
        echo "Error: Root or sudo privileges are required to install podman." >&2
        echo "Please ask your lab administrator to install 'podman' or 'docker'." >&2
        return 1
    fi

    echo "Would you like to automatically install Podman? (y/n)"
    local answer
    if [ "$sourced" -eq 1 ]; then
        read -p "Install Podman? [y/N]: " answer < /dev/tty
    else
        read -p "Install Podman? [y/N]: " answer
    fi

    if [[ "$answer" =~ ^[Yy]$ ]]; then
        echo "Attempting to install Podman..."
        if command -v apt-get &>/dev/null; then
            echo "Running: sudo apt-get update && sudo apt-get install -y podman"
            sudo apt-get update && sudo apt-get install -y podman
        elif command -v dnf &>/dev/null; then
            echo "Running: sudo dnf install -y podman"
            sudo dnf install -y podman
        elif command -v yum &>/dev/null; then
            echo "Running: sudo yum install -y podman"
            sudo yum install -y podman
        elif command -v pacman &>/dev/null; then
            echo "Running: sudo pacman -S --noconfirm podman"
            sudo pacman -S --noconfirm podman
        else
            echo "Error: Unsupported package manager. Please install Podman manually." >&2
            return 1
        fi

        # Re-verify installation
        if command -v podman &>/dev/null; then
            echo "Podman installed successfully!"
            CONTAINER_ENGINE="podman"
            return 0
        else
            echo "Error: Podman installation finished but 'podman' executable is still not found." >&2
            return 1
        fi
    else
        echo "Installation cancelled. Please install 'podman' or 'docker' manually." >&2
        return 1
    fi
}

detect_engine() {
    # 1. Try Podman first (preferred, rootless)
    if command -v podman &>/dev/null; then
        if podman ps &>/dev/null; then
            CONTAINER_ENGINE="podman"
            return 0
        else
            echo "Warning: podman is installed but 'podman ps' failed." >&2
        fi
    fi

    # 2. Try Docker
    if command -v docker &>/dev/null; then
        if docker ps &>/dev/null; then
            CONTAINER_ENGINE="docker"
            return 0
        else
            echo "Warning: docker is installed but the Docker daemon is not running or you do not have permission." >&2
            if command -v systemctl &>/dev/null; then
                echo "--> You may need to start the docker daemon: sudo systemctl start docker" >&2
                echo "--> Or add your user to the docker group:   sudo usermod -aG docker \$USER (then log out and log back in)" >&2
            fi
        fi
    fi

    # 3. If neither works, try installing Podman
    if install_container_engine; then
        return 0
    fi

    return 1
}

# Run the detection
if ! detect_engine; then
    echo "Error: Container engine is missing or unusable. Cannot proceed." >&2
    (return 1 2>/dev/null) || exit 1
fi


show_help() {
    echo "Usage: $0 [command] [args...]"
    echo ""
    echo "Commands:"
    echo "  build         Build the DevOps lab container image"
    echo "  push [user]   Push the image to Docker Hub (default user: $DOCKERHUB_USER)"
    echo "  start         Start the container in the background (Jenkins on port 8080)"
    echo "  stop          Stop and remove the container (preserves Jenkins data volume)"
    echo "  status        Show the container status and Jenkins URL"
    echo "  run [cmd...]  Run a command inside the container in the current directory context"
    echo "  shell         Open an interactive bash shell in the container"
    echo "  help          Show this help message"
}

ensure_running() {
    if ! $CONTAINER_ENGINE ps --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}$"; then
        # Check if container exists but is stopped
        if $CONTAINER_ENGINE ps -a --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}$"; then
            echo "Container is stopped. Starting it now..."
            $CONTAINER_ENGINE start "$CONTAINER_NAME" >/dev/null
            sleep 1
        else
            echo "Error: Container '$CONTAINER_NAME' does not exist." >&2
            echo "Please run '$0 start' first to create and run it." >&2
            (return 1 2>/dev/null) || exit 1
        fi
    fi
}

get_container_work_dir() {
    local current_dir
    current_dir="$(pwd)"
    if [[ "$current_dir" == "$HOME"* ]]; then
        echo "$current_dir"
    elif [[ "$current_dir" == "$WORKSPACE_ROOT"* ]]; then
        local rel_path="${current_dir#$WORKSPACE_ROOT}"
        rel_path="${rel_path#/}"
        if [ -n "$rel_path" ]; then
            echo "/workspace/$rel_path"
        else
            echo "/workspace"
        fi
    else
        echo "/workspace"
    fi
}


# Ensure wrapper binaries exist in bin/
ensure_wrappers() {
    local bin_dir="$WORKSPACE_ROOT/bin"
    mkdir -p "$bin_dir"

    # mvn wrapper
    if [ ! -f "$bin_dir/mvn" ]; then
        echo "Creating wrapper $bin_dir/mvn..."
        cat << 'EOF' > "$bin_dir/mvn"
#!/usr/bin/env bash
WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$WORKSPACE_ROOT/setup_env.sh" run mvn "$@"
EOF
        chmod +x "$bin_dir/mvn"
    fi

    # gradle wrapper
    if [ ! -f "$bin_dir/gradle" ]; then
        echo "Creating wrapper $bin_dir/gradle..."
        cat << 'EOF' > "$bin_dir/gradle"
#!/usr/bin/env bash
WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$WORKSPACE_ROOT/setup_env.sh" run gradle "$@"
EOF
        chmod +x "$bin_dir/gradle"
    fi

    # ansible wrapper
    if [ ! -f "$bin_dir/ansible" ]; then
        echo "Creating wrapper $bin_dir/ansible..."
        cat << 'EOF' > "$bin_dir/ansible"
#!/usr/bin/env bash
WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$WORKSPACE_ROOT/setup_env.sh" run ansible "$@"
EOF
        chmod +x "$bin_dir/ansible"
    fi
}

execute_cmd() {
    case "$1" in
        build)
            echo "Building container image '$IMAGE_NAME' using $CONTAINER_ENGINE..."
            $CONTAINER_ENGINE build -t "$IMAGE_NAME" "$WORKSPACE_ROOT"
            ;;
        push)
            shift
            target_user="${1:-$DOCKERHUB_USER}"
            target_image="docker.io/${target_user}/devops-lab:latest"
            echo "Tagging local image '$IMAGE_NAME' as '$target_image'..."
            if ! $CONTAINER_ENGINE tag "$IMAGE_NAME" "$target_image"; then
                echo "Error: Tagging failed. Make sure the local image is built first with '$0 build'." >&2
                (return 1 2>/dev/null) || exit 1
            fi
            echo "Pushing image '$target_image' to Docker Hub..."
            echo "Make sure you are logged in (using '$CONTAINER_ENGINE login') first."
            if $CONTAINER_ENGINE push "$target_image"; then
                echo "Successfully pushed '$target_image' to Docker Hub!"
            else
                echo "Error: Pushing failed. Check your login status and credentials." >&2
                (return 1 2>/dev/null) || exit 1
            fi
            ;;
        start)
            # Default ports
            host_port="${JENKINS_PORT:-8080}"
            host_jnlp_port="${JENKINS_JNLP_PORT:-50000}"

            # Determine which image to run. Try local first, then remote, then pull, then fallback to build.
            running_image="$IMAGE_NAME"
            if ! $CONTAINER_ENGINE image inspect "$IMAGE_NAME" &>/dev/null; then
                if $CONTAINER_ENGINE image inspect "$REMOTE_IMAGE" &>/dev/null; then
                    running_image="$REMOTE_IMAGE"
                else
                    echo "Local image '$IMAGE_NAME' not found. Attempting to pull '$REMOTE_IMAGE'..."
                    if $CONTAINER_ENGINE pull "$REMOTE_IMAGE"; then
                        running_image="$REMOTE_IMAGE"
                    else
                        echo "Could not pull remote image. Building locally..."
                        execute_cmd build || (return 1 2>/dev/null) || exit 1
                    fi
                fi
            fi

            # Check if volume exists, create if not
            if ! $CONTAINER_ENGINE volume inspect "$VOLUME_NAME" &>/dev/null; then
                echo "Creating named volume '$VOLUME_NAME' for persistent Jenkins data..."
                $CONTAINER_ENGINE volume create "$VOLUME_NAME" >/dev/null
            fi

            # Check if container is running or exists
            if $CONTAINER_ENGINE ps -a --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}$"; then
                if ! $CONTAINER_ENGINE ps --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}$"; then
                    echo "Starting existing container '$CONTAINER_NAME'..."
                    $CONTAINER_ENGINE start "$CONTAINER_NAME" >/dev/null
                else
                    echo "Container '$CONTAINER_NAME' is already running."
                fi
            else
                # Check if port is in use (by looking for exact port binding in ss output)
                if command -v ss &>/dev/null && ss -lptn 2>/dev/null | grep -Eq ":${host_port}\s"; then
                    echo "Error: Port $host_port is already in use on the host system." >&2
                    echo "You can run Jenkins on a different port by setting the JENKINS_PORT environment variable." >&2
                    echo "Example: JENKINS_PORT=9090 ./setup_env.sh" >&2
                    (return 1 2>/dev/null) || exit 1
                fi

                echo "Starting new container '$CONTAINER_NAME' on port $host_port..."
                # Run container as root to match permissions in rootless container runtimes
                $CONTAINER_ENGINE run -d \
                    --name "$CONTAINER_NAME" \
                    -p "$host_port":8080 \
                    -p "$host_jnlp_port":50000 \
                    -v "$VOLUME_NAME":/var/jenkins_home \
                    -v "$WORKSPACE_ROOT":/workspace:Z \
                    -v "$HOME":"$HOME":z \
                    --workdir /workspace \
                    "$running_image" >/dev/null
            fi
            echo "Jenkins is starting up in the background."
            active_port=$($CONTAINER_ENGINE port "$CONTAINER_NAME" 8080/tcp 2>/dev/null | sed 's/.*://')
            [ -z "$active_port" ] && active_port="$host_port"
            echo "It will be accessible shortly at: http://localhost:$active_port"
            ;;
        stop)
            if $CONTAINER_ENGINE ps -a --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}$"; then
                echo "Stopping container '$CONTAINER_NAME'..."
                $CONTAINER_ENGINE stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
                echo "Removing container '$CONTAINER_NAME'..."
                $CONTAINER_ENGINE rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
                echo "Container stopped and removed successfully."
            else
                echo "Container '$CONTAINER_NAME' is not running or created."
            fi
            ;;
        status)
            if $CONTAINER_ENGINE ps --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}$"; then
                active_port=$($CONTAINER_ENGINE port "$CONTAINER_NAME" 8080/tcp 2>/dev/null | sed 's/.*://')
                [ -z "$active_port" ] && active_port="8080"
                echo "Status: RUNNING"
                echo "Engine: $CONTAINER_ENGINE"
                echo "Jenkins URL: http://localhost:$active_port"
            elif $CONTAINER_ENGINE ps -a --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}$"; then
                echo "Status: STOPPED"
            else
                echo "Status: NOT CREATED"
            fi
            ;;
        run)
            shift
            if [ $# -eq 0 ]; then
                echo "Error: No command specified to run." >&2
                (return 1 2>/dev/null) || exit 1
            fi
            ensure_running
            work_dir=$(get_container_work_dir)
            exec $CONTAINER_ENGINE exec -w "$work_dir" -it "$CONTAINER_NAME" "$@"
            ;;
        shell)
            ensure_running
            work_dir=$(get_container_work_dir)
            exec $CONTAINER_ENGINE exec -w "$work_dir" -it "$CONTAINER_NAME" bash
            ;;
        help)
            show_help
            ;;
        *)
            show_help
            (return 1 2>/dev/null) || exit 1
            ;;
    esac
}

# If arguments are passed, execute the command and exit
if [ $# -gt 0 ]; then
    execute_cmd "$@"
    # Only exit if not sourced, otherwise return
    if [ "$sourced" -eq 1 ]; then
        return 0 2>/dev/null
    else
        exit 0
    fi
fi

# No arguments: standard setup mode
echo "Initializing DevOps containerized environment..."
ensure_wrappers
if ! execute_cmd start; then
    echo "Error: Failed to initialize the DevOps container environment." >&2
    (return 1 2>/dev/null) || exit 1
fi

if [ "$sourced" -eq 1 ]; then
    # Add bin/ to PATH if not already present
    BIN_DIR="$WORKSPACE_ROOT/bin"
    if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
        export PATH="$BIN_DIR:$PATH"
        echo "--> Added wrapper binaries to PATH: $BIN_DIR"
    fi
    echo "Environment fully configured. You can now run 'mvn', 'gradle', and 'ansible' commands directly!"
else
    echo ""
    echo "========================================================================"
    echo " DevOps container successfully started!"
    echo " Jenkins is launching in the background."
    echo ""
    echo " NOTE: You did not 'source' this script, so your command wrappers"
    echo " (mvn, gradle, ansible) are NOT loaded in this shell session."
    echo ""
    echo " To load them, please run:"
    echo "     source setup_env.sh"
    echo "========================================================================"
fi
