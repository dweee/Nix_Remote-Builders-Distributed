{ pkgs, ... }:
pkgs.writeShellApplication {
  name = "nix-remote";
  runtimeInputs = with pkgs; [
    nushell
    gh
    nix-eval-jobs
    nix-fast-build
  ];
  text = ''
    exec nu "${../src/nix-remote.nu}" "$@"
  '';
}
