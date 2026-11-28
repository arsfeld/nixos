# Keeps the screen of a Pantheon test VM on. elementary's defaults blank it after
# 900 s idle (org.gnome.desktop.session idle-delay), and nothing in a test is
# input, so on a loaded CI runner, where one OCR wait has taken 510 s, a test
# that reaches its next wait_for_text after that point OCRs a black screen until
# it times out (seen 2026-11-28: "Last OCR attempt failed. Text was: ['\x0c']").
{lib, ...}: {
  programs.dconf.profiles.user.databases = [
    {settings."org/gnome/desktop/session".idle-delay = lib.gvariant.mkUint32 0;}
  ];
}
