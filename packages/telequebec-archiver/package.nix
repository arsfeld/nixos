{pkgs, ...}: let
  python = pkgs.python3;
  lib = pkgs.lib;
in
  python.pkgs.buildPythonApplication {
    pname = "telequebec-archiver";
    version = "0.1.0";
    pyproject = true;
    src = ./.;

    nativeBuildInputs = with python.pkgs; [
      setuptools
    ];

    dependencies = with python.pkgs; [
      requests
      beautifulsoup4
    ];

    # Downloads are delegated to yt-dlp (which itself needs ffmpeg for muxing
    # and thumbnail embedding); ensure both are on PATH at runtime.
    makeWrapperArgs = [
      "--prefix PATH : ${lib.makeBinPath [pkgs.yt-dlp pkgs.ffmpeg]}"
    ];

    pythonImportsCheck = ["telequebec_archiver"];

    doCheck = false;

    meta = with lib; {
      description = "Archive Télé-Québec series into a Plex-friendly layout";
      license = licenses.mit;
      mainProgram = "telequebec-archiver";
    };
  }
