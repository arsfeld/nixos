{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
}: let
  version = "0.128.2";

  sources = {
    x86_64-linux = {
      url = "https://github.com/SigNoz/signoz-otel-collector/releases/download/v${version}/signoz-schema-migrator_linux_amd64.tar.gz";
      sha256 = "sha256-pRe/56oYmNEdpxIVknRXedzBMPdN9Qtr0RFnQiNoRwU=";
    };
    aarch64-linux = {
      url = "https://github.com/SigNoz/signoz-otel-collector/releases/download/v${version}/signoz-schema-migrator_linux_arm64.tar.gz";
      sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    };
  };

  source = sources.${stdenv.hostPlatform.system} or (throw "Unsupported system: ${stdenv.hostPlatform.system}");
in
  stdenv.mkDerivation rec {
    pname = "signoz-schema-migrator";
    inherit version;

    src = fetchurl {
      inherit (source) url sha256;
    };

    nativeBuildInputs = [autoPatchelfHook];

    sourceRoot = ".";

    installPhase = ''
      runHook preInstall

      mkdir -p $out/bin
      cp -r signoz-schema-migrator_linux_*/bin/* $out/bin/
      chmod +x $out/bin/*

      runHook postInstall
    '';

    meta = with lib; {
      description = "SigNoz schema migrator for ClickHouse";
      homepage = "https://signoz.io";
      license = licenses.asl20;
      platforms = ["x86_64-linux" "aarch64-linux"];
      maintainers = with maintainers; [];
    };
  }
