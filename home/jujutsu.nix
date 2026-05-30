{pkgs, ...}: {
  programs.jujutsu = {
    enable = true;
    settings = {
      user = {
        name = "Alexandre Rosenfeld";
        email = "arsfeld@gmail.com";
      };
    };
  };
}
