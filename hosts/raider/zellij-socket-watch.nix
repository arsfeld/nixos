# Diagnostic: log every unlink or rename under a zellij socket directory, with
# the pid and parent that did it.
#
# On 2026-10-02 a live `main` server lost its socket file and a second server
# took the name (see zellijGuard in home/home.nix). zellij logs nothing on that
# path, so what removed the socket could not be established afterwards. Read
# the answer with `journalctl -u zellij-socket-watch`, and delete this file
# once it is known.
#
# It matches on the path string the syscall was given, so an unlinkat relative
# to a directory fd is not seen. zellij itself always passes absolute paths.
{pkgs, ...}: let
  script = pkgs.writeText "zellij-socket-watch.bt" ''
    tracepoint:syscalls:sys_enter_unlink,
    tracepoint:syscalls:sys_enter_unlinkat
    /strcontains(str(args.pathname), "/zellij/contract_version_")/
    {
      printf("%s %s pid=%d comm=%s uid=%d ppid=%d pcomm=%s\n",
        probe, str(args.pathname), pid, comm, uid,
        curtask->real_parent->tgid, curtask->real_parent->comm);
    }

    tracepoint:syscalls:sys_enter_rename,
    tracepoint:syscalls:sys_enter_renameat,
    tracepoint:syscalls:sys_enter_renameat2
    /strcontains(str(args.oldname), "/zellij/contract_version_")/
    {
      printf("%s %s pid=%d comm=%s uid=%d ppid=%d pcomm=%s\n",
        probe, str(args.oldname), pid, comm, uid,
        curtask->real_parent->tgid, curtask->real_parent->comm);
    }
  '';
in {
  systemd.services.zellij-socket-watch = {
    description = "Log unlinks and renames of zellij session sockets";
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      ExecStart = "${pkgs.bpftrace}/bin/bpftrace ${script}";
      Restart = "on-failure";
      RestartSec = 30;
    };
  };
}
