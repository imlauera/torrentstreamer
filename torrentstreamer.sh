#!/usr/bin/env bash
# =============================================================================
# torrent_streamer.sh — "El nuevo Ares"
# https://imlauera.github.io/post/el_nuevo_ares/
#
# Uso:
#   ./torrent_streamer.sh "Jason vs Freddy"
#   ./torrent_streamer.sh --reset
#   ./torrent_streamer.sh --setup
# =============================================================================

# IMPORTANTE: NO usar set -e porque grep/jq/curl devuelven exit!=0 legítimamente
set -uo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
step()  { echo -e "\n${MAGENTA}[STEP]${RESET} ${BOLD}$*${RESET}"; }
error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()   { error "$*"; exit 1; }

# ─── Config ──────────────────────────────────────────────────────────────────
QBT_HOST="http://127.0.0.1:8080"
QBT_USER="admin"
QBT_PASS="adminadmin"
QBT_COOKIES="/tmp/qbt_cookies.txt"
QBT_CONF="$HOME/.config/qBittorrent/qBittorrent.conf"
QBT_LOG="/tmp/qbt.log"

JACKETT_HOST="http://127.0.0.1:9117"
JACKETT_ENGINES_DIR="$HOME/.local/share/qBittorrent/nova3/engines"
JACKETT_KEY_FILE="$JACKETT_ENGINES_DIR/jackett.json"
JACKETT_PLUGIN_URL="https://raw.githubusercontent.com/qbittorrent/search-plugins/master/nova3/engines/jackett.py"

# Directorio de descarga: tiene que ser escribible por el usuario 'qbt' (systemd)
# /var/lib/qbittorrent es el home del usuario qbt → siempre tiene permisos
DOWNLOAD_DIR="/var/lib/qbittorrent/Downloads"
# Si preferís descargar en tu home, corré:
#   sudo chown -R qbt:qbt ~/Downloads/torrents
#   DOWNLOAD_DIR="$HOME/Downloads/torrents"
FLARESOLVERR_INDEXERS=("0magnet" "1337x" "52bt")

# ─── Args ────────────────────────────────────────────────────────────────────
MODE="stream"
QUERY="Jason vs Freddy"

usage() {
    echo -e "${BOLD}Uso:${RESET}"
    echo "  $0 \"nombre\"    Buscar y reproducir"
    echo "  $0 --setup     Instalar y configurar todo"
    echo "  $0 --reset     Reiniciar cuando algo falla"
    echo "  $0 --help"
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --help|-h) usage ;;
        --reset)   MODE="reset" ;;
        --setup)   MODE="setup" ;;
        *)         QUERY="$arg" ;;
    esac
done

banner() {
    echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${CYAN}║   🎬  El Nuevo Ares — Torrent Streamer       ║${RESET}"
    echo -e "${BOLD}${CYAN}║   qBittorrent-nox + Jackett + mpv            ║${RESET}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════╝${RESET}"
    echo -e "   ${CYAN}https://imlauera.github.io/post/el_nuevo_ares/${RESET}\n"

    echo -e "${YELLOW}╔══════════════════════════════════════════════╗${RESET}"
    echo -e "${YELLOW}║  ⚠  REQUISITO PREVIO: configurar Jackett     ║${RESET}"
    echo -e "${YELLOW}╠══════════════════════════════════════════════╣${RESET}"
    echo -e "${YELLOW}║${RESET}  1. Abrí  ${CYAN}http://localhost:9117${RESET}"
    echo -e "${YELLOW}║${RESET}  2. Hacé click en ${BOLD}"+ Add indexer"${RESET}"
    echo -e "${YELLOW}║${RESET}  3. Marcá los indexers que querés usar"
    echo -e "${YELLOW}║${RESET}     (cada fuente = un indexer, ej: 1337x,"
    echo -e "${YELLOW}║${RESET}      YTS, EZTV, Knaben, TorrentGalaxy...)"
    echo -e "${YELLOW}║${RESET}  4. Hacé click en ${BOLD}"Add selected"${RESET} y listo"
    echo -e "${YELLOW}║${RESET}  ${RED}Sin indexers configurados no hay resultados${RESET}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════╝${RESET}\n"
}

