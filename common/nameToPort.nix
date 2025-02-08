# Generate a stable port number from a string (service name)
# Uses SHA-256 hash to generate a number between 1024-65535
name: let
  # Get SHA-256 hash of name and take first 8 chars
  hash = builtins.substring 0 6 (builtins.hashString "sha256" name);
  # Convert hex to decimal (base 16)
  decimal = (builtins.fromTOML "a = 0x${hash}").a;
  # Scale to port range (1024-65535)
  portRange = 65535 - 1024;
  # Implement modulo using division and multiplication
  remainder = decimal - (portRange * (decimal / portRange));
  port = 1024 + remainder;
in
  port
