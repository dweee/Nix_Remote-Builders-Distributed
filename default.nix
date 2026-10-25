{ pkgs, ... }:
let
  package = pkgs.callPackage ./nix/package.nix { };
  homeManagerModule = import ./nix/modules/home-manager.nix;
  nixosModule = import ./nix/modules/nixos.nix;
  darwinModule = import ./nix/modules/darwin.nix;
in
package
// {
  nixosModules = {
    nix-remote = nixosModule;
    default = nixosModule;
  };
  darwinModules = {
    nix-remote = darwinModule;
    default = darwinModule;
  };
  homeManagerModules = {
    nix-remote = homeManagerModule;
    default = homeManagerModule;
  };
}
