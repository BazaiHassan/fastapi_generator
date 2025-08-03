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
            DB_DRIVER="psycopg2-binary"
            ;;
        2)
            DB_TYPE="mysql"
            DB_PORT=3306
            DB_DRIVER="PyMySQL"
            ;;
        3)
            DB_TYPE="sqlite"
            DB_PORT=0
            DB_DRIVER="pysqlite3"
            ;;
        *)
            error "Invalid choice: $db_choice"
            exit 1
            ;;
    esac

    log "Selected database: $DB_TYPE"

    local DB_NAME DB_USER DB_PASS DB_HOST DB_URL

    if [[ "$DB_TYPE" == "sqlite" ]]; then
        DB_NAME=$(ask "Enter SQLite database filename" || echo "datahub.db")
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
            DB_URL="postgresql://$DB_USER:$DB_PASS@$DB_HOST:$DB_PORT/$DB_NAME"
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

    # Create __init__.py in all directories
    find "$PROJECT_ROOT" -type d | while read -r dir; do
        init_file="$dir/__init__.py"
        if [[ ! -f "$init_file" ]]; then
            touch "$init_file"
            log "Created: $init_file"
        fi
    done

    log "Writing templated content to files..."

    # app/main.py
    cat > "$PROJECT_ROOT/app/main.py" << 'EOF'
from fastapi import FastAPI
from app.api.v1.api import api_router
from app.core.config import settings

app = FastAPI(
    title=settings.PROJECT_NAME,
    openapi_url=f"{settings.API_V1_STR}/openapi.json"
)

app.include_router(api_router, prefix=settings.API_V1_STR)

@app.get("/")
def read_root():
    return {"message": "Welcome to DataHub API"}
EOF
    log "Created file: $PROJECT_ROOT/app/main.py"

    # app/api/v1/api.py
    cat > "$PROJECT_ROOT/app/api/v1/api.py" << 'EOF'
from fastapi import APIRouter

api_router = APIRouter()

@api_router.get("/health")
def health_check():
    return {"status": "healthy"}
EOF
    log "Created file: $PROJECT_ROOT/app/api/v1/api.py"

    # app/api/v1/dependencies.py
    cat > "$PROJECT_ROOT/app/api/v1/dependencies.py" << 'EOF'
from fastapi import Depends, HTTPException, status
from typing import Annotated

# Example reusable dependency
def get_current_user():
    # Placeholder for auth logic
    return {"user_id": 1, "username": "johndoe"}
EOF
    log "Created file: $PROJECT_ROOT/app/api/v1/dependencies.py"

    # app/core/config.py
    cat > "$PROJECT_ROOT/app/core/config.py" << 'EOF'
from pydantic_settings import BaseSettings
from pydantic import Field

class Settings(BaseSettings):
    PROJECT_NAME: str = "DataHub API"
    API_V1_STR: str = "/api/v1"
    SECRET_KEY: str = "your-super-secret-jwt-key-change-in-production"
    ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 30
    DATABASE_URL: str

    class Config:
        env_file = ".env"

settings = Settings()
EOF
    log "Created file: $PROJECT_ROOT/app/core/config.py"

    # app/core/security.py
    cat > "$PROJECT_ROOT/app/core/security.py" << 'EOF'
from datetime import datetime, timedelta
from typing import Optional
from jose import jwt, JWTError

from app.core.config import settings

def create_access_token(data: dict, expires_delta: Optional[timedelta] = None):
    to_encode = data.copy()
    expire = datetime.utcnow() + (expires_delta or timedelta(minutes=15))
    to_encode.update({"exp": expire})
    return jwt.encode(to_encode, settings.SECRET_KEY, algorithm=settings.ALGORITHM)

def decode_access_token(token: str) -> Optional[dict]:
    try:
        return jwt.decode(token, settings.SECRET_KEY, algorithms=[settings.ALGORITHM])
    except JWTError:
        return None
