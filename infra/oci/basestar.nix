{
  resource.oci_core_instance.basestar = {
    compartment_id = "\${var.tenancy_ocid}";
    availability_domain = "Lefm:CA-MONTREAL-1-AD-1";
    display_name = "cloud";
    shape = "VM.Standard.A1.Flex";

    shape_config = [
      {
        ocpus = 4;
        memory_in_gbs = 24;
      }
    ];

    # The public IP (168.138.71.109) is ephemeral: discovery found no
    # standalone oci_core_public_ip, and a region-scoped reserved-IP listing
    # on this compartment came back empty. It lives on this VNIC via
    # assign_public_ip, not as a separate resource here. This one address is
    # also the content of five managed A records across all three
    # Cloudflare zones (the arsfeld.dev apex, niks3.arsfeld.dev,
    # seed.arsfeld.dev, mail.arsfeld.one, and the rosenfeld.one apex).
    #
    # Note the address survives a stop/start — Oracle keeps an ephemeral public
    # IP assigned across an instance stop — so the exposure is instance
    # termination or a VNIC recreate, which prevent_destroy above already
    # guards. Reserving cannot preserve this address either: Oracle does not
    # allow converting a public IP object between types, so it would mean a new
    # address and a five-record DNS cutover. See CLAUDE.md.
    create_vnic_details = [
      {
        subnet_id = "\${oci_core_subnet.main.id}";
        assign_public_ip = true;
        display_name = "dev";
        hostname_label = "dev";
      }
    ];

    source_details = [
      {
        source_type = "image";
        source_id = "ocid1.image.oc1.ca-montreal-1.aaaaaaaamhckn2kxhgaryqi57l5h4citrvfvpxfeosl2tzz4ea7kynoxuwuq";
        boot_volume_size_in_gbs = "100";
      }
    ];

    lifecycle = [
      {
        # This is the machine. A plan that would replace or destroy it should
        # fail to generate, not fail halfway through applying.
        prevent_destroy = true;

        # basestar was infected onto a stock Oracle image and has been NixOS
        # ever since; the image OCID is now pure history. Oracle retires image
        # OCIDs on its own schedule, and an unguarded source_details would read
        # that retirement as "replace the instance".
        ignore_changes = ["source_details"];
      }
    ];
  };

  # Adoption. No-op once in state; kept as the record of which real object
  # this resource adopted. No oci_core_boot_volume or oci_core_public_ip is
  # adopted alongside it: discovery found neither as a standalone resource,
  # so the boot volume stays implicit under source_details and the public IP
  # stays implicit under create_vnic_details.
  import = [
    {
      to = "oci_core_instance.basestar";
      id = "ocid1.instance.oc1.ca-montreal-1.an4xkljrw33uygicgugwkwhej57wbhzl5zmhcetikb7iafxr2zskue4kc3yq";
    }
  ];
}
