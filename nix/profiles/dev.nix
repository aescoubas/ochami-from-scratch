let
  refs = {
    bss = "main";
    smd = "main";
    cloudInit = "main";
    keaSync = "main";
    pcs = "main";
    httpServer = "latest";
    tftp = "latest";
  };
in
{
  name = "dev";
  inherit refs;

  sources = {
    smd = {
      owner = "openchami";
      repo = "smd";
      rev = refs.smd;
      hash = "sha256-SKAao/ib26e2I0QKprxQjUcxD9gFKdFHUwJpGfLTLkc=";
      vendorHash = "sha256-Gqvn+GMctybEOhLsXo1/2TewpGiO7c0IO/YFC2TPWKQ=";
    };
    bss = {
      owner = "openchami";
      repo = "bss";
      rev = refs.bss;
      hash = "sha256-NGgLB/2o6KW1ZPAlbITtlRSurja93lLBjyHVkhmDGaE=";
      vendorHash = "sha256-TXBznp95gkHKc76UgwQJ+xQHD8HfAC7nbfse0YrjH9A=";
    };
    pcs = {
      owner = "OpenCHAMI";
      repo = "power-control";
      rev = refs.pcs;
      hash = "sha256-CmTGafEqDZg2rpjLdo32qpy5mMHS567OSM0ITco34Sk=";
      vendorHash = "sha256-hiCp1uHyJx75sFQGW7L+x6YtYsH9y5ZkL54I6dQdQu0=";
    };
    cloudInit = {
      owner = "openchami";
      repo = "cloud-init";
      rev = refs.cloudInit;
      hash = "sha256-TxEYFe9Kkp2i9bmx/+BGMJgDfiklTi2J0kV4ydk31Ns=";
      vendorHash = "sha256-ZpOjgzPU3dksbHpe9QTH+uGRQvg6clZUjfLEOLfUyfw=";
    };
  };

  containerServiceIds = [
    "postgres"
    "smd-init"
    "smd"
    "bss-init"
    "bss"
    "cloud-init"
    "pcs-init"
    "pcs"
    "kea-init"
    "kea"
    "kea-sync"
    "http-server"
    "tftp"
  ];

  scriptServiceIds = [
    "bss-boot-defaults"
  ];

  enableStork = false;
}
