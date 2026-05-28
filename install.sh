#!/usr/bin/env bash
# =============================================================
# ZapTec — Instalacao completa com migracao automatica do Ticketz
# Uso: curl -fsSL https://raw.githubusercontent.com/morrice22/zaptec-deploy/main/install.sh | bash
# =============================================================
set -euo pipefail

GHCR_IMAGE="ghcr.io/morrice22/whatsapp-saas:latest"
GHCR_USER="morrice22"
INSTALL_DIR="/opt/zaptec"

# Cores
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; W='\033[1;37m'; NC='\033[0m'
ok()   { echo -e "${G}[OK]${NC} $*"; }
info() { echo -e "${B}[..]${NC} $*"; }
warn() { echo -e "${Y}[!]${NC} $*"; }
err()  { echo -e "${R}[ERRO]${NC} $*"; exit 1; }
step() { echo -e "\n${W}==== $* ====${NC}"; }

clear
echo ""
echo -e "${W}╔══════════════════════════════════════════╗${NC}"
echo -e "${W}║         ZapTec — Instalacao              ║${NC}"
echo -e "${W}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Voce precisara do token de acesso fornecido pelo suporte."
echo ""
read -rsp "  Cole o token aqui e pressione ENTER: " GHCR_TOKEN
echo ""
[ -z "$GHCR_TOKEN" ] && err "Token nao informado."
ok "Token recebido."

# ─────────────────────────────────────────────────────────────
# 1. DOCKER
# ─────────────────────────────────────────────────────────────
step "1/6 Verificando Docker"

if ! command -v docker &>/dev/null; then
  info "Instalando Docker..."
  curl -fsSL https://get.docker.com | bash
  systemctl enable --now docker
  ok "Docker instalado."
else
  ok "Docker $(docker --version | cut -d' ' -f3 | tr -d ',')"
fi

if ! docker compose version &>/dev/null 2>&1; then
  info "Instalando Docker Compose plugin..."
  apt-get install -y docker-compose-plugin 2>/dev/null || true
fi
ok "Docker Compose disponivel."

# ─────────────────────────────────────────────────────────────
# 2. DETECTAR TICKETZ
# ─────────────────────────────────────────────────────────────
step "2/6 Detectando Ticketz"

TICKETZ_DIR=""
TICKETZ_ENV=""
TICKETZ_DB_CONTAINER=""
TICKETZ_DB_NAME=""
TICKETZ_DB_USER=""
TICKETZ_DB_PASS=""
TICKETZ_DB_HOST=""
TICKETZ_DB_PORT="5432"
HAS_TICKETZ=false

# Diretorios comuns do Ticketz/Whaticket
for dir in /opt/ticketz /opt/whaticket /opt/ticketzsaas /home/deploy/ticketz /root/ticketz /var/www/ticketz; do
  if [ -f "$dir/.env" ] || [ -f "$dir/docker-compose.yml" ] || [ -f "$dir/docker-compose.yaml" ]; then
    TICKETZ_DIR="$dir"
    TICKETZ_ENV="$dir/.env"
    HAS_TICKETZ=true
    ok "Ticketz encontrado em: $TICKETZ_DIR"
    break
  fi
done

# Tambem procura por containers Docker rodando
if [ "$HAS_TICKETZ" = false ]; then
  TICKETZ_CONTAINER=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE 'ticketz|whaticket' | head -1 || true)
  if [ -n "$TICKETZ_CONTAINER" ]; then
    HAS_TICKETZ=true
    ok "Container Ticketz encontrado: $TICKETZ_CONTAINER"
    # Tenta achar o diretorio pelo label do compose
    TICKETZ_DIR=$(docker inspect "$TICKETZ_CONTAINER" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null || echo "")
    [ -f "$TICKETZ_DIR/.env" ] && TICKETZ_ENV="$TICKETZ_DIR/.env"
  fi
fi

