{ pkgs
, runTests ? false
}:

let
  inherit (pkgs) lib;
  pyPkgs = pkgs.python3Packages;
  projectRoot = ../.;
  includedDirs = [
    "nix"
    "ochami"
    "ochami-helm"
    "scripts"
    "tests"
  ];
  includedFiles = [
    ".gitignore"
    "Makefile"
    "README.md"
    "flake.nix"
    "pyproject.toml"
  ];
  relPath = path:
    let
      pathString = toString path;
      rootString = toString projectRoot;
    in
      if pathString == rootString then "" else lib.removePrefix "${rootString}/" pathString;
  src = lib.cleanSourceWith {
    src = projectRoot;
    filter = path: type:
      let
        relative = relPath path;
        inIncludedDir = lib.any (dir: relative == dir || lib.hasPrefix "${dir}/" relative) includedDirs;
      in
        relative == ""
        || builtins.elem relative includedFiles
        || inIncludedDir;
  };
in
pyPkgs.buildPythonApplication rec {
  pname = "ochami-mcp";
  version = "0.1.0";
  pyproject = true;
  inherit src;

  nativeBuildInputs = with pyPkgs; [
    setuptools
    wheel
  ];

  # MCP server has zero runtime dependencies (stdlib only).
  propagatedBuildInputs = [ ];

  nativeCheckInputs = lib.optionals runTests (with pyPkgs; [
    pytest
    pytestCheckHook
  ]);

  doCheck = runTests;
  pytestFlagsArray = lib.optionals runTests [ "tests" ];
  pythonImportsCheck = [ "ochami" "ochami.mcp" ];
  strictDeps = true;

  meta = {
    description = "OpenCHAMI MCP server — local control plane for OpenCHAMI deployments";
    homepage = "https://github.com/aescoubas/ochami-from-scratch";
    license = lib.licenses.asl20;
    mainProgram = "ochami-mcp";
    platforms = lib.platforms.unix;
  };
}
