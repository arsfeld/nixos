# cylon-link-boot: the NixOS side of cylon-link's boot chain. See run.sh for
# the protocol on the CYLON_BOOT partition.
#
#   cylon-link-boot install TOPLEVEL P1
#     Stage TOPLEVEL as the `new` entry and refresh the firmware payload.
#     NixOS runs this as boot.loader.external's hook on every switch/boot;
#     `just flash-cylon-link` runs a build-platform copy.
#   cylon-link-boot confirm P1 CMDLINE_FILE
#     Record the running entry as good. Run once per boot with /proc/cmdline.
#
# RUN_SH, KEXEC, KEXEC_MODULE and DTB_NAME come from package.nix.

usage() {
  echo "usage: cylon-link-boot install TOPLEVEL P1 | confirm P1 CMDLINE_FILE" >&2
  exit 2
}

# replace_dir STAGED DEST: move the staged directory over DEST.
replace_dir() {
  rm -rf "$2.old"
  if [[ -e $2 ]]; then mv "$2" "$2.old"; fi
  mv "$1" "$2"
  rm -rf "$2.old"
}

# install_file SRC DEST MODE: copy under a temporary name, then rename.
install_file() {
  cp "$1" "$2.tmp"
  chmod "$3" "$2.tmp"
  mv "$2.tmp" "$2"
}

cmd_install() {
  local toplevel=$1 p1=$2
  local staged=$p1/nixos/new.tmp
  mkdir -p "$p1/nixos" "$p1/steamlink/factory_test" "$p1/steamlink/bin"

  rm -rf "$staged"
  mkdir "$staged"
  cp "$toplevel/kernel" "$staged/zImage"
  cp "$toplevel/initrd" "$staged/initrd"
  cp "$toplevel/dtbs/$DTB_NAME" "$staged/dtb"
  printf '%s init=%s\n' "$(cat "$toplevel/kernel-params")" "$toplevel/init" >"$staged/cmdline"
  sync
  replace_dir "$staged" "$p1/nixos/new"
  rm -f "$p1/nixos/tried-new"

  install_file "$KEXEC_MODULE" "$p1/steamlink/kexec_load.ko" 0644
  install_file "$KEXEC" "$p1/steamlink/bin/kexec" 0755
  install_file "$RUN_SH" "$p1/steamlink/factory_test/run.sh" 0755
  sync
  echo "cylon-link: staged $toplevel for the next power-on"
}

# param NAME WORD...: print the value of NAME=... among WORDs.
param() {
  local name=$1 word
  shift
  for word in "$@"; do
    if [[ $word == "$name="* ]]; then
      printf '%s\n' "${word#*=}"
      return 0
    fi
  done
  return 1
}

cmd_confirm() {
  local p1=$1 entry running_init staged_init=""
  local -a words staged_words
  read -r -a words <"$2"
  entry=$(param cylon.entry "${words[@]}" || true)
  running_init=$(param init "${words[@]}" || true)

  case $entry in
  new)
    if [[ -r $p1/nixos/new/cmdline ]]; then
      read -r -a staged_words <"$p1/nixos/new/cmdline"
      staged_init=$(param init "${staged_words[@]}" || true)
    fi
    if [[ -n $running_init && $staged_init == "$running_init" ]]; then
      rm -rf "$p1/nixos/good.tmp"
      cp -a "$p1/nixos/new" "$p1/nixos/good.tmp"
      sync
      replace_dir "$p1/nixos/good.tmp" "$p1/nixos/good"
      rm -f "$p1/nixos/tried-new" "$p1/nixos/tried-good"
      echo "cylon-link: $running_init is now the good entry"
    else
      # A switch replaced `new` after this boot; it gets its own try.
      rm -f "$p1/nixos/tried-good"
      echo "cylon-link: booted an entry that has since been replaced; not recording it"
    fi
    ;;
  good)
    rm -f "$p1/nixos/tried-good"
    echo "cylon-link: running the good entry; the failed new entry stays marked as tried"
    ;;
  *)
    echo "cylon-link: no cylon.entry on the kernel command line, nothing to confirm" >&2
    return 1
    ;;
  esac
  sync
}

case ${1:-} in
install)
  [[ $# -eq 3 ]] || usage
  cmd_install "$2" "$3"
  ;;
confirm)
  [[ $# -eq 3 ]] || usage
  cmd_confirm "$2" "$3"
  ;;
*) usage ;;
esac