# ─── Reset ───────────────────────────────────────────────────────────────────
do_reset() {
    step "Reiniciando todo..."
    pkill -f qbittorrent-nox 2>/dev/null && ok "qBittorrent-nox detenido." || info "No había proceso activo."
    rm -f "$QBT_COOKIES" "$QBT_LOG"
    sudo systemctl restart jackett 2>/dev/null && ok "Jackett reiniciado." || warn "No se pudo reiniciar Jackett."
    rm -f /tmp/qbt_*.txt /tmp/qbt*.log
    ok "Reset completo. Corré el script nuevamente."
    exit 0
}

# ─── Setup ───────────────────────────────────────────────────────────────────
do_setup() {
    step "Instalando dependencias..."
    if command -v apt &>/dev/null; then
        sudo apt update -qq && sudo apt install -y qbittorrent-nox jackett curl jq mpv python3
    elif command -v yay &>/dev/null; then
        yay -S --noconfirm qbittorrent-nox jackett-bin curl jq mpv
    elif command -v pacman &>/dev/null; then
        sudo pacman -Sy --noconfirm qbittorrent-nox curl jq mpv
        warn "Instalá jackett: yay -S jackett-bin"
    else
        warn "Instalá manualmente: qbittorrent-nox jackett curl jq mpv"
    fi

    step "Configurando jackett.json..."
    setup_jackett_json

    step "Descargando plugin jackett.py..."
    mkdir -p "$JACKETT_ENGINES_DIR"
    if curl -sL "$JACKETT_PLUGIN_URL" -o "$JACKETT_ENGINES_DIR/jackett.py"; then
        ok "Plugin descargado: $JACKETT_ENGINES_DIR/jackett.py"
    else
        warn "No se pudo descargar. URL: $JACKETT_PLUGIN_URL"
    fi

    step "Configurando qBittorrent..."
    configure_qbt

    echo ""
    ok "Setup completo."
    echo -e "\n  ${BOLD}Próximos pasos:${RESET}"
    echo -e "  1. Abrí Jackett en ${CYAN}http://localhost:9117${RESET}"
    echo -e "  2. Copiá tu API key y pegala en: ${CYAN}$JACKETT_KEY_FILE${RESET}"
    echo -e "  3. Corré: ${BOLD}./torrent_streamer.sh \"nombre pelicula\"${RESET}"
    echo ""
    warn "Indexers que necesitan FlareSolverr: ${FLARESOLVERR_INDEXERS[*]}"
    exit 0
}

# ─── Deps ────────────────────────────────────────────────────────────────────
check_deps() {
    step "Verificando dependencias..."
    local missing=0

    for cmd in qbittorrent-nox curl jq mpv python3; do
        if command -v "$cmd" &>/dev/null; then
            ok "  ✓ $cmd"
        else
            warn "  ✗ '$cmd' no encontrado."
            missing=1
        fi
    done

    # Jackett: puede estar en /usr/lib/jackett/ sin binario en PATH (AUR jackett-bin)
    local jackett_found=0
    command -v jackett &>/dev/null && jackett_found=1
    [[ -f /usr/lib/jackett/jackett ]] && jackett_found=1
    [[ -f /usr/lib/jackett/Jackett ]] && jackett_found=1
    systemctl list-unit-files --type=service 2>/dev/null | grep -qi jackett && jackett_found=1

    if [[ $jackett_found -eq 1 ]]; then
        ok "  ✓ jackett"
    else
        warn "  ✗ jackett no encontrado. En Arch: yay -S jackett-bin | En Debian: apt install jackett"
        missing=1
    fi

    if [[ $missing -eq 1 ]]; then
        die "Faltan dependencias. Corré: $0 --setup"
    fi
}

