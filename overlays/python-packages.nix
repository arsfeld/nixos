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
      })
    ];
}
