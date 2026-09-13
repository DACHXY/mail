{
  description = "Flectar Mail development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, rust-overlay, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
        };

        # Cargo.toml pins rust-version = "1.92"; keep the toolchain new enough
        # for edition 2024 and add the components used by cargo fmt/clippy.
        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          extensions = [ "rust-src" "rust-analyzer" "clippy" "rustfmt" ];
        };

        # winit's wayland/x11 backends, arboard's wayland-data-control clipboard,
        # dbus-secret-service credential storage, and the udev crate all need
        # their native libraries at both link and run time.
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
      in
      {
        devShells.default = pkgs.mkShell {
          packages = [
            rustToolchain
            pkgs.pkg-config
            pkgs.cargo-machete
            pkgs.python3 # stylo's build.rs shells out to `python3` to generate style properties
          ] ++ runtimeLibs;

          # Linked native libraries are looked up via pkg-config at build time...
          PKG_CONFIG_PATH = pkgs.lib.makeSearchPathOutput "dev" "lib/pkgconfig" runtimeLibs;

          # ...and via the dynamic loader at run time, since cargo-built
          # binaries aren't wrapped/patched the way nixpkgs derivations are.
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath runtimeLibs;

          # Matches .cargo/config.toml: Slint's generated code and the Blitz
          # test harness can exhaust memory on constrained dev machines when
          # built in parallel.
          CARGO_BUILD_JOBS = "1";

          shellHook = ''
            echo "flectar-mail dev shell: $(rustc --version)"
          '';
        };
      });
}