EOF
    log "Created file: $PROJECT_ROOT/app/core/security.py"

    # app/core/dependencies.py
    cat > "$PROJECT_ROOT/app/core/dependencies.py" << 'EOF'
from fastapi import Depends, HTTPException, status
from typing import Generator
from sqlalchemy.orm import Session

from app.db.session import SessionLocal
from app.core.security import decode_access_token

def get_db() -> Generator:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

def get_current_user(db: Session = Depends(get_db), token: str = ""):
    payload = decode_access_token(token)
    if not payload:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid authentication credentials",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return {"user_id": payload.get("sub"), "username": payload.get("username")}
EOF
    log "Created file: $PROJECT_ROOT/app/core/dependencies.py"

    # app/core/exceptions.py
    cat > "$PROJECT_ROOT/app/core/exceptions.py" << 'EOF'
from fastapi import HTTPException

def http_404(detail="Item not found"):
    return HTTPException(status_code=404, detail=detail)

def http_400(detail="Bad request"):
    return HTTPException(status_code=400, detail=detail)
EOF
    log "Created file: $PROJECT_ROOT/app/core/exceptions.py"

    # app/db/base_class.py
    cat > "$PROJECT_ROOT/app/db/base_class.py" << 'EOF'
from sqlalchemy.ext.declarative import declarative_base

Base = declarative_base()
EOF
    log "Created file: $PROJECT_ROOT/app/db/base_class.py"

    # app/db/base.py
    cat > "$PROJECT_ROOT/app/db/base.py" << 'EOF'
# Import all models here so Alembic can detect them
from app.models.user import User  # noqa
EOF
    log "Created file: $PROJECT_ROOT/app/db/base.py"

    # app/db/session.py
    cat > "$PROJECT_ROOT/app/db/session.py" << 'EOF'
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, Session
from typing import Generator
from app.core.config import settings

engine = create_engine(settings.DATABASE_URL)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

def get_db_session() -> Session:
    return SessionLocal()

# Dependency
def get_db() -> Generator:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
EOF
    log "Created file: $PROJECT_ROOT/app/db/session.py"

    # app/db/init_db.py
    cat > "$PROJECT_ROOT/app/db/init_db.py" << 'EOF'
from app.db.session import get_db_session
from app.models.user import User
from sqlalchemy import select

def init_db():
    db = get_db_session()
    # Create initial data here
    result = db.execute(select(User).where(User.email == "admin@example.com"))
    if not result.first():
        user = User(
            email="admin@example.com",
            hashed_password="fakehashed-secret",
            is_active=True,
            full_name="Admin User"
        )
        db.add(user)
        db.commit()
    db.close()
EOF
    log "Created file: $PROJECT_ROOT/app/db/init_db.py"

    # app/models/user.py
    cat > "$PROJECT_ROOT/app/models/user.py" << 'EOF'
from sqlalchemy import Column, Integer, String, Boolean
from app.db.base_class import Base

class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, index=True)
    email = Column(String(100), unique=True, index=True, nullable=False)
    hashed_password = Column(String(255), nullable=False)
    is_active = Column(Boolean, default=True)
    full_name = Column(String(100), nullable=True)
EOF
    log "Created file: $PROJECT_ROOT/app/models/user.py"

    # alembic/env.py
    cat > "$PROJECT_ROOT/alembic/env.py" << 'EOF'
from logging.config import fileConfig
from sqlalchemy import engine_from_config, pool
from alembic import context

from app.core.config import settings
from app.db.base_class import Base

config = context.config
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

target_metadata = Base.metadata
config.set_main_option("sqlalchemy.url", settings.DATABASE_URL)

def run_migrations_online():
    connectable = engine_from_config(
        config.get_section(config.config_ini_section),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )
    with connectable.connect() as connection:
        context.configure(connection=connection, target_metadata=target_metadata)
        with context.begin_transaction():
            context.run_migrations()