if [ "$HAS_TICKETZ" = false ]; then
  warn "Nenhuma instalacao do Ticketz detectada automaticamente."
  echo ""
  read -rp "Voce tem o Ticketz instalado? (s/N): " HAS_OLD
  if [[ "$HAS_OLD" =~ ^[Ss]$ ]]; then
    read -rp "Caminho da instalacao (ex: /opt/ticketz): " TICKETZ_DIR
    [ -f "$TICKETZ_DIR/.env" ] && TICKETZ_ENV="$TICKETZ_DIR/.env" && HAS_TICKETZ=true
  fi
fi

# Extrai credenciais do banco do .env do Ticketz
if [ "$HAS_TICKETZ" = true ] && [ -f "$TICKETZ_ENV" ]; then
  info "Lendo credenciais do banco de dados..."

  # Suporta DATABASE_URL ou variaveis separadas
  DB_URL=$(grep -E '^DATABASE_URL=' "$TICKETZ_ENV" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
  if [ -n "$DB_URL" ]; then
    # Extrai da DATABASE_URL: postgres://user:pass@host:port/dbname
    TICKETZ_DB_USER=$(echo "$DB_URL" | sed 's|.*://||;s|:.*||')
    TICKETZ_DB_PASS=$(echo "$DB_URL" | sed 's|.*://[^:]*:||;s|@.*||')
    TICKETZ_DB_HOST=$(echo "$DB_URL" | sed 's|.*@||;s|:.*||;s|/.*||')
    TICKETZ_DB_PORT=$(echo "$DB_URL" | sed 's|.*:\([0-9]*\)/.*|\1|' || echo "5432")
    TICKETZ_DB_NAME=$(echo "$DB_URL" | sed 's|.*/||;s|?.*||')
  else
    TICKETZ_DB_HOST=$(grep -E '^DB_HOST=' "$TICKETZ_ENV" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "localhost")
    TICKETZ_DB_PORT=$(grep -E '^DB_PORT=' "$TICKETZ_ENV" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "5432")
    TICKETZ_DB_USER=$(grep -E '^DB_USER=' "$TICKETZ_ENV" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "postgres")
    TICKETZ_DB_PASS=$(grep -E '^DB_PASS=' "$TICKETZ_ENV" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "")
    TICKETZ_DB_NAME=$(grep -E '^DB_NAME=' "$TICKETZ_ENV" 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "ticketz")
  fi

  # Descobre se o banco esta num container Docker
  TICKETZ_DB_CONTAINER=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE 'postgres|postgresql|ticketz.*db|db.*ticketz' | head -1 || true)

  ok "Banco: $TICKETZ_DB_NAME @ $TICKETZ_DB_HOST:$TICKETZ_DB_PORT (usuario: $TICKETZ_DB_USER)"
fi

# ─────────────────────────────────────────────────────────────
# 3. DUMP DO TICKETZ
# ─────────────────────────────────────────────────────────────
DUMP_FILE=""

