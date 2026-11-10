# Flashing and monitoring the ESP32-S3 AMOLED session board (firmware/claude-board) over its
# native USB serial/JTAG port, /dev/ttyACM*, which belongs to dialout. Takes effect on the
# next login. Until then `just board` falls back to sudo.
{
  configurations.nixos.raider.module = {
    users.users.arosenfeld.extraGroups = ["dialout"];
  };
}