run_migrations_online()
EOF
    log "Created file: $PROJECT_ROOT/alembic/env.py"

    # alembic/script.py.mako
    touch "$PROJECT_ROOT/alembic/script.py.mako"
    log "Created file: $PROJECT_ROOT/alembic/script.py.mako"

    # tests/conftest.py
    cat > "$PROJECT_ROOT/tests/conftest.py" << 'EOF'
import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, Session
from app.db.base_class import Base

@pytest.fixture(scope="session")
def db_engine():
    engine = create_engine("sqlite:///:memory:", connect_args={"check_same_thread": False})
    Base.metadata.create_all(bind=engine)
    yield engine
    Base.metadata.drop_all(bind=engine)

@pytest.fixture(scope="function")
def db_session(db_engine):
    connection = db_engine.connect()
    transaction = connection.begin()
    Session = sessionmaker(bind=connection)
    session = Session()
    yield session
    session.close()
    transaction.rollback()
    connection.close()
EOF
    log "Created file: $PROJECT_ROOT/tests/conftest.py"

    # run.py
    cat > "$PROJECT_ROOT/run.py" << 'EOF'
import uvicorn

if __name__ == "__main__":
    uvicorn.run("app.main:app", host="0.0.0.0", port=8000, reload=True)
EOF
    log "Created file: $PROJECT_ROOT/run.py"

    # requirements.txt
    cat > "$PROJECT_ROOT/requirements.txt" << 'EOF'
fastapi>=0.110.0
uvicorn>=0.27.0
sqlalchemy>=2.0.0
pydantic-settings>=2.0.0
python-jose[cryptography]
passlib[bcrypt]
python-multipart
jinja2
alembic
EOF
    log "Created file: $PROJECT_ROOT/requirements.txt"

    # requirements-dev.txt
    cat > "$PROJECT_ROOT/requirements-dev.txt" << EOF
-r requirements.txt
pytest>=8.0.0
pytest-cov
black
isort
flake8
$DB_DRIVER
EOF
    log "Created file: $PROJECT_ROOT/requirements-dev.txt"

    # Dockerfile
    cat > "$PROJECT_ROOT/Dockerfile" << 'EOF'
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
EOF
    log "Created file: $PROJECT_ROOT/Dockerfile"

    # docker-compose.yml
    if [[ "$DB_TYPE" == "sqlite" ]]; then
        cat > "$PROJECT_ROOT/docker-compose.yml" << EOF
version: '3.8'

services:
  api:
    build: .
    ports:
      - "8000:8000"
    environment:
      - DATABASE_URL=$DB_URL
    env_file:
      - .env
    volumes:
      - ./uploads:/app/uploads
      - ./datahub.db:/app/datahub.db

volumes:
  db_data:
EOF
    else
        local db_image="postgres:15"
        local db_port_map="5432:5432"
        local db_env_vars=""

        if [[ "$DB_TYPE" == "postgresql" ]]; then
            db_env_vars="      - POSTGRES_DB=$DB_NAME
      - POSTGRES_USER=$DB_USER
      - POSTGRES_PASSWORD=$DB_PASS"
        elif [[ "$DB_TYPE" == "mysql" ]]; then
            db_image="mysql:8.0"
            db_port_map="3306:3306"
            db_env_vars="      - MYSQL_DATABASE=$DB_NAME
      - MYSQL_USER=$DB_USER
      - MYSQL_PASSWORD=$DB_PASS
      - MYSQL_ROOT_PASSWORD=rootpass"
        fi

        cat > "$PROJECT_ROOT/docker-compose.yml" << EOF
version: '3.8'

services:
  api:
    build: .
    ports:
      - "8000:8000"
    environment:
      - DATABASE_URL=$DB_URL
    env_file:
      - .env
    depends_on:
      - db
    volumes:
      - ./uploads:/app/uploads

  db:
    image: $db_image
    environment:
$db_env_vars
    ports:
      - "$db_port_map"
    volumes:
      - db_data:/var/lib/$DB_TYPE/data