if [ "$HAS_TICKETZ" = true ]; then
  step "3/6 Exportando banco do Ticketz"

  DUMP_FILE="/tmp/ticketz_dump_$(date +%Y%m%d%H%M%S).sql"

  if [ -n "$TICKETZ_DB_CONTAINER" ]; then
    info "Criando dump via container Docker: $TICKETZ_DB_CONTAINER"
    docker exec "$TICKETZ_DB_CONTAINER" pg_dump \
      -U "$TICKETZ_DB_USER" \
      -d "$TICKETZ_DB_NAME" \
      --no-owner --no-acl \
      -f /tmp/ticketz_dump.sql

    docker cp "$TICKETZ_DB_CONTAINER:/tmp/ticketz_dump.sql" "$DUMP_FILE"
    ok "Dump criado: $DUMP_FILE"
  elif command -v pg_dump &>/dev/null; then
    info "Criando dump via pg_dump local..."
    PGPASSWORD="$TICKETZ_DB_PASS" pg_dump \
      -h "$TICKETZ_DB_HOST" \
      -p "$TICKETZ_DB_PORT" \
      -U "$TICKETZ_DB_USER" \
      -d "$TICKETZ_DB_NAME" \
      --no-owner --no-acl \
      -f "$DUMP_FILE"
    ok "Dump criado: $DUMP_FILE"
  else
    warn "pg_dump nao encontrado. Tentando via sidekick..."
    if command -v ticketz-sidekick &>/dev/null; then
      ticketz-sidekick backup
      BACKUP_TGZ=$(ls -t /opt/ticketz/backups/*.tar.gz 2>/dev/null | head -1 || ls -t ~/ticketz-backup-*.tar.gz 2>/dev/null | head -1 || true)
      if [ -n "$BACKUP_TGZ" ]; then
        tar -xzf "$BACKUP_TGZ" --wildcards '*.sql' -O > "$DUMP_FILE"
        ok "Dump extraido do backup: $BACKUP_TGZ"
      else
        warn "Nao foi possivel criar o dump automaticamente."
        DUMP_FILE=""
      fi
    fi
  fi
else
  step "3/6 Backup"
  info "Sem Ticketz detectado — pulando etapa de backup."
fi

# ─────────────────────────────────────────────────────────────
# 4. INSTALAR ZAPTEC
# ─────────────────────────────────────────────────────────────
step "4/6 Instalando ZapTec"

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# Login e pull da imagem
info "Autenticando no registry..."
echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
ok "Autenticado."

info "Baixando imagem ZapTec..."
docker pull "$GHCR_IMAGE"
ok "Imagem baixada."

# Extrair arquivos de configuracao da imagem
docker create --name zaptec-tmp "$GHCR_IMAGE" > /dev/null
docker cp zaptec-tmp:/app/migrate.js "$INSTALL_DIR/migrate.js"
docker rm zaptec-tmp > /dev/null
ok "migrate.js extraido."

# docker-compose.yml
cat > "$INSTALL_DIR/docker-compose.yml" << 'COMPOSE'
version: "3.9"
services:
  app:
    image: ghcr.io/morrice22/whatsapp-saas:latest
    container_name: zaptec-app
    restart: unless-stopped
    env_file: .env
    ports:
      - "${PORT:-3000}:3000"
    volumes:
      - zaptec-sessions:/app/whatsapp-sessions
      - zaptec-media:/app/media
      - zaptec-uploads:/app/uploads
    depends_on:
      db:
        condition: service_healthy
    networks:
      - zaptec-net

  db:
    image: postgres:16-alpine
    container_name: zaptec-db
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${DB_USER:-zaptec}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_DB: ${DB_NAME:-zaptec_prod}
    volumes:
      - zaptec-pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER:-zaptec} -d ${DB_NAME:-zaptec_prod}"]
      interval: 5s
      timeout: 5s
      retries: 10
    ports:
      - "${DB_PORT:-5433}:5432"
    networks:
      - zaptec-net

volumes:
  zaptec-pgdata:
  zaptec-sessions:
  zaptec-media:
  zaptec-uploads:

networks:
  zaptec-net:
    driver: bridge
COMPOSE

ok "docker-compose.yml criado."

# ─────────────────────────────────────────────────────────────
# 5. CONFIGURAR .env
# ─────────────────────────────────────────────────────────────
step "5/6 Configurando ambiente"

if [ ! -f "$INSTALL_DIR/.env" ]; then
  echo ""
  warn "Precisamos configurar algumas informacoes:"
  echo ""

  read -rp "  Dominio ou IP do servidor (ex: app.meusite.com.br ou 123.456.789.0): " DOMAIN
  read -rp "  Senha para o banco de dados ZapTec (crie uma senha forte): " DB_PASS
  echo ""

  # Gera JWT secrets automaticamente
  JWT_SECRET=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64 || echo "changeme-$(date +%s)")
  JWT_REFRESH=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64 || echo "refresh-$(date +%s)")

  # Define protocolo
  if [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    BASE_URL="http://$DOMAIN:3000"
  else
    BASE_URL="https://$DOMAIN"
  fi

  cat > "$INSTALL_DIR/.env" << ENV
NODE_ENV=production
PORT=3000
API_URL=${BASE_URL}
CORS_ORIGIN=${BASE_URL}
FRONTEND_URL=${BASE_URL}

DB_USER=zaptec
DB_PASSWORD=${DB_PASS}
DB_NAME=zaptec_prod
DB_PORT=5433
DATABASE_URL=postgresql://zaptec:${DB_PASS}@zaptec-db:5432/zaptec_prod

JWT_SECRET=${JWT_SECRET}
JWT_EXPIRES_IN=7d
JWT_REFRESH_SECRET=${JWT_REFRESH}
JWT_REFRESH_EXPIRES_IN=30d

VAPID_PUBLIC_KEY=
VAPID_PRIVATE_KEY=
VAPID_EMAIL=admin@${DOMAIN}

DEFAULT_MAX_CONNECTIONS=3
DEFAULT_MAX_USERS=5
WHATSAPP_MEDIA_DIR=./media
WHATSAPP_SESSIONS_DIR=./whatsapp-sessions
ENV

  ok ".env configurado."
else
  ok ".env ja existe — mantendo configuracao atual."
fi

# Sobe os containers
info "Subindo containers..."
docker compose up -d
ok "Containers iniciados."

# Aguarda banco
info "Aguardando banco de dados..."
MAX=30; COUNT=0
until docker compose exec -T db pg_isready -U zaptec -d zaptec_prod &>/dev/null 2>&1; do
  COUNT=$((COUNT+1)); [ $COUNT -ge $MAX ] && err "Banco nao ficou pronto."; sleep 3
done
ok "Banco de dados pronto."

# ─────────────────────────────────────────────────────────────
# 6. MIGRACAO DO TICKETZ
# ─────────────────────────────────────────────────────────────
step "6/6 Migracao de dados"

if [ -n "$DUMP_FILE" ] && [ -f "$DUMP_FILE" ]; then
  info "Importando dados do Ticketz..."

  # Cria banco temporario para o dump
  docker compose exec -T db psql -U zaptec -d zaptec_prod -c "CREATE DATABASE ticketz_import;" 2>/dev/null || true

  # Copia e carrega o dump
  docker cp "$DUMP_FILE" "$(docker compose ps -q db)":/tmp/ticketz_dump.sql
  docker compose exec -T db psql -U zaptec -d ticketz_import -f /tmp/ticketz_dump.sql > /dev/null 2>&1
  ok "Dump carregado no banco temporario."

  # Configura variaveis para o migrate.js
  DB_PASS_VAL=$(grep 'DB_PASSWORD=' "$INSTALL_DIR/.env" | cut -d'=' -f2)
  export OLD_DB_URL="postgresql://zaptec:${DB_PASS_VAL}@localhost:5433/ticketz_import"
  export NEW_DB_URL="postgresql://zaptec:${DB_PASS_VAL}@localhost:5433/zaptec_prod"

  # Instala dependencias do migrate.js se necessario
  if ! command -v node &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt-get install -y nodejs
  fi
  [ ! -f "$INSTALL_DIR/node_modules/.bin/uuid" ] && cd "$INSTALL_DIR" && npm install pg uuid --save 2>/dev/null || true
  cd "$INSTALL_DIR"

  info "Executando migracao..."
  node "$INSTALL_DIR/migrate.js"
  ok "Dados migrados com sucesso!"

  # Limpa banco temporario
  docker compose exec -T db psql -U zaptec -d zaptec_prod -c "DROP DATABASE IF EXISTS ticketz_import;" 2>/dev/null || true
  rm -f "$DUMP_FILE"
  ok "Limpeza concluida."
else
  info "Sem dados para migrar — instalacao limpa."
fi

# ─────────────────────────────────────────────────────────────
# CONCLUIDO
# ─────────────────────────────────────────────────────────────
IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
BASE_URL=$(grep 'API_URL=' "$INSTALL_DIR/.env" | cut -d'=' -f2)

echo ""
echo -e "${G}╔══════════════════════════════════════════╗${NC}"
echo -e "${G}║        Instalacao concluida!             ║${NC}"
echo -e "${G}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Acesse: ${W}${BASE_URL}${NC}"
echo ""
echo "  Comandos uteis:"
echo "    Ver logs:    docker compose -f $INSTALL_DIR/docker-compose.yml logs -f app"
echo "    Reiniciar:   docker compose -f $INSTALL_DIR/docker-compose.yml restart app"
echo "    Atualizar:   docker compose -f $INSTALL_DIR/docker-compose.yml pull && docker compose -f $INSTALL_DIR/docker-compose.yml up -d"
echo ""
