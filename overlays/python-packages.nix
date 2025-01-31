final: prev: {
  pythonPackagesExtensions =
    prev.pythonPackagesExtensions
    ++ [
      (python-final: python-prev: {
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

          cargoDeps = final.rustPlatform.fetchCargoTarball {
            inherit src;
            name = "${pname}-${version}";
            hash = "sha256-5cEQMCWM473y+se6jWuWr/T9Pg/Q6BuD4ypGF1SBF6M=";
          };

          doCheck = false;
          propagatedBuildInputs = [];
        };
      })
    ];
}
