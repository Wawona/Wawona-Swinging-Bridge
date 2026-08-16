{
  description = "Wawona Swinging Bridge (formerly anowaW): Cocoa/Android/(UIKit Mode B) apps as Wayland clients, locally or over waypipe-rs to Linux. Ships libanowaw (legacy ABI name) for Apple + Android. Not Desktop/LockScreen.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
    wwn-toolchain.url = "https://flakehub.com/f/Wawona/wwn-toolchain/*";
    wwn-toolchain.inputs.nixpkgs.follows = "nixpkgs";
    wwn-toolchain.inputs.rust-overlay.follows = "rust-overlay";
  };

  outputs = { self, nixpkgs, rust-overlay, wwn-toolchain, ... }:
    let
      # Nixpkgs 26.11 throws on x86_64-darwin eval; flakehub-push always runs
      # `nix flake show --all-systems`. Intel Mac still builds via Wawona's
      # registry merge with its own pkgs.
      darwinSystems = [ "aarch64-darwin" ];
      linuxSystems = [ "x86_64-linux" "aarch64-linux" ];
      allSystems = darwinSystems ++ linuxSystems;
      forAll = nixpkgs.lib.genAttrs allSystems;
      inherit (wwn-toolchain.lib) withPlatformVariants baseRegistry mkToolchains;

      pkgsFor = system: import nixpkgs {
        inherit system;
        overlays = [ (import rust-overlay) ];
        config = { allowUnfree = true; allowUnsupportedSystem = true; android_sdk.accept_license = true; };
      };

      abDir = ./dependencies/libs/anowaw;
    in
    {
      registryFragment = {
        anowaw = withPlatformVariants {
          android = abDir + "/android.nix";
          wearos = abDir + "/android.nix";
          ios = abDir + "/ios.nix";
          tvos = abDir + "/tvos.nix";
          ipados = abDir + "/ios.nix";
          visionos = abDir + "/visionos.nix";
          watchos = abDir + "/watchos.nix";
          macos = abDir + "/macos.nix";
        };
      };

      # Consumed by Wawona's flake to link the in-process bridge lib.
      lib = {
        anowawSrc = pkgs: import (abDir + "/anowaw-src.nix") { inherit pkgs; };
        srcRecipe = abDir + "/anowaw-src.nix";
        # Convenience wrapper: builds the platform static lib via the toolchain.
        mkAnowaw = { pkgs, platform ? "macos", extraArgs ? { } }:
          let
            tc = mkToolchains { inherit pkgs; registry = baseRegistry // self.registryFragment; inherit extraArgs; };
            fn = {
              macos = tc.buildForMacOS;
              ios = tc.buildForIOS;
              ipados = tc.buildForIPadOS;
              tvos = tc.buildForTVOS;
              watchos = tc.buildForWatchOS;
              visionos = tc.buildForVisionOS;
              android = tc.buildForAndroid;
              wearos = tc.buildForWearOS;
              linux = tc.buildForLinux;
            }.${platform};
          in
          fn "anowaw" { };
      };

      packages = forAll (system:
        let
          pkgs = pkgsFor system;
          tc = mkToolchains { inherit pkgs; registry = baseRegistry // self.registryFragment; };
          isDarwin = builtins.elem system darwinSystems;
        in
        (if isDarwin then {
          anowaw-macos = tc.buildForMacOS "anowaw" { };
          anowaw-ios = tc.buildForIOS "anowaw" { };
        } else { }));

      formatter = forAll (system: (pkgsFor system).nixfmt-rfc-style);
    };
}