# ─── jackett.json ────────────────────────────────────────────────────────────
setup_jackett_json() {
    mkdir -p "$JACKETT_ENGINES_DIR"

    if [[ ! -f "$JACKETT_KEY_FILE" ]]; then
        info "Creando $JACKETT_KEY_FILE..."
        cat > "$JACKETT_KEY_FILE" <<'EOF'
{
    "api_key": "YOUR_API_KEY_HERE",
    "url": "http://127.0.0.1:9117",
    "tracker_first": false,
    "thread_count": 20
}
EOF
        warn "IMPORTANTE: Editá $JACKETT_KEY_FILE con tu API key de http://localhost:9117"
    else
        # Completar campos faltantes (campos del artículo)
        local updated
        updated=$(jq '. + {
            "url":           (.url           // "http://127.0.0.1:9117"),
            "tracker_first": (.tracker_first // false),
            "thread_count":  (.thread_count  // 20)
          }' "$JACKETT_KEY_FILE" 2>/dev/null) || true
        if [[ -n "$updated" ]]; then
            echo "$updated" > "$JACKETT_KEY_FILE"
            ok "jackett.json verificado."
        fi
    fi
}

# ─── qBittorrent.conf ────────────────────────────────────────────────────────
configure_qbt() {
    info "Configurando qBittorrent.conf..."
    mkdir -p "$(dirname "$QBT_CONF")"

    local PASS_LINE
    PASS_LINE='WebUI\Password_PBKDF2="@ByteArray(ARQ77eY1NUZaQsuDHbIMCA==:0WMRkYTUWVT9wVvdDtHAjU9b3b7uB8NR1Gur2hmQCvCDpm39Q+PsJRJPaCU51dEiz+dTzh8qbPsL8WkFljQYFQ==)"'

    if [[ ! -f "$QBT_CONF" ]]; then
        cat > "$QBT_CONF" <<EOF
[Preferences]
${PASS_LINE}
WebUI\Port=8080
WebUI\Username=admin
WebUI\LocalHostAuth=false
EOF
        ok "qBittorrent.conf creado."
        return
    fi

    # grep devuelve 1 si no encuentra → no usar set -e aquí
    if grep -qF 'Password_PBKDF2' "$QBT_CONF" 2>/dev/null; then
        ok "Contraseña ya configurada en qBittorrent.conf."
    elif grep -q '^\[Preferences\]' "$QBT_CONF" 2>/dev/null; then
        sed -i "/^\[Preferences\]/a ${PASS_LINE}" "$QBT_CONF"
        ok "Contraseña insertada en [Preferences]."
    else
        printf '\n[Preferences]\n%s\n' "$PASS_LINE" >> "$QBT_CONF"
        ok "Sección [Preferences] creada con contraseña."
    fi
}

# ─── qBittorrent-nox ─────────────────────────────────────────────────────────
# El servicio systemd corre como usuario 'qbt', con su propia config en
# /var/lib/qbittorrent/.config/qBittorrent/qBittorrent.conf
# La contraseña debe estar ahí, no en $HOME del usuario actual.
QBT_CONF_SYS="/var/lib/qbittorrent/.config/qBittorrent/qBittorrent.conf"

configure_qbt_system() {
    # Usar single quotes para evitar problemas con los caracteres especiales
    local PASS_LINE
    PASS_LINE='WebUI\Password_PBKDF2="@ByteArray(ARQ77eY1NUZaQsuDHbIMCA==:0WMRkYTUWVT9wVvdDtHAjU9b3b7uB8NR1Gur2hmQCvCDpm39Q+PsJRJPaCU51dEiz+dTzh8qbPsL8WkFljQYFQ==)"'

    if [[ ! -f "$QBT_CONF_SYS" ]]; then
        info "Creando config del servicio en $QBT_CONF_SYS..."
        sudo mkdir -p "$(dirname "$QBT_CONF_SYS")"
        printf '[Preferences]\n%s\nWebUI\\Port=8080\nWebUI\\Username=admin\nWebUI\\LocalHostAuth=false\n' \
            "$PASS_LINE" | sudo tee "$QBT_CONF_SYS" > /dev/null
        sudo chown -R qbt:qbt "$(dirname "$QBT_CONF_SYS")" 2>/dev/null || true
        ok "Config del servicio creada en $QBT_CONF_SYS."
    elif sudo grep -qF 'Password_PBKDF2' "$QBT_CONF_SYS" 2>/dev/null; then
        ok "Contraseña ya configurada en config del servicio."
    else
        sudo sed -i "/^\[Preferences\]/a ${PASS_LINE}" "$QBT_CONF_SYS" 2>/dev/null \
            && ok "Contraseña insertada en config del servicio." \
            || warn "No se pudo escribir en $QBT_CONF_SYS. La contraseña será temporal (se leerá del journal)."
    fi
}
start_qbt() {
    if curl -sf "$QBT_HOST/api/v2/app/version" &>/dev/null; then
        ok "qBittorrent-nox ya está corriendo."
        return
    fi

    # Configurar la contraseña en la config del servicio (usuario qbt)
    configure_qbt_system

    # Crear directorio de descarga con permisos para el usuario qbt
    sudo mkdir -p "$DOWNLOAD_DIR"
    sudo chown qbt:qbt "$DOWNLOAD_DIR" 2>/dev/null || true
    sudo chmod 775 "$DOWNLOAD_DIR" 2>/dev/null || true
    # Agregar tu usuario al grupo qbt para que también puedas leer los archivos
    sudo usermod -aG qbt "$USER" 2>/dev/null || true

    info "Iniciando qBittorrent-nox via systemd..."
    if sudo systemctl start qbittorrent-nox; then
        ok "Comando systemctl start ejecutado."
    else
        die "sudo systemctl start qbittorrent-nox falló. Revisá el servicio."
    fi

    info "Esperando que la WebUI responda en $QBT_HOST..."
    local tries=0
    while true; do
        if curl -sf "$QBT_HOST/api/v2/app/version" &>/dev/null; then
            ok "qBittorrent-nox corriendo."
            break
        fi
        tries=$(( tries + 1 ))
        if [[ $tries -ge 30 ]]; then
            error "No responde tras 30s. Status:"
            sudo systemctl status qbittorrent-nox --no-pager -l >&2
            die "qBittorrent-nox no responde en $QBT_HOST"
        fi
        sleep 1
    done
}

# ─── Login ───────────────────────────────────────────────────────────────────
login_qbt() {
    info "Login en qBittorrent WebUI (user: $QBT_USER / pass: $QBT_PASS)..."
    local result
    result=$(curl -sf -X POST "$QBT_HOST/api/v2/auth/login" \
        -d "username=${QBT_USER}&password=${QBT_PASS}" \
        -c "$QBT_COOKIES" 2>/dev/null) || result=""

    case "$result" in
        "Ok.")
            ok "Login exitoso."
            ;;
        "Fails.")
            # El servicio systemd puede haber generado una contraseña temporal.
            # Leerla del journal y reintentar.
            warn "Contraseña incorrecta. Buscando contraseña temporal en el journal..."
            local tmp_pass
            tmp_pass=$(sudo journalctl -u qbittorrent-nox -n 50 --no-pager 2>/dev/null \
                | grep -oP "temporary password is provided for this session: \K\S+" | tail -1)
            if [[ -n "$tmp_pass" ]]; then
                warn "Contraseña temporal encontrada: $tmp_pass"
                warn "Para evitar esto en el futuro, el script intentará fijarla via API..."
                result=$(curl -sf -X POST "$QBT_HOST/api/v2/auth/login" \
                    -d "username=admin&password=${tmp_pass}" \
                    -c "$QBT_COOKIES" 2>/dev/null) || result=""
                if [[ "$result" == "Ok." ]]; then
                    ok "Login con contraseña temporal exitoso."
                    # Fijar la contraseña adminadmin para la próxima vez
                    curl -sf -X POST "$QBT_HOST/api/v2/app/setPreferences" \
                        -b "$QBT_COOKIES" \
                        -d "json={"web_ui_password":"adminadmin"}" &>/dev/null || true
                    ok "Contraseña fijada a 'adminadmin' para próximas sesiones."
                else
                    die "Login fallido incluso con contraseña temporal. Corré --reset."
                fi
            else
                die "Login fallido y no se encontró contraseña temporal. Corré --reset."
            fi
            ;;
        *)
            warn "Respuesta login: '${result:-vacía}' (asumiendo sesión activa)."
            ;;
    esac
}

