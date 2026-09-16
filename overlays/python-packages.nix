final: prev: {
  pythonPackagesExtensions =
    prev.pythonPackagesExtensions
    ++ [
      (python-final: python-prev: {
        # patool 4.0.5 archive/mime tests fail on current nixpkgs (bzip2/xz
        # helpers missing); the package itself works. Disables the check phase.
        patool = python-prev.patool.overridePythonAttrs (_: {
          doCheck = false;
        });

        mrml = python-final.buildPythonPackage rec {
          pname = "mrml";
          version = "0.1.15";
          format = "pyproject";

          src = python-final.fetchPypi {
            inherit pname version;
            sha256 = "sha256-XbYRkJ6tptG0LUYZQAF5UsHjpm9ys2graxDmn1BUz6A=";
          };

          nativeBuildInputs = with final; [
            cargo
            rustPlatform.cargoSetupHook
            rustc
          ];

          build-system = [
            final.rustPlatform.maturinBuildHook
          ];

          cargoDeps = final.rustPlatform.fetchCargoVendor {
            inherit src;
            name = "${pname}-${version}";
            hash = "sha256-g2d6NRGrjNIdG5KLSeGUaZU8JsevxJo98i+pGU/HU0E=";
          };

          useFetchCargoVendor = true;

          doCheck = false;
          propagatedBuildInputs = [];
        };

        # Hilo (Hydro-Québec) API client, required by the hilo Home Assistant
        # component (packages/home-assistant-hilo). Not in nixpkgs.
        python-hilo = python-final.buildPythonPackage rec {
          pname = "python-hilo";
          version = "2026.9.1";
          pyproject = true;

          src = python-final.fetchPypi {
            pname = "python_hilo";
            inherit version;
            hash = "sha256-YALMLy0F761q8kJ6OBrnLyH2zVPd0HPUBTC5faHmoe8=";
          };

          build-system = [python-final.hatchling];

          dependencies = with python-final;
            [
              aiofiles
              aiohttp
              backoff
              httpx
              httpx-sse
              pysignalr
              python-dateutil
              pyyaml
            ]
            ++ httpx.optional-dependencies.http2;

          # No tests or import check: pyhilo imports homeassistant itself, which
          # only exists inside Home Assistant's own environment.
          doCheck = false;
        };
      })
    ];
}
