{
  lib,
  python3,
  writeTextFile,
  writeShellScriptBin,
  iproute2,
  nftables,
  wireguard-tools,
}: let
  pythonEnv = python3.withPackages (ps:
    with ps; [
      streamlit
      pandas
    ]);

  vpnManagerScript = writeTextFile {
    name = "vpn-manager.py";
    text = builtins.readFile ./vpn-manager.py;
    executable = false;
  };
in
  writeShellScriptBin "vpn-manager" ''
    export PATH="${iproute2}/bin:${nftables}/bin:${wireguard-tools}/bin:$PATH"
    exec ${pythonEnv}/bin/streamlit run \
      --server.baseUrlPath=vpn-manager \
      --server.enableCORS=false \
      --server.enableXsrfProtection=false \
      ${vpnManagerScript} "$@"
  ''
