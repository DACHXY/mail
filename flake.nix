{
  description = "Flectar Mail dev shell and Linux package";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # The dlopen'd winit/fontique backends below and the bundled PDFium
      # build are Linux/x86_64-specific; macOS, Windows, iOS, and Android
      # build through the separate platform/ toolchains instead.
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      version = (builtins.fromTOML (builtins.readFile ./Cargo.toml)).package.version;

      # dbus and libudev (via systemd) are linked at build time and show up
      # in `ldd`. wayland, X11, libxkbcommon, fontconfig, and freetype are
      # opened at runtime through winit's and fontique's `*-dlopen` features
      # instead, so they never appear as DT_NEEDED entries: a hook that only
      # patches an ELF's existing rpath from its linked dependencies (e.g.
      # autoPatchelfHook) would silently drop them. They're listed here so
      # both outputs below can add them to rpath/LD_LIBRARY_PATH explicitly.
      runtimeLibs = with pkgs; [
        wayland
        wayland-protocols
        libxkbcommon
        libGL
        vulkan-loader
        libx11
        libxcursor
        libxi
        libxrandr
        libxext
        fontconfig
        freetype
        dbus
        systemd # provides libudev
      ];

      # Matches packaging/flatpak/com.flectar.mail.yml: PDF preview loads
      # this prebuilt PDFium build at runtime via dlopen, so it's fetched and
      # staged next to the binary rather than built from source or linked.
      pdfiumRuntime = pkgs.fetchzip {
        url = "https://github.com/bblanchon/pdfium-binaries/releases/download/chromium%2F8044/pdfium-linux-x64.tgz";
        # fetchzip hashes the *unpacked* tree, unlike the tarball sha256
        # packaging/flatpak/com.flectar.mail.yml records for this same release.
        hash = "sha256-cX6LytYlS2SsvbyRc04DNGlyDxP/erLz8V7MqfD/pyo=";
        stripRoot = false;
      };
    in
    {
      packages.${system}.default = pkgs.rustPlatform.buildRustPackage {
        pname = "flectar-mail";
        inherit version;
        src = self;

        cargoLock.lockFile = ./Cargo.lock;

        # Some unit tests are gated on `debug_assertions`, which release
        # profiles disable; this package only needs the release binary.
        doCheck = false;

        nativeBuildInputs = [
          pkgs.pkg-config
          pkgs.python3 # stylo's build.rs shells out to `python3` to generate style properties
        ];
        buildInputs = runtimeLibs;

        # src/pdf_preview.rs's library_path() looks for a packaged PDFium next
        # to the executable at ../lib/flectar-mail (or ../lib64/flectar-mail).
        postInstall = ''
          install -Dm0755 ${pdfiumRuntime}/lib/libpdfium.so "$out/lib/flectar-mail/libpdfium.so"
          install -Dm0644 resources/com.flectar.mail.desktop "$out/share/applications/com.flectar.mail.desktop"
          install -Dm0644 resources/app-icon/flectar-mail-masked-512.png \
            "$out/share/icons/hicolor/512x512/apps/com.flectar.mail.png"
          install -Dm0644 resources/app-icon/flectar-mail-masked.svg \
            "$out/share/icons/hicolor/scalable/apps/com.flectar.mail.svg"
        '';

        # See the runtimeLibs comment above: several of these are dlopen'd,
        # not linked, so they must be added to rpath explicitly rather than
        # relying on a linked-dependency scan.
        postFixup = ''
          patchelf --set-rpath "${pkgs.lib.makeLibraryPath runtimeLibs}" "$out/bin/flectar-mail"
        '';

        meta = {
          description = "A native email client built with Rust, Slint, and Blitz";
          homepage = "https://flectar.com";
          license = pkgs.lib.licenses.agpl3Only;
          mainProgram = "flectar-mail";
          platforms = [ system ];
        };
      };

      apps.${system}.default = {
        type = "app";
        program = "${self.packages.${system}.default}/bin/flectar-mail";
        meta.description = "Run the packaged Flectar Mail binary";
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.cargo
          pkgs.rustc
          pkgs.rust-analyzer
          pkgs.clippy
          pkgs.rustfmt
          pkgs.pkg-config
          pkgs.cargo-machete
          pkgs.python3 # stylo's build.rs shells out to `python3` to generate style properties
        ] ++ runtimeLibs;

        RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";

        # Linked native libraries are looked up via pkg-config at build time...
        PKG_CONFIG_PATH = pkgs.lib.makeSearchPathOutput "dev" "lib/pkgconfig" runtimeLibs;

        # ...and via the dynamic loader at run time, since cargo-built
        # binaries aren't wrapped/patched the way nixpkgs derivations are.
        LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath runtimeLibs;

        shellHook = ''
          echo "flectar-mail dev shell: $(rustc --version)"
        '';
      };
    };
}