# ─── Jackett ─────────────────────────────────────────────────────────────────
start_jackett() {
    info "Iniciando Jackett (systemd)..."

    if systemctl is-active --quiet jackett 2>/dev/null; then
        ok "Jackett ya está activo."
    else
        sudo systemctl start jackett 2>/dev/null \
            && ok "Jackett iniciado." \
            || warn "No se pudo iniciar. ¿Instalado? (yay -S jackett-bin)"
    fi

    info "Esperando que Jackett responda en $JACKETT_HOST..."
    local tries=0
    while true; do
        if curl -sf "$JACKETT_HOST" &>/dev/null; then
            ok "Jackett disponible."
            break
        fi
        tries=$(( tries + 1 ))
        [[ $tries -ge 25 ]] && die "Jackett no responde en $JACKETT_HOST tras 25s."
        sleep 1
    done
}

get_jackett_key() {
    setup_jackett_json

    JACKETT_API_KEY=$(jq -r '.api_key // empty' "$JACKETT_KEY_FILE" 2>/dev/null) || JACKETT_API_KEY=""

    if [[ -z "$JACKETT_API_KEY" || "$JACKETT_API_KEY" == "YOUR_API_KEY_HERE" ]]; then
        die "API key no configurada. Editá $JACKETT_KEY_FILE con la key de http://localhost:9117"
    fi
    ok "API key lista."
}

