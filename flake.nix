{
  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs;
    utils.url = github:vkleen/machine-utils;
    utils.inputs.nixpkgs.follows = "nixpkgs";

    neovim-flake = {
      url = github:neovim/neovim?dir=contrib;
      inputs.nixpkgs.follows = "nixpkgs";
    };

    vimplugin-nvim-treesitter-context = { url = github:romgrk/nvim-treesitter-context; flake = false; };
    vimplugin-nvim-treesitter = { url = github:nvim-treesitter/nvim-treesitter; flake = false; };
  };
  outputs = inputs: let 
    inherit (inputs.utils.lib)
      filterAttrs
      forAllSystems
      mapAttrs'
      nameValuePair
      optional
      strings
      ;
    
    addRtp = path: drv:
      drv // { rtp = "${drv}/${path}"; };

    vimPlugin = pkgs: ref: vimPluginSubdir pkgs ref "";
    vimPluginSubdir = pkgs: ref_: d: let
      ref = strings.removePrefix "vimplugin-" ref_;
    in addRtp "${ref}" (pkgs.stdenv.mkDerivation {
      pname = "${strings.sanitizeDerivationName ref}";
      version = "flake";
      forceShare = [ "man" "info" ];
      nativeBuildInputs = optional
        (pkgs.stdenv.hostPlatform == pkgs.stdenv.buildPlatform)
        pkgs.vimUtils.vimGenDocHook;
      unpackPhase = ":";
      buildPhase = ":";
      configurePhase = ":";
      installPhase = ''
        runHook preInstall
        mkdir -p "$out"
        cp -r "${inputs.self.inputs."${ref_}".outPath}/${d}/"* "$out"
        runHook postInstall
      '';
    });

    update-grammars = s: let
      pkgs = inputs.nixpkgs.legacyPackages.${s};
      inherit (inputs.neovim-flake.packages.${s}) neovim;
    in pkgs.writers.writePython3 "update-grammars" {
      libraries = [];
      flakeIgnore = [ "E401" "E501" "W503" "E265" ];
    } (pkgs.substituteAll {
      src = ./ts-grammars/updater.py;
      nixPrefetchGit = "${pkgs.nix-prefetch-git}/bin/nix-prefetch-git";
      abiVersion = pkgs.runCommand "neovim-treesitter-abi-version" { nvim = "${neovim}/bin/nvim"; } ''
        $nvim -i NONE -u NONE --headless --cmd 'lua print(vim.treesitter.language_version)' --cmd qa >$out 2>&1
      '';
    });

    builtGrammars = pkgs: (pkgs.callPackage ./ts-grammars {}).builtGrammars;
    treeSitterGrammars = pkgs: grammarFn:
      let
        grammars = grammarFn (builtGrammars pkgs);
      in pkgs.linkFarm "grammars" (builtins.map (drv: let
          name = strings.getName drv;
        in {
          name = 
            (strings.replaceStrings [ "-" ] [ "_" ]
              (strings.removePrefix "tree-sitter-"
                (strings.removeSuffix "-grammar" name)))
            + pkgs.stdenv.hostPlatform.extensions.sharedLibrary;
          path = "${drv}/parser";
        })
        grammars);

  in {
    vimPluginsOverrides = pkgs: import ./overrides.nix { inherit addRtp pkgs; treeSitterGrammars = treeSitterGrammars pkgs; };
    vimPlugins = pkgs: _: mapAttrs'
      (n: v: let name = strings.removePrefix "vimplugin-" n; in nameValuePair name (vimPlugin pkgs n))
      (filterAttrs (n: _: strings.hasPrefix "vimplugin-" n) inputs.self.inputs);

    packages = forAllSystems (s: {
      update-grammars = update-grammars s;
    });
    apps = forAllSystems (s: {
      update-grammars = {
        type = "app";
        program = "${inputs.self.packages.${s}.update-grammars}";
      };
    });
    checks = forAllSystems (s:
      inputs.self.packages.${s} //
      (builtGrammars inputs.nixpkgs.legacyPackages.${s})
    );
  };
}
