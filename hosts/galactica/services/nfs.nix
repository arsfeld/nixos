# NFS exports for media files
# Used by raider to access media for AI model processing
{...}: {
  services.nfs.server = {
    enable = true;
    exports = ''
      /mnt/storage/media 100.64.0.0/10(ro,no_subtree_check,no_root_squash)
    '';
  };
}