warn_flaresolverr() {
    echo ""
    warn "Si no hay resultados, algunos indexers necesitan FlareSolverr: ${FLARESOLVERR_INDEXERS[*]}"
    echo ""
}

# ─── Búsqueda ────────────────────────────────────────────────────────────────
search_torrent() {
    local query_encoded
    query_encoded=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$QUERY")

    info "Buscando '${BOLD}${QUERY}${RESET}' en todos los indexers de Jackett..."

    SEARCH_RESULTS=$(curl -sf \
        "${JACKETT_HOST}/api/v2.0/indexers/all/results?Query=${query_encoded}&apikey=${JACKETT_API_KEY}" \
        2>/dev/null) || SEARCH_RESULTS=""

    if [[ -z "$SEARCH_RESULTS" ]]; then
        warn_flaresolverr
        die "Sin respuesta de Jackett. ¿API key correcta? ¿Jackett corriendo?"
    fi

    local total
    total=$(echo "$SEARCH_RESULTS" | jq '.Results | length' 2>/dev/null) || total=0

    if [[ "$total" -eq 0 ]]; then
        warn_flaresolverr
        die "Sin resultados para '${QUERY}'. Agregá más indexers en http://localhost:9117"
    fi

    info "Resultados encontrados: ${BOLD}$total${RESET}"
    echo ""
    info "Top 5 por seeds:"
    echo "$SEARCH_RESULTS" | jq -r '
      .Results
      | map(select(.Seeders > 0))
      | sort_by(-.Seeders)
      | .[0:5][]
      | "  \(.Seeders) seeds | \(.Title[:65])"
    ' 2>/dev/null || true
    echo ""
}

