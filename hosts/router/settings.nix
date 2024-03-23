rec {
  # Rename them so they're easier to handle
  eth1 = "enp2s0";
  eth2 = "enp3s0";
  eth3 = "enp4s0";
  eth4 = "enp5s0";

  wanInterface = "${eth4}";
  lanInterfaces = ["${eth1}" "${eth2}" "${eth3}"];
}
