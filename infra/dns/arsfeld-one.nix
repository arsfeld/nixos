# arsfeld.one — galactica's internal zone, fronted by its cloudflared tunnel.
#
# Generated from the Cloudflare API and reviewed by hand. Records are adopted,
# not authored: this file describes what already exists.
#
# The apex (cname_arsfeld_one) points at the tunnel
# (f53e532a-...cfargotunnel.com); *.arsfeld.one chains onto the apex.
#
# Nothing here is zone-authoritative — OpenTofu only touches the 50 records
# named in this repo's config/state, so adding a hostname through the Zero
# Trust dashboard doesn't get deleted by the next apply; it just isn't
# reflected here, and this file silently stops matching the live zone. If a
# dashboard change instead touches a name that *is* managed here, the next
# apply reverts it. Add new hostnames to this file, or import them
# afterwards.
{
  resource.cloudflare_dns_record = {
    a_mail_arsfeld_one = {
      zone_id = "877dc2cb2972842c423b9c9851d95cc7";
      name = "mail.arsfeld.one";
      type = "A";
      content = "168.138.71.109";
      ttl = 1;
      proxied = false;
    };
    cname___arsfeld_one = {
      zone_id = "877dc2cb2972842c423b9c9851d95cc7";
      name = "*.arsfeld.one";
      type = "CNAME";
      content = "arsfeld.one";
      ttl = 1;
      proxied = true;
    };
    cname_arsfeld_one = {
      zone_id = "877dc2cb2972842c423b9c9851d95cc7";
      name = "arsfeld.one";
      type = "CNAME";
      content = "f53e532a-783b-4e78-a373-23dd749d1faa.cfargotunnel.com";
      ttl = 1;
      proxied = true;
    };
    mx_arsfeld_one_1 = {
      zone_id = "877dc2cb2972842c423b9c9851d95cc7";
      name = "arsfeld.one";
      type = "MX";
      content = "wednesday-relay.mxrouting.net";
      ttl = 1;
      priority = 20;
    };
    mx_arsfeld_one_2 = {
      zone_id = "877dc2cb2972842c423b9c9851d95cc7";
      name = "arsfeld.one";
      type = "MX";
      content = "wednesday.mxrouting.net";
      ttl = 1;
      priority = 10;
    };
    txt_arsfeld_one = {
      zone_id = "877dc2cb2972842c423b9c9851d95cc7";
      name = "arsfeld.one";
      type = "TXT";
      content = "v=spf1 include:mxlogin.com -all";
      ttl = 1;
    };
    txt_x__domainkey_arsfeld_one = {
      zone_id = "877dc2cb2972842c423b9c9851d95cc7";
      name = "x._domainkey.arsfeld.one";
      type = "TXT";
      content = "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAvsq0sIGNlPCnAKGLLGKnjHLKmDPNodgKV1WbqzxniVS/CHKJzuvF1vxWAzrroruf6zC6SynHuTuRWR0Lfb+2evnaS/554KG6EbM8GNWlR9Csit7d7zNvCBmXVL3mwTU9bQlrjhkRx+8ZyyzSpCWT+DOqJZPdZ5xzB0z7lj9QgTUvQcTsx7u1CbT+lKi9t75KiFYN0XeZWEHkQCtjanZCXI5ihX01CsQt4KeWchOnH5c8g+2ZpOhYIDjy3e3znnPAPrviZrMziAmwWE6+74wrS51jzirrmq/z8bIkJ0EwHYdnp+8qhCPuZ9mNshZ4gcd541Q5sT0zWEnjJhvbTbdKZQIDAQAB";
      ttl = 1;
    };
  };

  import = [
    {
      to = "cloudflare_dns_record.a_mail_arsfeld_one";
      id = "877dc2cb2972842c423b9c9851d95cc7/3544af96fccda5f60c38f7b12a5784ae";
    }
    {
      to = "cloudflare_dns_record.cname___arsfeld_one";
      id = "877dc2cb2972842c423b9c9851d95cc7/3f52238db12f174e0ad3a5e1c5fc7c10";
    }
    {
      to = "cloudflare_dns_record.cname_arsfeld_one";
      id = "877dc2cb2972842c423b9c9851d95cc7/a3346f4d63e6c1fbb8b9562ee84a8ee9";
    }
    {
      to = "cloudflare_dns_record.mx_arsfeld_one_1";
      id = "877dc2cb2972842c423b9c9851d95cc7/4e54bbeca1ca39428b152fa9a167df01";
    }
    {
      to = "cloudflare_dns_record.mx_arsfeld_one_2";
      id = "877dc2cb2972842c423b9c9851d95cc7/a9567ce56d0c92a673aab08180846109";
    }
    {
      to = "cloudflare_dns_record.txt_arsfeld_one";
      id = "877dc2cb2972842c423b9c9851d95cc7/eaf443f81b9994f61e3b38f6fe5e9538";
    }
    {
      to = "cloudflare_dns_record.txt_x__domainkey_arsfeld_one";
      id = "877dc2cb2972842c423b9c9851d95cc7/acb2d77bce226341145f8064aa6b094c";
    }
  ];
}
