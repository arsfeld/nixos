# rosenfeld.one — the zone behind constellation.sites.rosenfeld-one.
#
# Generated from the Cloudflare API and reviewed by hand. Records are adopted,
# not authored: this file describes what already exists.
{
  resource.cloudflare_dns_record = {
    a_rosenfeld_one = {
      zone_id = "1c77692238095c6a5a263ab71c301ed8";
      name = "rosenfeld.one";
      type = "A";
      content = "168.138.71.109";
      ttl = 1;
      proxied = false;
    };
    cname___rosenfeld_one = {
      zone_id = "1c77692238095c6a5a263ab71c301ed8";
      name = "*.rosenfeld.one";
      type = "CNAME";
      content = "rosenfeld.one";
      ttl = 1;
      proxied = false;
    };
    cname__dmarc_rosenfeld_one = {
      zone_id = "1c77692238095c6a5a263ab71c301ed8";
      name = "_dmarc.rosenfeld.one";
      type = "CNAME";
      content = "dmarcroot.purelymail.com";
      ttl = 1;
      proxied = false;
    };
    cname_brcrytaxi5uu222vrqjgx36o5amkf3sx__domainkey_rosenfeld_one = {
      zone_id = "1c77692238095c6a5a263ab71c301ed8";
      name = "brcrytaxi5uu222vrqjgx36o5amkf3sx._domainkey.rosenfeld.one";
      type = "CNAME";
      content = "brcrytaxi5uu222vrqjgx36o5amkf3sx.dkim.amazonses.com";
      ttl = 1;
      proxied = false;
    };
    cname_ewfhgcs6p4wxmjha5ahwd7fy6v2r24ik__domainkey_rosenfeld_one = {
      zone_id = "1c77692238095c6a5a263ab71c301ed8";
      name = "ewfhgcs6p4wxmjha5ahwd7fy6v2r24ik._domainkey.rosenfeld.one";
      type = "CNAME";
      content = "ewfhgcs6p4wxmjha5ahwd7fy6v2r24ik.dkim.amazonses.com";
      ttl = 1;
      proxied = false;
    };
    cname_nl53bj3zjuhinf4mrpckbo7zm7exscj7__domainkey_rosenfeld_one = {
      zone_id = "1c77692238095c6a5a263ab71c301ed8";
      name = "nl53bj3zjuhinf4mrpckbo7zm7exscj7._domainkey.rosenfeld.one";
      type = "CNAME";
      content = "nl53bj3zjuhinf4mrpckbo7zm7exscj7.dkim.amazonses.com";
      ttl = 1;
      proxied = false;
    };
    cname_purelymail1__domainkey_rosenfeld_one = {
      zone_id = "1c77692238095c6a5a263ab71c301ed8";
      name = "purelymail1._domainkey.rosenfeld.one";
      type = "CNAME";
      content = "key1.dkimroot.purelymail.com";
      ttl = 1;
      proxied = false;
    };
    cname_purelymail2__domainkey_rosenfeld_one = {
      zone_id = "1c77692238095c6a5a263ab71c301ed8";
      name = "purelymail2._domainkey.rosenfeld.one";
      type = "CNAME";
      content = "key2.dkimroot.purelymail.com";
      ttl = 1;
      proxied = false;
    };
    cname_purelymail3__domainkey_rosenfeld_one = {
      zone_id = "1c77692238095c6a5a263ab71c301ed8";
      name = "purelymail3._domainkey.rosenfeld.one";
      type = "CNAME";
      content = "key3.dkimroot.purelymail.com";
      ttl = 1;
      proxied = false;
    };
    cname_www_rosenfeld_one = {
      zone_id = "1c77692238095c6a5a263ab71c301ed8";
      name = "www.rosenfeld.one";
      type = "CNAME";
      content = "rosenfeld.one";
      ttl = 1;
      proxied = false;
    };
    mx_mail_rosenfeld_one = {
      zone_id = "1c77692238095c6a5a263ab71c301ed8";
      name = "mail.rosenfeld.one";
      type = "MX";
      content = "feedback-smtp.ca-central-1.amazonses.com";
      ttl = 1;
      priority = 10;
    };
    mx_rosenfeld_one = {
      zone_id = "1c77692238095c6a5a263ab71c301ed8";
      name = "rosenfeld.one";
      type = "MX";
      content = "mailserver.purelymail.com";
      ttl = 1;
      priority = 10;
    };
    mx_send_rosenfeld_one = {
      zone_id = "1c77692238095c6a5a263ab71c301ed8";
      name = "send.rosenfeld.one";
      type = "MX";
      content = "feedback-smtp.us-east-1.amazonses.com";
      ttl = 3600;
      priority = 10;
    };
    txt_cf2024_1__domainkey_rosenfeld_one = {
      zone_id = "1c77692238095c6a5a263ab71c301ed8";
      name = "cf2024-1._domainkey.rosenfeld.one";
      type = "TXT";
      content = "\"v=DKIM1; h=sha256; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAiweykoi+o48IOGuP7GR3X0MOExCUDY/BCRHoWBnh3rChl7WhdyCxW3jgq1daEjPPqoi7sJvdg5hEQVsgVRQP4DcnQDVjGMbASQtrY4WmB1VebF+RPJB2ECPsEDTpeiI5ZyUAwJaVX7r6bznU67g7LvFq35yIo4sdlmtZGV+i0H4cpYH9+3JJ78k\" \"m4KXwaf9xUJCWF6nxeD+qG6Fyruw1Qlbds2r85U9dkNDVAS3gioCvELryh1TxKGiVTkg4wqHTyHfWsp7KD3WQHYJn0RyfJJu6YEmL77zonn7p2SRMvTMP3ZEXibnC9gz3nnhR6wcYL8Q7zXypKTMD58bTixDSJwIDAQAB\"";
      ttl = 1;
    };
    txt_mail_rosenfeld_one = {
      zone_id = "1c77692238095c6a5a263ab71c301ed8";
      name = "mail.rosenfeld.one";
      type = "TXT";
      content = "\"v=spf1 include:amazonses.com ~all\"";
      ttl = 1;
    };
    txt_resend__domainkey_rosenfeld_one = {
      zone_id = "1c77692238095c6a5a263ab71c301ed8";
      name = "resend._domainkey.rosenfeld.one";
      type = "TXT";
      content = "\"p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDAgJPEsoGTv+TcDpfdH0JrVGa0wt0LxWeL4cjQ1SVuDpUvtnGEfNDOvOrSA7iatiR7EYRsgStwzsS90UhCluBbeT4fqu20+PQsol0tQbC1UbAq6dhRjAmG8DrzbMeoiZhkeNEZftt84XlHkVvj+zDvPxD4SVoxKqXVu1Yty3IoBwIDAQAB\"";
      ttl = 3600;
    };
    txt_rosenfeld_one_1 = {
      zone_id = "1c77692238095c6a5a263ab71c301ed8";
      name = "rosenfeld.one";
      type = "TXT";
      content = "\"apple-domain=AX6vH5Q5qJNTfS8C\"";
      ttl = 1;
    };
    txt_rosenfeld_one_2 = {
      zone_id = "1c77692238095c6a5a263ab71c301ed8";
      name = "rosenfeld.one";
      type = "TXT";
      content = "purelymail_ownership_proof=e7e52cc035c4d6071b2c6e42f994ec6fa737e10aa5647a765f75c3d947826ea1debf842ea5a4595c3d15d4d469ebfa5528341c9511254ee15c2c6fc5c01185e8";
      ttl = 1;
    };
    txt_rosenfeld_one_3 = {
      zone_id = "1c77692238095c6a5a263ab71c301ed8";
      name = "rosenfeld.one";
      type = "TXT";
      content = "v=spf1 include:_spf.purelymail.com ~all";
      ttl = 1;
    };
    txt_send_rosenfeld_one = {
      zone_id = "1c77692238095c6a5a263ab71c301ed8";
      name = "send.rosenfeld.one";
      type = "TXT";
      content = "\"v=spf1 include:amazonses.com -all\"";
      ttl = 3600;
    };
  };

  import = [
    {
      to = "cloudflare_dns_record.a_rosenfeld_one";
      id = "1c77692238095c6a5a263ab71c301ed8/b159f46096ac701a7dbec4d3dd413995";
    }
    {
      to = "cloudflare_dns_record.cname___rosenfeld_one";
      id = "1c77692238095c6a5a263ab71c301ed8/0bde135746440107b708274183f78553";
    }
    {
      to = "cloudflare_dns_record.cname__dmarc_rosenfeld_one";
      id = "1c77692238095c6a5a263ab71c301ed8/13c0b5559ec692e2c4c5461dfe083a1b";
    }
    {
      to = "cloudflare_dns_record.cname_brcrytaxi5uu222vrqjgx36o5amkf3sx__domainkey_rosenfeld_one";
      id = "1c77692238095c6a5a263ab71c301ed8/8b6bd006accadffb2c7ba61b7f8b02ac";
    }
    {
      to = "cloudflare_dns_record.cname_ewfhgcs6p4wxmjha5ahwd7fy6v2r24ik__domainkey_rosenfeld_one";
      id = "1c77692238095c6a5a263ab71c301ed8/01a7a17e3b7c6ad1e54a714fd710b6e4";
    }
    {
      to = "cloudflare_dns_record.cname_nl53bj3zjuhinf4mrpckbo7zm7exscj7__domainkey_rosenfeld_one";
      id = "1c77692238095c6a5a263ab71c301ed8/4896d1fecf138e5a6a81c1fd85325fed";
    }
    {
      to = "cloudflare_dns_record.cname_purelymail1__domainkey_rosenfeld_one";
      id = "1c77692238095c6a5a263ab71c301ed8/0ed8b4fc2ed191b952b0f71cfbf7fa61";
    }
    {
      to = "cloudflare_dns_record.cname_purelymail2__domainkey_rosenfeld_one";
      id = "1c77692238095c6a5a263ab71c301ed8/cdeb19fd25a0db7f9f9385532c7b260c";
    }
    {
      to = "cloudflare_dns_record.cname_purelymail3__domainkey_rosenfeld_one";
      id = "1c77692238095c6a5a263ab71c301ed8/2c279eb8098f040b1ced04d86513d0da";
    }
    {
      to = "cloudflare_dns_record.cname_www_rosenfeld_one";
      id = "1c77692238095c6a5a263ab71c301ed8/186c031a45a5b92163f75975ffcf6b47";
    }
    {
      to = "cloudflare_dns_record.mx_mail_rosenfeld_one";
      id = "1c77692238095c6a5a263ab71c301ed8/a3c3ff04b0a713a2fb1b584f719250aa";
    }
    {
      to = "cloudflare_dns_record.mx_rosenfeld_one";
      id = "1c77692238095c6a5a263ab71c301ed8/c0fcaf7af03ee8dbb21bcc4cd9ee861a";
    }
    {
      to = "cloudflare_dns_record.mx_send_rosenfeld_one";
      id = "1c77692238095c6a5a263ab71c301ed8/5884ef0ea40a14a805a9e50b455e7a9a";
    }
    {
      to = "cloudflare_dns_record.txt_cf2024_1__domainkey_rosenfeld_one";
      id = "1c77692238095c6a5a263ab71c301ed8/a7e3b62c67a176177499f84ef2775dc3";
    }
    {
      to = "cloudflare_dns_record.txt_mail_rosenfeld_one";
      id = "1c77692238095c6a5a263ab71c301ed8/4ea68a2c41091e81006ccc2149e5b039";
    }
    {
      to = "cloudflare_dns_record.txt_resend__domainkey_rosenfeld_one";
      id = "1c77692238095c6a5a263ab71c301ed8/ad72dbca1e9161532e37f7aea16f0a96";
    }
    {
      to = "cloudflare_dns_record.txt_rosenfeld_one_1";
      id = "1c77692238095c6a5a263ab71c301ed8/ef5719c90d27e708b457e6b78b272131";
    }
    {
      to = "cloudflare_dns_record.txt_rosenfeld_one_2";
      id = "1c77692238095c6a5a263ab71c301ed8/67b7d2756aa6abd76a302bf981626f75";
    }
    {
      to = "cloudflare_dns_record.txt_rosenfeld_one_3";
      id = "1c77692238095c6a5a263ab71c301ed8/df8c957ea3f57528a53734ae275f83b3";
    }
    {
      to = "cloudflare_dns_record.txt_send_rosenfeld_one";
      id = "1c77692238095c6a5a263ab71c301ed8/ac5392fcf512ce061339f11cf90822c6";
    }
  ];
}