# ─── Filtrar ─────────────────────────────────────────────────────────────────
pick_torrent() {
    info "Seleccionando: menor calidad + más seeds + magnet link..."

    # Intento 1: sin 4K/1080p
    MAGNET=$(echo "$SEARCH_RESULTS" | jq -r '
      .Results
      | map(select(
          .Seeders > 0 and
          (.Guid | startswith("magnet:?")) and
          (.Title | test("4K|2160p|UHD|1080p|FHD|REMUX"; "i") | not)
        ))
      | sort_by(-.Seeders)
      | .[0].Guid // empty
    ' 2>/dev/null) || MAGNET=""

    # Intento 2: sin 4K solamente
    if [[ -z "$MAGNET" || "$MAGNET" == "null" ]]; then
        warn "No hay baja calidad. Probando 1080p..."
        MAGNET=$(echo "$SEARCH_RESULTS" | jq -r '
          .Results
          | map(select(
              .Seeders > 0 and
              (.Guid | startswith("magnet:?")) and
              (.Title | test("4K|2160p|UHD"; "i") | not)
            ))
          | sort_by(-.Seeders)
          | .[0].Guid // empty
        ' 2>/dev/null) || MAGNET=""
    fi

    # Intento 3: cualquier magnet con seeds
    if [[ -z "$MAGNET" || "$MAGNET" == "null" ]]; then
        warn "Usando cualquier calidad disponible..."
        MAGNET=$(echo "$SEARCH_RESULTS" | jq -r '
          .Results
          | map(select(.Seeders > 0 and (.Guid | startswith("magnet:?"))))
          | sort_by(-.Seeders)
          | .[0].Guid // empty
        ' 2>/dev/null) || MAGNET=""
    fi

    if [[ -z "$MAGNET" || "$MAGNET" == "null" ]]; then
        warn_flaresolverr
        die "No se encontró magnet link. Revisá los indexers activos en Jackett."
    fi

    local title seeders
    title=$(echo "$SEARCH_RESULTS" | jq -r --arg g "$MAGNET" \
        '.Results | map(select(.Guid == $g)) | .[0].Title // "desconocido"' 2>/dev/null) || title="?"
    seeders=$(echo "$SEARCH_RESULTS" | jq -r --arg g "$MAGNET" \
        '.Results | map(select(.Guid == $g)) | .[0].Seeders // 0' 2>/dev/null) || seeders="?"

    ok "Elegido:  ${BOLD}${title}${RESET}"
    ok "Seeds:    ${BOLD}${seeders}${RESET}"
    info "Magnet:   ${MAGNET:0:90}..."
}

# ─── Agregar torrent ─────────────────────────────────────────────────────────
add_torrent() {
    info "Agregando torrent a qBittorrent-nox..."
    local resp
    resp=$(curl -sf -X POST "$QBT_HOST/api/v2/torrents/add" \
        -b "$QBT_COOKIES" \
        --data-urlencode "urls=$MAGNET" \
        -d "savepath=$DOWNLOAD_DIR" \
        -d "category=streamed" \
        -d "sequentialDownload=true" \
        -d "firstLastPiecePrio=true" \
        2>/dev/null) || resp="(sin respuesta)"
    ok "qBittorrent: ${resp}"
    info "Descargando en: $DOWNLOAD_DIR"
}

# ─── Esperar y reproducir ────────────────────────────────────────────────────

# ─── Esperar y reproducir ────────────────────────────────────────────────────
wait_and_play() {
    info "Esperando datos para reproducir... (Ctrl+C para cancelar)"

    # Extraer hash del magnet para consultar qBittorrent directamente
    local torrent_hash state="" found_file="" tries=0 max_wait=360 min_size=52428800 metadl_count=0
    torrent_hash=$(echo "$MAGNET" | grep -oE 'btih:[a-fA-F0-9]+' | cut -d: -f2 | tr '[:upper:]' '[:lower:]')
    info "Hash: $torrent_hash"

    while [[ $tries -lt $max_wait ]]; do

        # Consultar estado y path via API — funciona aunque ya esté descargado
        local torrent_info content_path save_path
        torrent_info=$(curl -sf "$QBT_HOST/api/v2/torrents/info?hashes=$torrent_hash" \
            -b "$QBT_COOKIES" 2>/dev/null) || torrent_info=""

        if [[ -n "$torrent_info" && "$torrent_info" != "[]" ]]; then
            state=$(echo "$torrent_info"       | jq -r '.[0].state        // empty' 2>/dev/null) || state=""
            content_path=$(echo "$torrent_info" | jq -r '.[0].content_path // empty' 2>/dev/null) || content_path=""
            save_path=$(echo "$torrent_info"   | jq -r '.[0].save_path    // empty' 2>/dev/null) || save_path=""
            local pct
            pct=$(echo "$torrent_info" | jq -r '.[0].progress // 0' 2>/dev/null) || pct=0
            pct=$(awk "BEGIN{printf \"%.1f\", $pct * 100}" 2>/dev/null) || pct="?"
            info "Estado: ${state:-?} | Progreso: ${pct}%"

            # metaDL por más de 30s = sin seeds reales → cancelar y reintentar
            if [[ "$state" == "metaDL" ]]; then
                metadl_count=$(( metadl_count + 1 ))
                if [[ $metadl_count -ge 6 ]]; then
                    warn "Sin seeds después de 30s (metaDL). Cancelando este torrent..."
                    curl -sf -X POST "$QBT_HOST/api/v2/torrents/delete"                         -b "$QBT_COOKIES"                         -d "hashes=$torrent_hash&deleteFiles=false" &>/dev/null || true
                    warn "Buscando otro resultado con más seeds..."
                    # Reintentar pick_torrent excluyendo este magnet
                    SEARCH_RESULTS=$(echo "$SEARCH_RESULTS" | jq                         --arg g "$MAGNET" '[.Results[] | select(.Guid != $g)]'                         | jq '{Results: .}' 2>/dev/null) || true
                    pick_torrent
                    add_torrent
                    # Reiniciar contadores
                    torrent_hash=$(echo "$MAGNET" | grep -oE 'btih:[a-fA-F0-9]+' | cut -d: -f2 | tr '[:upper:]' '[:lower:]')
                    metadl_count=0
                    tries=0
                    info "Nuevo hash: $torrent_hash"
                fi
            else
                metadl_count=0
            fi
        fi

        # Encontrar el archivo de video: content_path puede ser fichero o carpeta
        if [[ -n "$content_path" && -e "$content_path" ]]; then
            if [[ -d "$content_path" ]]; then
                found_file=$(find "$content_path" -type f \
                    \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" \
                       -o -iname "*.mov" -o -iname "*.webm" -o -iname "*.ts" \
                       -o -iname "*.m4v" -o -iname "*.m2ts" \) \
                    2>/dev/null | while read -r f; do
                        stat -c "%s %n" "$f" 2>/dev/null
                    done | sort -rn | head -1 | cut -d' ' -f2-) || found_file=""
            else
                # Verificar que sea video por extensión
                case "${content_path,,}" in
                    *.mkv|*.mp4|*.avi|*.mov|*.webm|*.ts|*.m4v|*.m2ts)
                        found_file="$content_path" ;;
                esac
            fi
        fi

        # Fallback: buscar el video más grande en DOWNLOAD_DIR (sin filtro de fecha)
        if [[ -z "$found_file" && -d "$DOWNLOAD_DIR" ]]; then
            found_file=$(find "$DOWNLOAD_DIR" -type f \
                \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" \
                   -o -iname "*.mov" -o -iname "*.webm" -o -iname "*.ts" \
                   -o -iname "*.m4v" -o -iname "*.m2ts" \) \
                2>/dev/null | while read -r f; do
                    stat -c "%s %n" "$f" 2>/dev/null
                done | sort -rn | head -1 | cut -d' ' -f2-) || found_file=""
        fi

        if [[ -n "$found_file" && -f "$found_file" ]]; then
            local size size_mb
            size=$(stat -c%s "$found_file" 2>/dev/null) || size=0
            size_mb=$(( size / 1048576 ))
            # Si ya terminó de bajar → reproducir de inmediato
            case "$state" in
                uploading|stalledUP|pausedUP|forcedUP|checkingUP|completed)
                    ok "Descarga completa (${size_mb} MB) — reproduciendo."
                    break ;;
            esac
            # Si está bajando y tiene suficientes datos para bufferear
            if [[ $size -gt $min_size ]]; then
                ok "Suficientes datos (${size_mb} MB) — reproduciendo."
                break
            fi
            info "Descargando... ${size_mb} MB (mínimo 50 MB para reproducir)"
        else
            info "Esperando inicio de descarga... (${tries}s)"
        fi

        sleep 5
        tries=$(( tries + 5 ))
    done

    if [[ -z "$found_file" || ! -f "$found_file" ]]; then
        warn "No se encontró archivo de video."
        warn "Buscá en: $DOWNLOAD_DIR"
        warn "O en la WebUI: $QBT_HOST"
        exit 0
    fi

    echo ""
    ok "▶  Reproduciendo: $(basename "$found_file")"
    mpv \
        --cache=yes \
        --cache-secs=120 \
        --demuxer-readahead-secs=60 \
        --force-seekable=yes \
        --title="$(basename "$found_file")" \
        "$found_file"
}

# ═══════════════════════════════════════════════════════════════════════════════
banner

case "$MODE" in
    reset)  do_reset ;;
    setup)  do_setup ;;
    stream)
        info "Búsqueda: '${BOLD}${QUERY}${RESET}'"
        echo ""
        check_deps
        configure_qbt
        start_qbt
        login_qbt
        start_jackett
        get_jackett_key
        search_torrent
        pick_torrent
        add_torrent
        wait_and_play
        echo ""
        ok "¡Disfrutá la película! 🍿"
        ;;
esac
