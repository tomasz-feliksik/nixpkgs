{
  lib,
  stdenv,
  rustPlatform,
  fetchFromGitHub,
  git,
  cargo-bundle,
  fontconfig,
  freetype,
  libGL,
  libxcb,
  libxkbcommon,
  makeBinaryWrapper,
  nix-update-script,
  openssl,
  pkg-config,
  versionCheckHook,
  vulkan-loader,
  wayland,
}:

let
  # crates/openlogi-desktop/build.rs embeds gpui-component's themes, which live at
  # that repo's root rather than inside the crate, so cargo vendoring drops them.
  # Fetch the rev Cargo.lock pins and point build.rs's OPENLOGI_THEMES_DIR
  # escape hatch at it. This pin follows Cargo.lock rather than openlogi's
  # version, and nix-update does not maintain it.
  gpuiComponentThemes = fetchFromGitHub {
    owner = "AprilNEA";
    repo = "gpui-kit";
    rev = "1ac69bd51f744f3664361d9abd609bfc16de489f";
    hash = "sha256-up6s9rM5brgtiBQq9CSQRf8vJ4vE2ZhY4d8wRE1nfDk=";
  };
in

rustPlatform.buildRustPackage (finalAttrs: {
  pname = "openlogi";
  version = "0.8.13";

  __structuredAttrs = true;

  src = fetchFromGitHub {
    owner = "AprilNEA";
    repo = "OpenLogi";
    tag = "v${finalAttrs.version}";
    hash = "sha256-1c8a6QDMajiFqUc9dc8dmlWuzO8Pxsq1parD79iSGWQ=";
  };

  cargoHash = "sha256-V6EhwbblXRePcfVZ0DgMR9YRHlKp06Xfo4N3fE9pcLk=";

  postPatch = ''
    grep -q 'gpui-kit?rev=${gpuiComponentThemes.rev}' Cargo.lock || {
      echo "ERROR: gpui-component revision needs update (must match Cargo.lock)"
      exit 1
    }

    # Dev-only cargo runner wraps test binaries in a throwaway .app bundle;
    # the Nix darwin sandbox refuses to exec it, so cargo test aborts with
    # EPERM before the binary runs. Strip it — tests don't need the bundle.
    substituteInPlace .cargo/config.toml \
      --replace-fail 'runner = ".cargo/run-macos.sh"' ""
  '';

  nativeBuildInputs = [
    rustPlatform.bindgenHook
  ]
  ++ lib.optionals stdenv.hostPlatform.isDarwin [
    cargo-bundle
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [
    makeBinaryWrapper
    pkg-config
  ];

  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
    fontconfig
    freetype
    libGL
    libxcb
    libxkbcommon
    openssl
    vulkan-loader
    wayland
  ];

  # Name the binaries: selecting the openlogi-agent package alone also builds
  # its development-only openlogi-agent-mock.
  cargoBuildFlags = [
    "--package=openlogi"
    "--bin=openlogi"
    "--package=openlogi-desktop"
    "--bin=openlogi-desktop"
    "--package=openlogi-agent"
    "--bin=openlogi-agent"
    "--package=openlogi-overlay"
    "--bin=openlogi-overlay"
  ];

  # Upstream's Linux CI selection; the desktop interaction suite runs on macOS.
  cargoTestFlags = [
    "--workspace"
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [
    "--exclude=openlogi-desktop"
  ];

  # xtask's release tests `git init` throwaway repositories.
  nativeCheckInputs = [ git ];

  buildFeatures = lib.optionals stdenv.hostPlatform.isDarwin [
    "gpui_platform/runtime_shaders"
  ];

  env.OPENLOGI_THEMES_DIR = "${gpuiComponentThemes}/themes";

  installPhase = ''
    runHook preInstall

    release_target="target/${stdenv.hostPlatform.rust.cargoShortTarget}/release"
  ''
  + lib.optionalString stdenv.hostPlatform.isDarwin ''
    mv "$release_target/openlogi-desktop" target/release/openlogi-desktop

    # cargo-bundle's resources glob points at device assets, which upstream
    # fetches on first launch instead of bundling.
    mkdir -p crates/openlogi-desktop/assets

    pushd crates/openlogi-desktop
    export CARGO_BUNDLE_SKIP_BUILD=true
    app_path=$(cargo bundle --release --format osx | xargs)
    popd

    mkdir -p "$out/Applications" "$out/bin"
    mv "$app_path" "$out/Applications/"
    app="$out/Applications/OpenLogi.app"

    # The rest mirrors upstream's `xtask macos bundle` (production channel),
    # minus code signing and the Xcode-compiled icon catalog (Assets.car);
    # macOS falls back to the .icns cargo-bundle installs.

    # The CLI ships inside the app, next to the GUI.
    install -Dm755 "$release_target/openlogi" "$app/Contents/MacOS/openlogi"
    ln -s "$app/Contents/MacOS/openlogi" "$out/bin/openlogi"

    # The agent and the Actions Ring overlay are login-item helpers nested in
    # the app; the GUI resolves them relative to its own executable. Their
    # Info.plist templates are upstream's, with the 0.0.0 version sentinel
    # stamped the way xtask does it.
    install_helper() {
      local name=$1 binary=$2 template=$3
      local helper="$app/Contents/Library/LoginItems/$name.app"
      install -Dm755 "$release_target/$binary" "$helper/Contents/MacOS/$binary"
      install -Dm644 "crates/openlogi-desktop/bundle/$template/Info.plist" \
        "$helper/Contents/Info.plist"
      substituteInPlace "$helper/Contents/Info.plist" \
        --replace-fail "<string>0.0.0</string>" "<string>${finalAttrs.version}</string>"
      install -Dm644 crates/openlogi-desktop/icon/AppIcon.icns \
        "$helper/Contents/Resources/AppIcon.icns"
    }
    install_helper "OpenLogi Agent" openlogi-agent agent-release
    install_helper "OpenLogi Overlay" openlogi-overlay overlay-release
    ln -s "$app/Contents/Library/LoginItems/OpenLogi Agent.app/Contents/MacOS/openlogi-agent" \
      "$out/bin/openlogi-agent"

    # The agent is registered as a bundled launch agent (SMAppService); its
    # plist names the helper's executable relative to the app.
    mkdir -p "$app/Contents/Library/LaunchAgents"
    cat > "$app/Contents/Library/LaunchAgents/org.openlogi.agent.service.plist" <<EOF
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>BundleProgram</key>
      <string>Contents/Library/LoginItems/OpenLogi Agent.app/Contents/MacOS/openlogi-agent</string>
      <key>KeepAlive</key>
      <dict>
        <key>SuccessfulExit</key>
        <false/>
      </dict>
      <key>Label</key>
      <string>org.openlogi.agent.service</string>
    </dict>
    </plist>
    EOF

    # The webcam preview needs a camera usage description, or macOS terminates
    # the app on first access.
    substituteInPlace "$app/Contents/Info.plist" \
      --replace-fail "<key>CFBundleIdentifier</key>" \
      "<key>NSCameraUsageDescription</key>
    <string>OpenLogi previews your Logitech webcam locally. Video never leaves your Mac.</string>
    <key>CFBundleIdentifier</key>"
  ''
  + lib.optionalString stdenv.hostPlatform.isLinux ''
    install -Dm755 "$release_target/openlogi" "$out/bin/openlogi"
    install -Dm755 "$release_target/openlogi-desktop" "$out/bin/openlogi-desktop"
    install -Dm755 "$release_target/openlogi-agent" "$out/bin/openlogi-agent"
    install -Dm755 "$release_target/openlogi-overlay" "$out/bin/openlogi-overlay"

    # Upstream's own packaging inputs, installed verbatim rather than
    # re-authored here (they are what the .deb/.rpm ship).
    install -Dm644 packaging/linux/udev/70-openlogi.rules \
      "$out/lib/udev/rules.d/70-openlogi.rules"
    install -Dm644 packaging/linux/desktop/openlogi.desktop \
      "$out/share/applications/openlogi.desktop"
    install -Dm644 packaging/linux/systemd/openlogi-agent.service \
      "$out/share/systemd/user/openlogi-agent.service"

    # The unit hardcodes /usr/bin (upstream's install.sh rewrites it for a
    # custom PREFIX); point it at the store path instead.
    substituteInPlace "$out/share/systemd/user/openlogi-agent.service" \
      --replace-fail "ExecStart=/usr/bin/openlogi-agent" \
                     "ExecStart=$out/bin/openlogi-agent"

    install -Dm644 design/icon/openlogi.png \
      "$out/share/icons/hicolor/1024x1024/apps/openlogi.png"
    # A stock hicolor index stops at 512x512, so install the indexed sizes too.
    for size in 512 256 128 64 48 32 16; do
      install -Dm644 "design/icon/openlogi-$size.png" \
        "$out/share/icons/hicolor/''${size}x''${size}/apps/openlogi.png"
    done
  ''
  + ''
    runHook postInstall
  '';

  # GPUI (Blade) dlopen()s its Vulkan/Wayland/GL backends at runtime, so they
  # are invisible to the linker and must be on the wrapper's search path.
  postFixup = lib.optionalString stdenv.hostPlatform.isLinux ''
    for program in openlogi-desktop openlogi-overlay; do
      wrapProgram "$out/bin/$program" \
        --suffix LD_LIBRARY_PATH : "${
          lib.makeLibraryPath [
            libGL
            libxcb
            libxkbcommon
            vulkan-loader
            wayland
          ]
        }"
    done
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];
  versionCheckProgramArg = "--version";

  passthru.updateScript = nix-update-script { };

  meta = {
    description = "Local-first companion for Logitech HID++ peripherals";
    homepage = "https://github.com/AprilNEA/OpenLogi";
    changelog = "https://github.com/AprilNEA/OpenLogi/releases/tag/v${finalAttrs.version}";
    license = with lib.licenses; [
      asl20
      mit
    ];
    mainProgram = "openlogi";
    maintainers = with lib.maintainers; [ imcvampire ];
    platforms = lib.platforms.darwin ++ [
      "aarch64-linux"
      "x86_64-linux"
    ];
  };
})
