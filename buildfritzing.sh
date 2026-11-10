#!/usr/bin/env bash
# build-fritzing.sh
# Instala as dependências e compila o Fritzing (Qt 6.8.3) no Debian 13 / Codespaces.

set -euo pipefail
trap 'echo "ERRO na linha $LINENO (comando: $BASH_COMMAND)" >&2' ERR

# Forçado para 6.8.3 para evitar incompatibilidade com o código atual do Fritzing
QT_VERSION="${QT_VERSION:-6.8.3}"
WORKDIR="${WORKDIR:-$HOME/fritzing-build}"
JOBS="${JOBS:-$(nproc)}"
APP_REF="${APP_REF:-}"
PARTS_REF="${PARTS_REF:-}"

QT_ROOT="$WORKDIR/Qt"
QT_DIR="$QT_ROOT/$QT_VERSION/gcc_64"
DEPS="$WORKDIR/deps"
APP_DIR="$WORKDIR/fritzing-app"
SVGPP_DIR="$WORKDIR/svgpp"
QUAZIP_TAG="v1.4"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

sync_repo() {
  local url="$1" dir="$2" ref="${3:-}"
  if [ -d "$dir/.git" ]; then
    git -C "$dir" fetch --depth 1 origin ${ref:+"$ref"}
    git -C "$dir" checkout -qf FETCH_HEAD
  else
    git clone --depth 1 "$url" "$dir"
    if [ -n "$ref" ]; then
      git -C "$dir" fetch --depth 1 origin "$ref"
      git -C "$dir" checkout -q FETCH_HEAD
    fi
  fi
}

mkdir -p "$WORKDIR" "$DEPS"

# ---------------------------------------------------------------------------
log "1/7 Dependências do sistema (apt)"
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  build-essential git cmake pkg-config ca-certificates \
  python3 python3-venv python3-pip \
  libssl-dev zlib1g-dev libbz2-dev \
  libgit2-dev libboost-dev libpolyclipping-dev libngspice0-dev \
  libgl1-mesa-dev libglu1-mesa-dev libegl1 libxkbcommon-dev \
  libxkbcommon-x11-0 libfontconfig1-dev libfreetype6-dev libdbus-1-dev \
  libx11-xcb-dev libxcb-cursor0 libxcb-icccm4 libxcb-image0 \
  libxcb-keysyms1 libxcb-render-util0 libxcb-xinerama0 libxcb-xkb1 \
  rsync tar

# ---------------------------------------------------------------------------
log "2/7 Qt $QT_VERSION (via aqtinstall)"
if [ ! -x "$QT_DIR/bin/qmake" ] \
   || [ ! -d "$QT_DIR/lib/cmake/Qt6Core5Compat" ] \
   || [ ! -d "$QT_DIR/lib/cmake/Qt6SerialPort" ]; then
  python3 -m venv "$WORKDIR/venv"
  # shellcheck disable=SC1091
  source "$WORKDIR/venv/bin/activate"
  pip install -U pip aqtinstall
  aqt install-qt linux desktop "$QT_VERSION" -m qt5compat qtserialport --outputdir "$QT_ROOT"
  deactivate
else
  echo "Qt já instalado em $QT_DIR, pulando."
fi
[ -x "$QT_DIR/bin/qmake" ] || { echo "qmake não encontrado em $QT_DIR"; exit 1; }

# ---------------------------------------------------------------------------
log "3/7 QuaZip $QUAZIP_TAG"
if [ ! -f "$DEPS/lib/pkgconfig/quazip1-qt6.pc" ] && \
   [ ! -f "$DEPS/lib/x86_64-linux-gnu/pkgconfig/quazip1-qt6.pc" ]; then
  rm -rf "$WORKDIR/quazip"
  git clone --depth 1 --branch "$QUAZIP_TAG" https://github.com/stachenov/quazip.git "$WORKDIR/quazip"
  cmake -S "$WORKDIR/quazip" -B "$WORKDIR/quazip/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$QT_DIR" \
    -DCMAKE_INSTALL_PREFIX="$DEPS" \
    -DQUAZIP_QT_MAJOR_VERSION=6 \
    -DQUAZIP_ENABLE_TESTS=OFF
  cmake --build "$WORKDIR/quazip/build" -j"$JOBS"
  cmake --install "$WORKDIR/quazip/build"
else
  echo "QuaZip já instalado, pulando."
fi

# ---------------------------------------------------------------------------
log "4/7 svgpp"
sync_repo https://github.com/svgpp/svgpp.git "$SVGPP_DIR"

# ---------------------------------------------------------------------------
log "5/7 Código do Fritzing e peças"
sync_repo https://github.com/fritzing/fritzing-app.git "$APP_DIR" "$APP_REF"
sync_repo https://github.com/fritzing/fritzing-parts.git "$APP_DIR/parts" "$PARTS_REF"

# ---------------------------------------------------------------------------
log "6/7 Compilando (qmake + make -j$JOBS)"
export PKG_CONFIG_PATH="$DEPS/lib/pkgconfig:$DEPS/lib/x86_64-linux-gnu/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="$DEPS/lib:$DEPS/lib/x86_64-linux-gnu:$QT_DIR/lib:${LD_LIBRARY_PATH:-}"

NG_NAME="$(grep -ohE 'ngspice-[0-9]+' "$APP_DIR/pri/spicedetect.pri" 2>/dev/null | head -1 || true)"
NG_NAME="${NG_NAME:-ngspice-42}"
NG_INC="/usr/include/ngspice"
rm -rf "$WORKDIR/$NG_NAME"
mkdir -p "$WORKDIR/$NG_NAME"
ln -s "$NG_INC" "$WORKDIR/$NG_NAME/include"

QT_FULL="$("$QT_DIR/bin/qmake" -query QT_VERSION)"
QZ_VER="$(grep -ohE 'QUAZIP_VERSION=[0-9.]+' "$APP_DIR/pri/quazipdetect.pri" 2>/dev/null | head -1 | cut -d= -f2 || true)"
QZ_VER="${QZ_VER:-1.4}"
QZ_DIR="$WORKDIR/quazip-${QT_FULL}-${QZ_VER}intuisphere"
QZ_SO="$(find "$DEPS" -name 'libquazip1-qt6.so' 2>/dev/null | head -1)"
rm -rf "$QZ_DIR"
mkdir -p "$QZ_DIR"
ln -s "$DEPS/include" "$QZ_DIR/include"
ln -s "$(dirname "$QZ_SO")" "$QZ_DIR/lib"

CLIP_INC="/usr/include/polyclipping"
cat > "$APP_DIR/pri/svgppdetect.pri" <<EOF
message("Using custom svgpp detect script.")
INCLUDEPATH += $SVGPP_DIR/include
EOF

cat > "$APP_DIR/pri/clipper1detect.pri" <<EOF
message("Using custom Clipper 1 detect script.")
INCLUDEPATH += $CLIP_INC
LIBS += -lpolyclipping
EOF

cd "$APP_DIR"
"$QT_DIR/bin/qmake" CONFIG+=release \
  PKGCONFIG+=libgit2 \
  phoenix.pro
make -j"$JOBS"

log "Pronto! Compilação concluída com sucesso em $APP_DIR/Fritzing"
