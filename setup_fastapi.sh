#!/bin/bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    printf "${GREEN}[INFO]${NC} %s\n" "$1"
}

warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$1"
}

error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1" >&2
}

ask() {
    local prompt="$1"
    local response
    read -p "$(printf "${YELLOW}[INPUT]${NC} %s: " "$prompt")" response
    echo "$response"
}

confirm() {
    local prompt="$1"
    while true; do
        read -p "$(printf "${YELLOW}[CONFIRM]${NC} %s [y/n]: " "$prompt")" yn
        case $yn in
            [Yy]* ) return 0 ;;
            [Nn]* ) return 1 ;;
            * ) printf "Please answer y or n.\n" ;;
        esac
    done
}

check_and_kill_port() {
    local port=$1
    local pid=$(lsof -t -i :"$port" 2>/dev/null || true)
    if [[ -n "$pid" ]]; then
        warn "Port $port is in use by PID(s): $pid"
        if confirm "Kill process on port $port?"; then
            kill -9 $pid && log "Killed process on port $port"
        else
            error "Port $port is busy. Cannot proceed."
            exit 1
        fi
    else
        log "Port $port is free."
    fi
}

ensure_dir() {
    if [[ ! -d "$1" ]]; then
        mkdir -p "$1"
        log "Created directory: $1"
    fi
}

main() {
    log "Starting DataHub API setup..."

    PROJECT_ROOT="$(pwd)/datahub-api"
    log "Project will be set up at: $PROJECT_ROOT"

    if [[ -d "$PROJECT_ROOT" ]] && [[ -n "$(ls -A "$PROJECT_ROOT" 2>/dev/null)" ]]; then
        if ! confirm "Directory '$PROJECT_ROOT' already exists and is non-empty. Overwrite?"; then
            error "Setup aborted by user."
            exit 1
        fi
        rm -rf "$PROJECT_ROOT"
    fi

    ensure_dir "$PROJECT_ROOT"

    echo
    printf "Select database type:\n"
    printf "1) PostgreSQL (default port: 5432)\n"
    printf "2) MySQL (default port: 3306)\n"
    printf "3) SQLite (file-based, no port)\n"

    local db_choice
    read -p "$(printf "${YELLOW}[INPUT]${NC} Choose database [1-3]: ")" db_choice

    case "${db_choice:-1}" in
        1)
            DB_TYPE="postgresql"
            DB_PORT=5432
            DB_DRIVER="psycopg2"
            ;;
        2)
            DB_TYPE="mysql"
            DB_PORT=3306
            DB_DRIVER="pymysql"
            ;;
        3)
            DB_TYPE="sqlite"
            DB_PORT=0
            DB_DRIVER=""
            ;;
        *)
            error "Invalid choice: $db_choice"
            exit 1
            ;;
    esac

    log "Selected database: $DB_TYPE"

    local DB_NAME DB_USER DB_PASS DB_HOST DB_URL

    if [[ "$DB_TYPE" == "sqlite" ]]; then
        DB_NAME="${DB_NAME:-datahub.db}"
        DB_HOST="localhost"
        DB_URL="sqlite:///./$DB_NAME"
    else
        DB_HOST=$(ask "Enter database host" || echo "localhost")
        
        local DB_PORT_INPUT
        DB_PORT_INPUT=$(ask "Enter database port (default: $DB_PORT)" || echo "$DB_PORT")
        DB_PORT=${DB_PORT_INPUT:-$DB_PORT}

        if ! [[ "$DB_PORT" =~ ^[0-9]+$ ]] || (( DB_PORT < 1 || DB_PORT > 65535 )); then
            error "Invalid port: $DB_PORT"
            exit 1
        fi

        check_and_kill_port "$DB_PORT"

        DB_NAME=$(ask "Enter database name" || echo "datahub")
        DB_USER=$(ask "Enter database user" || echo "datahub_user")
        DB_PASS=$(ask "Enter database password" || echo "datahub_pass")

        if [[ "$DB_TYPE" == "postgresql" ]]; then
            DB_URL="$DB_TYPE://$DB_USER:$DB_PASS@$DB_HOST:$DB_PORT/$DB_NAME"
        elif [[ "$DB_TYPE" == "mysql" ]]; then
            DB_URL="mysql+pymysql://$DB_USER:$DB_PASS@$DB_HOST:$DB_PORT/$DB_NAME"
        fi
    fi

    log "Creating project directory structure..."

    local dirs=(
        "$PROJECT_ROOT/app/api/v1/endpoints"
        "$PROJECT_ROOT/app/core"
        "$PROJECT_ROOT/app/db/migrations"
        "$PROJECT_ROOT/app/models"
        "$PROJECT_ROOT/app/schemas"
        "$PROJECT_ROOT/app/crud"
        "$PROJECT_ROOT/app/utils"
        "$PROJECT_ROOT/app/workers"
        "$PROJECT_ROOT/alembic/versions"
        "$PROJECT_ROOT/tests/test_api"
        "$PROJECT_ROOT/tests/test_models"
        "$PROJECT_ROOT/tests/test_utils"
        "$PROJECT_ROOT/uploads/datasets"
        "$PROJECT_ROOT/uploads/audio"
        "$PROJECT_ROOT/scripts"
    )

    for dir in "${dirs[@]}"; do
        ensure_dir "$dir"
    done

    find "$PROJECT_ROOT" -type d | while read -r dir; do
        init_file="$dir/__init__.py"
        if [[ ! -f "$init_file" ]]; then
            touch "$init_file"
            log "Created: $init_file"
        fi
    done

    local files=(
        "$PROJECT_ROOT/app/main.py"
        "$PROJECT_ROOT/app/api/v1/api.py"
        "$PROJECT_ROOT/app/api/v1/dependencies.py"
        "$PROJECT_ROOT/app/core/config.py"
        "$PROJECT_ROOT/app/core/security.py"
        "$PROJECT_ROOT/app/core/dependencies.py"
        "$PROJECT_ROOT/app/core/exceptions.py"
        "$PROJECT_ROOT/app/db/base.py"
        "$PROJECT_ROOT/app/db/base_class.py"
        "$PROJECT_ROOT/app/db/session.py"
        "$PROJECT_ROOT/app/db/init_db.py"
        "$PROJECT_ROOT/alembic/env.py"
        "$PROJECT_ROOT/alembic/script.py.mako"
        "$PROJECT_ROOT/tests/conftest.py"
        "$PROJECT_ROOT/run.py"
        "$PROJECT_ROOT/requirements.txt"
        "$PROJECT_ROOT/requirements-dev.txt"
        "$PROJECT_ROOT/Dockerfile"
        "$PROJECT_ROOT/docker-compose.yml"
        "$PROJECT_ROOT/Makefile"
        "$PROJECT_ROOT/README.md"
        "$PROJECT_ROOT/pyproject.toml"
        "$PROJECT_ROOT/scripts/create_initial_data.py"
        "$PROJECT_ROOT/scripts/backup_db.py"
    )

    for file in "${files[@]}"; do
        if [[ ! -f "$file" ]]; then
            touch "$file"
            log "Created file: $file"
        fi
    done

    local env_example="$PROJECT_ROOT/.env.example"
    local env_file="$PROJECT_ROOT/.env"

    if [[ ! -f "$env_example" ]]; then
        cat > "$env_example" << '_ENV_EXAMPLE_EOF_'
