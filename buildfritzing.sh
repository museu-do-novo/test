#!/usr/bin/env bash
set -euo pipefail

QT_VERSION="6.8.3"
WORKDIR="${WORKDIR:-$HOME/fritzing-build}"
QT_DIR="$WORKDIR/Qt/$QT_VERSION/gcc_64"
DEPS="$WORKDIR/deps"
APP_DIR="$WORKDIR/fritzing-app"

mkdir -p "$WORKDIR" "$DEPS"

# 1. Dependências + aqtinstall
sudo apt update && sudo apt install -y --no-install-recommends \
  build-essential git cmake pkg-config python3-pip python3-full \
  libssl-dev zlib1g-dev libgit2-dev libboost-dev libpolyclipping-dev \
  libngspice0-dev libgl1-mesa-dev libglu1-mesa-dev libfontconfig1-dev \
  libfreetype6-dev libx11-xcb-dev libxcb-cursor0 libxcb-keysyms1 rsync wget

pip install --no-cache-dir aqtinstall --break-system-packages

# 2. Baixar Qt
[ -x "$QT_DIR/bin/qmake" ] || aqt install-qt linux desktop "$QT_VERSION" -m qt5compat qtserialport --outputdir "$WORKDIR/Qt"

# 3. QuaZip
if [ ! -f "$DEPS/lib/pkgconfig/quazip1-qt6.pc" ]; then
  git clone --depth 1 --branch v1.4 https://github.com/stachenov/quazip.git "$WORKDIR/quazip"
  cmake -S "$WORKDIR/quazip" -B "$WORKDIR/quazip/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$QT_DIR" -DCMAKE_INSTALL_PREFIX="$DEPS" -DQUAZIP_QT_MAJOR_VERSION=6 -DQUAZIP_ENABLE_TESTS=OFF
  cmake --build "$WORKDIR/quazip/build" -j$(nproc) && cmake --install "$WORKDIR/quazip/build"
fi

# 4. Clonar repositórios
[ -d "$APP_DIR" ] || git clone --depth 1 https://github.com/fritzing/fritzing-app.git "$APP_DIR"
[ -d "$APP_DIR/parts" ] || git clone --depth 1 https://github.com/fritzing/fritzing-parts.git "$APP_DIR/parts"
[ -d "$WORKDIR/svgpp" ] || git clone --depth 1 https://github.com/svgpp/svgpp.git "$WORKDIR/svgpp"

# 5. Configurar e Compilar de forma totalmente dinâmica
export PKG_CONFIG_PATH="$DEPS/lib/pkgconfig:$DEPS/lib/x86_64-linux-gnu/pkgconfig"
export LD_LIBRARY_PATH="$DEPS/lib:$DEPS/lib/x86_64-linux-gnu:$QT_DIR/lib"

NG_NAME="$(grep -ohE 'ngspice-[0-9]+' "$APP_DIR/pri/spicedetect.pri" | head -1)"
rm -rf "$WORKDIR/$NG_NAME" && mkdir -p "$WORKDIR/$NG_NAME"
ln -sf /usr/include/ngspice "$WORKDIR/$NG_NAME/include"

QT_FULL="$("$QT_DIR/bin/qmake" -query QT_VERSION)"
QZ_VER="$(grep -ohE 'QUAZIP_VERSION=[0-9.]+' "$APP_DIR/pri/quazipdetect.pri" | cut -d= -f2)"
QZ_DIR="$WORKDIR/quazip-${QT_FULL}-${QZ_VER}intuisphere"
rm -rf "$QZ_DIR" && mkdir -p "$QZ_DIR"
ln -sf "$DEPS/include" "$QZ_DIR/include"
ln -sf "$DEPS/lib" "$QZ_DIR/lib"

echo "INCLUDEPATH += $WORKDIR/svgpp/include" > "$APP_DIR/pri/svgppdetect.pri"
echo -e "INCLUDEPATH += /usr/include/polyclipping\nLIBS += -lpolyclipping" > "$APP_DIR/pri/clipper1detect.pri"

cd "$APP_DIR"
"$QT_DIR/bin/qmake" CONFIG+=release phoenix.pro
make -j$(nproc)

# 6. Empacotar AppImage (Caminhos relativos e portáteis)
APPDIR="$WORKDIR/Fritzing.AppDir"
rm -rf "$APPDIR" && mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" "$APPDIR/usr/plugins" "$APPDIR/usr/share/applications"

cp "$APP_DIR/Fritzing" "$APPDIR/usr/bin/"
cp -r "$APP_DIR/parts" "$APPDIR/usr/bin/"
cp -a "$QT_DIR/lib"/libQt6*.so* "$APPDIR/usr/lib/"
cp -a "$QT_DIR/lib"/libicu*.so* "$APPDIR/usr/lib/" 2>/dev/null || true
cp -a "$DEPS/lib"/libquazip1-qt6.so* "$APPDIR/usr/lib/" 2>/dev/null || true
cp -a "$DEPS/lib/x86_64-linux-gnu"/libquazip1-qt6.so* "$APPDIR/usr/lib/" 2>/dev/null || true
ldd "$APP_DIR/Fritzing" | awk '/=> \//{print $3}' | grep -E 'polyclipping|libgit2|ngspice' | xargs -r -I{} cp -L {} "$APPDIR/usr/lib/"
cp -a /usr/lib/x86_64-linux-gnu/libngspice.so* "$APPDIR/usr/lib/" 2>/dev/null || true

for p in platforms imageformats iconengines xcbglintegrations platforminputcontexts sqldrivers tls; do
  [ -d "$QT_DIR/plugins/$p" ] && cp -a "$QT_DIR/plugins/$p" "$APPDIR/usr/plugins/"
done

cat << 'EOF' > "$APPDIR/AppRun"
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$HERE/usr/lib:$LD_LIBRARY_PATH"
export QT_PLUGIN_PATH="$HERE/usr/plugins"
exec "$HERE/usr/bin/Fritzing" "$@"
EOF
chmod +x "$APPDIR/AppRun"

echo -e "[Desktop Entry]\nType=Application\nName=Fritzing\nExec=Fritzing\nIcon=fritzing\nCategories=Development;" > "$APPDIR/fritzing.desktop"
cp "$APPDIR/fritzing.desktop" "$APPDIR/usr/share/applications/"

wget -q -O "$APPDIR/fritzing.png" https://raw.githubusercontent.com/fritzing/fritzing-app/develop/src/icons/fritzing.png

[ -f "$WORKDIR/appimagetool" ] || wget -O "$WORKDIR/appimagetool" https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
chmod +x "$WORKDIR/appimagetool"

cd "$WORKDIR"
./appimagetool --appimage-extract > /dev/null
ARCH=x86_64 ./squashfs-root/AppRun "$APPDIR" "$HOME/Fritzing-x86_64.AppImage"

echo "Pronto! AppImage gerado em: $HOME/Fritzing-x86_64.AppImage"
