{
  resource = {
    oci_core_vcn.main = {
      compartment_id = "\${var.tenancy_ocid}";
      cidr_blocks = ["10.0.0.0/16"];
      display_name = "vcn-20211201-1436";
      dns_label = "vcn12011447";
      # basestar's entire network path hangs off this VCN.
      lifecycle = [{prevent_destroy = true;}];
    };

    oci_core_internet_gateway.main = {
      compartment_id = "\${var.tenancy_ocid}";
      vcn_id = "\${oci_core_vcn.main.id}";
      display_name = "Internet Gateway vcn-20211201-1436";
      enabled = true;
    };

    # Discovery shows this VCN's route table is the VCN-default one (created
    # implicitly alongside the VCN, never a standalone oci_core_route_table),
    # so it is adopted with the resource type OCI's provider reserves for
    # that: oci_core_default_route_table, keyed by manage_default_resource_id
    # rather than vcn_id.
    oci_core_default_route_table.main = {
      compartment_id = "\${var.tenancy_ocid}";
      manage_default_resource_id = "\${oci_core_vcn.main.default_route_table_id}";
      display_name = "Default Route Table for vcn-20211201-1436";
      route_rules = [
        {
          destination = "0.0.0.0/0";
          destination_type = "CIDR_BLOCK";
          network_entity_id = "\${oci_core_internet_gateway.main.id}";
          route_type = "STATIC";
        }
        {
          destination = "::/0";
          destination_type = "CIDR_BLOCK";
          network_entity_id = "\${oci_core_internet_gateway.main.id}";
          route_type = "STATIC";
        }
      ];
    };

    # This is the firewall CLAUDE.md refers to as "the upstream OCI/cloud
    # firewall". The host firewall's base allowlist is 22/80/443; this list is
    # what actually decides what reaches basestar from the internet.
    #
    # Like the route table above, discovery shows this is the VCN-default
    # security list, so it is adopted as oci_core_default_security_list
    # (manage_default_resource_id) rather than a standalone
    # oci_core_security_list.
    #
    # Rules below are transcribed verbatim from resource discovery, in
    # discovery's order. Do not reorder, dedupe, or "clean up" — several
    # entries duplicate each other or look redundant, but rule order and
    # content here is a permanent record of live infrastructure, not a
    # designed policy.
    oci_core_default_security_list.main = {
      compartment_id = "\${var.tenancy_ocid}";
      manage_default_resource_id = "\${oci_core_vcn.main.default_security_list_id}";
      display_name = "Default Security List for vcn-20211201-1436";
      egress_security_rules = [
        {
          destination = "0.0.0.0/0";
          destination_type = "CIDR_BLOCK";
          protocol = "all";
          stateless = false;
        }
        {
          destination = "::/0";
          destination_type = "CIDR_BLOCK";
          protocol = "all";
          stateless = false;
        }
      ];
      ingress_security_rules = [
        {
          # SSH
          source = "0.0.0.0/0";
          source_type = "CIDR_BLOCK";
          protocol = "6"; # TCP
          stateless = false;
          tcp_options = [
            {
              min = 22;
              max = 22;
            }
          ];
        }
        {
          # Path MTU discovery (fragmentation needed)
          source = "0.0.0.0/0";
          source_type = "CIDR_BLOCK";
          protocol = "1"; # ICMP
          stateless = false;
          icmp_options = [
            {
              type = 3;
              code = 4;
            }
          ];
        }
        {
          # Destination unreachable, within the VCN
          source = "10.0.0.0/16";
          source_type = "CIDR_BLOCK";
          protocol = "1"; # ICMP
          stateless = false;
          icmp_options = [
            {
              type = 3;
              code = -1;
            }
          ];
        }
        {
          description = "HTTP, HTTPS";
          source = "0.0.0.0/0";
          source_type = "CIDR_BLOCK";
          protocol = "6"; # TCP
          stateless = false;
          tcp_options = [
            {
              min = 80;
              max = 80;
            }
          ];
        }
        {
          description = "HTTP, HTTPS";
          source = "0.0.0.0/0";
          source_type = "CIDR_BLOCK";
          protocol = "6"; # TCP
          stateless = false;
          tcp_options = [
            {
              min = 443;
              max = 443;
            }
          ];
        }
        {
          source = "0.0.0.0/0";
          source_type = "CIDR_BLOCK";
          protocol = "17"; # UDP
          stateless = false;
          udp_options = [
            {
              min = 4242;
              max = 4242;
            }
          ];
        }
        {
          source = "0.0.0.0/0";
          source_type = "CIDR_BLOCK";
          protocol = "17"; # UDP
          stateless = false;
          udp_options = [
            {
              min = 51821;
              max = 51830;
            }
          ];
        }
        {
          source = "100.64.0.0/10";
          source_type = "CIDR_BLOCK";
          protocol = "6"; # TCP
          stateless = false;
          tcp_options = [
            {
              min = 53;
              max = 53;
            }
          ];
        }
        {
          source = "0.0.0.0/0";
          source_type = "CIDR_BLOCK";
          protocol = "6"; # TCP
          stateless = false;
          tcp_options = [
            {
              min = 8883;
              max = 8883;
            }
          ];
        }
        {
          # Duplicate of the 51821-51830/udp rule above, as discovered.
          source = "0.0.0.0/0";
          source_type = "CIDR_BLOCK";
          protocol = "17"; # UDP
          stateless = false;
          udp_options = [
            {
              min = 51821;
              max = 51830;
            }
          ];
        }
        {
          # Plex
          source = "0.0.0.0/0";
          source_type = "CIDR_BLOCK";
          protocol = "6"; # TCP
          stateless = false;
          tcp_options = [
            {
              min = 32400;
              max = 32400;
            }
          ];
        }
        {
          source = "0.0.0.0/0";
          source_type = "CIDR_BLOCK";
          protocol = "6"; # TCP
          stateless = false;
          tcp_options = [
            {
              min = 58243;
              max = 58243;
            }
          ];
        }
        {
          source = "0.0.0.0/0";
          source_type = "CIDR_BLOCK";
          protocol = "17"; # UDP
          stateless = false;
          udp_options = [
            {
              min = 58243;
              max = 58243;
            }
          ];
        }
        {
          description = "Ingress to allow all IPv6 traffic";
          source = "::/0";
          source_type = "CIDR_BLOCK";
          protocol = "all";
          stateless = false;
        }
        {
          description = "DNS UDP";
          source = "100.64.0.0/10";
          source_type = "CIDR_BLOCK";
          protocol = "17"; # UDP
          stateless = false;
          udp_options = [
            {
              min = 53;
              max = 53;
            }
          ];
        }
        {
          source = "0.0.0.0/0";
          source_type = "CIDR_BLOCK";
          protocol = "17"; # UDP
          stateless = false;
          udp_options = [
            {
              min = 53;
              max = 53;
            }
          ];
        }
        {
          description = "SMTP";
          source = "0.0.0.0/0";
          source_type = "CIDR_BLOCK";
          protocol = "6"; # TCP
          stateless = false;
          tcp_options = [
            {
              min = 465;
              max = 465;
            }
          ];
        }
        {
          description = "IMAP";
          source = "0.0.0.0/0";
          source_type = "CIDR_BLOCK";
          protocol = "6"; # TCP
          stateless = false;
          tcp_options = [
            {
              min = 993;
              max = 993;
            }
          ];
        }
        {
          description = "IMAP (no TLS)";
          source = "0.0.0.0/0";
          source_type = "CIDR_BLOCK";
          protocol = "6"; # TCP
          stateless = false;
          tcp_options = [
            {
              min = 143;
              max = 143;
            }
          ];
        }
        {
          description = "SMTP (no TLS)";
          source = "0.0.0.0/0";
          source_type = "CIDR_BLOCK";
          protocol = "6"; # TCP
          stateless = false;
          tcp_options = [
            {
              min = 25;
              max = 25;
            }
          ];
        }
        {
          description = "Mail Submission";
          source = "0.0.0.0/0";
          source_type = "CIDR_BLOCK";
          protocol = "6"; # TCP
          stateless = false;
          tcp_options = [
            {
              min = 587;
              max = 587;
            }
          ];
        }
        {
          description = "rustdesk";
          source = "0.0.0.0/0";
          source_type = "CIDR_BLOCK";
          protocol = "6"; # TCP
          stateless = false;
          tcp_options = [
            {
              min = 21114;
              max = 21119;
            }
          ];
        }
        {
          description = "rustdesk";
          source = "0.0.0.0/0";
          source_type = "CIDR_BLOCK";
          protocol = "17"; # UDP
          stateless = false;
          udp_options = [
            {
              min = 21116;
              max = 21116;
            }
          ];
        }
        {
          description = "Radicle";
          source = "0.0.0.0/0";
          source_type = "CIDR_BLOCK";
          protocol = "6"; # TCP
          stateless = false;
          tcp_options = [
            {
              min = 8776;
              max = 8776;
            }
          ];
        }
        {
          description = "Radicle";
          source = "::/0";
          source_type = "CIDR_BLOCK";
          protocol = "6"; # TCP
          stateless = false;
          tcp_options = [
            {
              min = 8776;
              max = 8776;
            }
          ];
        }
      ];
    };

    oci_core_subnet.main = {
      compartment_id = "\${var.tenancy_ocid}";
      vcn_id = "\${oci_core_vcn.main.id}";
      cidr_block = "10.0.0.0/24";
      display_name = "subnet-20211201-1436";
      dns_label = "subnet12011447";
      route_table_id = "\${oci_core_default_route_table.main.id}";
      security_list_ids = ["\${oci_core_default_security_list.main.id}"];
      lifecycle = [{prevent_destroy = true;}];
    };
  };

  # Adoption. These blocks are no-ops once the resources are in state; they are
  # kept as the record of which real object each resource adopted, and they make
  # rebuilding state from scratch a `tofu apply` rather than an archaeology
  # exercise.
  #
  # Note: the VCN's default DHCP options set (Default DHCP Options for
  # vcn-20211201-1436, ocid1.dhcpoptions.oc1.ca-montreal-1...qzc3w7qeaq) is not
  # adopted here. It isn't in this task's scope (see task-3-report.md) and the
  # subnet's dhcp_options_id is optional+computed, so leaving it unmanaged
  # produces no plan diff.
  import = [
    {
      to = "oci_core_vcn.main";
      id = "ocid1.vcn.oc1.ca-montreal-1.amaaaaaaw33uygia2tq3m3ioiykenjnsn6nzqeockxs4gg3bpxdtxa56t5aq";
    }
    {
      to = "oci_core_internet_gateway.main";
      id = "ocid1.internetgateway.oc1.ca-montreal-1.aaaaaaaayuq35o6a2juuy7ynmmkwkc2ynbs2wf5iwamkhl2dtpjfqyu5erzq";
    }
    {
      to = "oci_core_default_route_table.main";
      id = "ocid1.routetable.oc1.ca-montreal-1.aaaaaaaa6cfmjusdwvbenq2kwy62nbxfwxjcxmtco7zmiyk3grznwlskrvca";
    }
    {
      to = "oci_core_default_security_list.main";
      id = "ocid1.securitylist.oc1.ca-montreal-1.aaaaaaaa2rv2i5r5zlw6zijep6paxs5wuxe4d26bxrgehtdnyxn7tza5sz5q";
    }
    {
      to = "oci_core_subnet.main";
      id = "ocid1.subnet.oc1.ca-montreal-1.aaaaaaaakpzqy7n3wbldgkbliwmwutjkbmt6lqlz77pd5nedcedbjfehbsfq";
    }
  ];
}