DATABASE_URL=sqlite:///./datahub.db
SECRET_KEY=your-super-secret-jwt-key-change-in-production
ALGORITHM=HS256
ACCESS_TOKEN_EXPIRE_MINUTES=30
_ENV_EXAMPLE_EOF_
        log "Created .env.example"
    fi

    if [[ ! -f "$env_file" ]]; then
        cp "$env_example" "$env_file"
        log "Created .env from .env.example"
    fi

    sed -i.bak "s|DATABASE_URL=.*|DATABASE_URL=$DB_URL|" "$env_file" && rm -f "$env_file.bak"
    log "Updated DATABASE_URL in .env"

    if [[ ! -f "$PROJECT_ROOT/.gitignore" ]]; then
        cat > "$PROJECT_ROOT/.gitignore" << '_GITIGNORE_EOF_'
__pycache__/
*.pyc
*.pyo
*.pyd
.Python
env/
venv/
.venv/
pip-log.txt
pip-delete-this-directory.txt
.pytest_cache/
.coverage
htmlcov/
dist/
build/
*.egg-info/
node_modules/
.DS_Store
.env
*.log
uploads/
.gitignore
*~
*.swp
.Git
_GITIGNORE_EOF_
        log "Created .gitignore"
    fi

    log "Setup completed successfully! 🎉"
    echo
    printf "Next steps:\n"
    printf "  cd datahub-api\n"
    printf "  python -m venv venv\n"
    printf "  source venv/bin/activate\n"
    printf "  pip install -r requirements.txt\n"
    printf "  alembic upgrade head\n"
    printf "  uvicorn app.main:app --reload\n"
    echo

    if [[ "$DB_TYPE" != "sqlite" ]]; then
        warn "Remember to start your $DB_TYPE server on port $DB_PORT."
    fi
}

main "$@"