volumes:
  db_data:
EOF
    fi
    log "Created file: $PROJECT_ROOT/docker-compose.yml"

    # Makefile
    cat > "$PROJECT_ROOT/Makefile" << 'EOF'
.PHONY: install dev migrate migrate-make test lint

install:
	pip install -r requirements.txt

dev:
	uvicorn app.main:app --reload --host 0.0.0.0 --port 8000

migrate:
	alembic upgrade head

migrate-make:
	alembic revision --autogenerate -m "auto"

test:
	pytest -v tests/

lint:
	black . && isort .

backup-db:
	python scripts/backup_db.py
EOF
    log "Created file: $PROJECT_ROOT/Makefile"

    # README.md
    cat > "$PROJECT_ROOT/README.md" << 'EOF'
# DataHub API

FastAPI backend for DataHub project.

## Setup

```bash
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
alembic upgrade head
uvicorn app.main:app --reload
```
EOF
    log "Created file: $PROJECT_ROOT/README.md"

    # pyproject.toml
    cat > "$PROJECT_ROOT/pyproject.toml" << 'EOF'
[tool.black]
line-length = 88
target-version = ['py311']
include = '\.pyi?$'
extend-exclude = '''
/(
    migrations
  | __pycache__
)/
'''

[tool.isort]
profile = "black"
line_length = 88

[build-system]
requires = ["setuptools>=45", "wheel"]
build-backend = "setuptools.build_meta"
EOF
    log "Created file: $PROJECT_ROOT/pyproject.toml"

    # scripts/create_initial_data.py
    cat > "$PROJECT_ROOT/scripts/create_initial_data.py" << 'EOF'
#!/usr/bin/env python3
from app.db.init_db import init_db

if __name__ == "__main__":
    print("Creating initial data...")
    init_db()
    print("Initial data created.")
EOF
    log "Created file: $PROJECT_ROOT/scripts/create_initial_data.py"

    # scripts/backup_db.py
    cat > "$PROJECT_ROOT/scripts/backup_db.py" << 'EOF'
#!/usr/bin/env python3
import shutil
import datetime
from pathlib import Path

BACKUP_DIR = Path("backups")
DB_PATH = Path("datahub.db")

def backup_sqlite():
    if not DB_PATH.exists():
        print("Database not found.")
        return
    
    BACKUP_DIR.mkdir(exist_ok=True)
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_path = BACKUP_DIR / f"datahub_backup_{timestamp}.db"
    
    shutil.copy(DB_PATH, backup_path)
    print(f"Backup saved to {backup_path}")

if __name__ == "__main__":
    backup_sqlite()
EOF
    log "Created file: $PROJECT_ROOT/scripts/backup_db.py"

    # .env.example
    cat > "$PROJECT_ROOT/.env.example" << EOF
DATABASE_URL=$DB_URL
SECRET_KEY=your-super-secret-jwt-key-change-in-production
ALGORITHM=HS256
ACCESS_TOKEN_EXPIRE_MINUTES=30
EOF
    log "Created file: $PROJECT_ROOT/.env.example"

    # .env
    cp "$PROJECT_ROOT/.env.example" "$PROJECT_ROOT/.env"
    log "Created file: $PROJECT_ROOT/.env"

    # .gitignore
    cat > "$PROJECT_ROOT/.gitignore" << 'EOF'
__pycache__/
*.pyc
*.pyo
*.pyd
.Python
env/
venv/
.venv/
.pytest_cache/
.coverage
htmlcov/
dist/
build/
*.egg-info/
.DS_Store
.env
*.log
uploads/
datahub.db
backups/
*.swp
*.bak
*.sqlite3
*.ipynb_checkpoints
migrations/
*.cover
.hypothesis/
mypy.ini
ruff.toml
pyrightconfig.json
EOF
    log "Created file: $PROJECT_ROOT/.gitignore"

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