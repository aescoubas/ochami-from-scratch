# TFTP server for PXE boot.
{ defaults }:
{
  service = {
    name = "tftp";
    image = defaults.images.tftp;
    after = [ ];
    type = "service";
  };
}
