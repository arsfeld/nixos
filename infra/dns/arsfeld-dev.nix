# arsfeld.dev — basestar's public zone.
#
# Generated from the Cloudflare API and reviewed by hand. Records are adopted,
# not authored: this file describes what already exists.
#
# The niks3 A record must stay unproxied (grey cloud). A proxied record serves
# GitHub-hosted runners a managed challenge, which silently breaks CI's push to
# the binary cache. See CLAUDE.md.
{
  resource.cloudflare_dns_record = {
    a_arsfeld_dev = {
      zone_id = "5b658a2265b2562c6f51ac93de8d21bf";
      name = "arsfeld.dev";
      type = "A";
      content = "168.138.71.109";
      ttl = 1;
      proxied = true;
    };
    a_claw_arsfeld_dev = {
      zone_id = "5b658a2265b2562c6f51ac93de8d21bf";
      name = "claw.arsfeld.dev";
      type = "A";
      content = "148.113.172.172";
      ttl = 1;
      proxied = false;
    };
    a_niks3_arsfeld_dev = {
      zone_id = "5b658a2265b2562c6f51ac93de8d21bf";
      name = "niks3.arsfeld.dev";
      type = "A";
      content = "168.138.71.109";
      ttl = 1;
      proxied = false;
      comment = "niks3 write endpoint (basestar). Must stay grey-cloud.";
    };
    a_seed_arsfeld_dev = {
      zone_id = "5b658a2265b2562c6f51ac93de8d21bf";
      name = "seed.arsfeld.dev";
      type = "A";
      content = "168.138.71.109";
      ttl = 1;
      proxied = false;
    };
    a_windmill_arsfeld_dev = {
      zone_id = "5b658a2265b2562c6f51ac93de8d21bf";
      name = "windmill.arsfeld.dev";
      type = "A";
      content = "149.56.129.39";
      ttl = 1;
      proxied = true;
    };
    aaaa_claw_arsfeld_dev = {
      zone_id = "5b658a2265b2562c6f51ac93de8d21bf";
      name = "claw.arsfeld.dev";
      type = "AAAA";
      content = "2607:5300:205:200::94a3";
      ttl = 1;
      proxied = false;
    };
    cname___arsfeld_dev = {
      zone_id = "5b658a2265b2562c6f51ac93de8d21bf";
      name = "*.arsfeld.dev";
      type = "CNAME";
      content = "arsfeld.dev";
      ttl = 1;
      proxied = true;
    };
    cname_cache_arsfeld_dev = {
      zone_id = "5b658a2265b2562c6f51ac93de8d21bf";
      name = "cache.arsfeld.dev";
      type = "CNAME";
      content = "public.r2.dev";
      ttl = 1;
      proxied = true;
    };
    cname_metadata_relay_arsfeld_dev = {
      zone_id = "5b658a2265b2562c6f51ac93de8d21bf";
      name = "metadata-relay.arsfeld.dev";
      type = "CNAME";
      content = "relay.mydia.dev";
      ttl = 1;
      proxied = true;
    };
    mx_arsfeld_dev = {
      zone_id = "5b658a2265b2562c6f51ac93de8d21bf";
      name = "arsfeld.dev";
      type = "MX";
      content = "mail.arsfeld.dev";
      ttl = 1;
      priority = 10;
    };
    # The eight _acme-challenge TXT records below (metadata-relay, sumwhere,
    # plane, windmill) are DNS-01 leftovers a client failed to clean up after
    # issuance. Adopted as found, per the import-only rule — they're safe to
    # delete out of band and drop from this file whenever someone gets around
    # to it. attic's three went with attic on 2026-09-07.
    txt__acme_challenge_metadata_relay_arsfeld_dev_1 = {
      zone_id = "5b658a2265b2562c6f51ac93de8d21bf";
      name = "_acme-challenge.metadata-relay.arsfeld.dev";
      type = "TXT";
      content = "M5jruhOzdY55zJosrZ9E4jyjOVw77V8D6bJFbZqZPKI";
      ttl = 120;
    };
    txt__acme_challenge_metadata_relay_arsfeld_dev_2 = {
      zone_id = "5b658a2265b2562c6f51ac93de8d21bf";
      name = "_acme-challenge.metadata-relay.arsfeld.dev";
      type = "TXT";
      content = "QC2jVowT8QcYNEz3aLokcWr_ADFj8TFkaQsyqCVBQGg";
      ttl = 120;
    };
    txt__acme_challenge_metadata_relay_arsfeld_dev_3 = {
      zone_id = "5b658a2265b2562c6f51ac93de8d21bf";
      name = "_acme-challenge.metadata-relay.arsfeld.dev";
      type = "TXT";
      content = "nkBYFKDY5CrXMCLJ_Pk71Q__k3skngMxvHhLpWelEcU";
      ttl = 120;
    };
    txt__acme_challenge_metadata_relay_arsfeld_dev_4 = {
      zone_id = "5b658a2265b2562c6f51ac93de8d21bf";
      name = "_acme-challenge.metadata-relay.arsfeld.dev";
      type = "TXT";
      content = "pQ8Kc65d3eDyr7MPSD4Hz1P_EV7ymP0Y0h0ulTEXsx8";
      ttl = 120;
    };
    txt__acme_challenge_plane_arsfeld_dev = {
      zone_id = "5b658a2265b2562c6f51ac93de8d21bf";
      name = "_acme-challenge.plane.arsfeld.dev";
      type = "TXT";
      content = "NlX1WpULZHJOBTWDH1ZYhqk4q8Ss815q1KLe7bYoD3g";
      ttl = 120;
    };
    txt__acme_challenge_sumwhere_arsfeld_dev_1 = {
      zone_id = "5b658a2265b2562c6f51ac93de8d21bf";
      name = "_acme-challenge.sumwhere.arsfeld.dev";
      type = "TXT";
      content = "7hhGBF6OpS2AgbUqZN1s_RalSczLvKAaFnqjflzRr34";
      ttl = 120;
    };
    txt__acme_challenge_sumwhere_arsfeld_dev_2 = {
      zone_id = "5b658a2265b2562c6f51ac93de8d21bf";
      name = "_acme-challenge.sumwhere.arsfeld.dev";
      type = "TXT";
      content = "Ikwg6NuHTdNhfyRkENHmkT_Wy44hE23r41RHjh_75T8";
      ttl = 120;
    };
    txt__acme_challenge_windmill_arsfeld_dev = {
      zone_id = "5b658a2265b2562c6f51ac93de8d21bf";
      name = "_acme-challenge.windmill.arsfeld.dev";
      type = "TXT";
      content = "rTRH3LKK2WMWD-IOC_Y745eZ9tRloN0B7BVXwSwIorM";
      ttl = 120;
    };
    txt_arsfeld_dev = {
      zone_id = "5b658a2265b2562c6f51ac93de8d21bf";
      name = "arsfeld.dev";
      type = "TXT";
      content = "v=spf1 a:mail.arsfeld.dev -all";
      ttl = 1;
    };
  };

  import = [
    {
      to = "cloudflare_dns_record.a_arsfeld_dev";
      id = "5b658a2265b2562c6f51ac93de8d21bf/947c7a170e2cf0c015f87b717b1b67fc";
    }
    {
      to = "cloudflare_dns_record.a_claw_arsfeld_dev";
      id = "5b658a2265b2562c6f51ac93de8d21bf/eeb759197692e8862c98e86b6ba9a841";
    }
    {
      to = "cloudflare_dns_record.a_niks3_arsfeld_dev";
      id = "5b658a2265b2562c6f51ac93de8d21bf/83435fe1559b0afa33a28dfa66d57b65";
    }
    {
      to = "cloudflare_dns_record.a_seed_arsfeld_dev";
      id = "5b658a2265b2562c6f51ac93de8d21bf/681307dfa36fe57ef01ef68d4a5605b2";
    }
    {
      to = "cloudflare_dns_record.a_windmill_arsfeld_dev";
      id = "5b658a2265b2562c6f51ac93de8d21bf/91d1064a39487e1050f292a2f1f92050";
    }
    {
      to = "cloudflare_dns_record.aaaa_claw_arsfeld_dev";
      id = "5b658a2265b2562c6f51ac93de8d21bf/61b4414494fa0dec096c00bef3f37ff6";
    }
    {
      to = "cloudflare_dns_record.cname___arsfeld_dev";
      id = "5b658a2265b2562c6f51ac93de8d21bf/0fb94d59fb8fa1ea411eae969fc62604";
    }
    {
      to = "cloudflare_dns_record.cname_cache_arsfeld_dev";
      id = "5b658a2265b2562c6f51ac93de8d21bf/17a377d5ee55e41236c3607695d709f5";
    }
    {
      to = "cloudflare_dns_record.cname_metadata_relay_arsfeld_dev";
      id = "5b658a2265b2562c6f51ac93de8d21bf/857637b4358a6c678b8ba43dc890fe23";
    }
    {
      to = "cloudflare_dns_record.mx_arsfeld_dev";
      id = "5b658a2265b2562c6f51ac93de8d21bf/53dfb8c77ba9ffcdc1afcdfa92e1ac0b";
    }
    {
      to = "cloudflare_dns_record.txt__acme_challenge_metadata_relay_arsfeld_dev_1";
      id = "5b658a2265b2562c6f51ac93de8d21bf/a0d0b8114f6d661c908638c5d49c6e1c";
    }
    {
      to = "cloudflare_dns_record.txt__acme_challenge_metadata_relay_arsfeld_dev_2";
      id = "5b658a2265b2562c6f51ac93de8d21bf/d009d94c629532e659dc98ba8835599e";
    }
    {
      to = "cloudflare_dns_record.txt__acme_challenge_metadata_relay_arsfeld_dev_3";
      id = "5b658a2265b2562c6f51ac93de8d21bf/7f072066af51866909d04ecfc58093ba";
    }
    {
      to = "cloudflare_dns_record.txt__acme_challenge_metadata_relay_arsfeld_dev_4";
      id = "5b658a2265b2562c6f51ac93de8d21bf/5bce52d6dc30f50f6e6b85585636ac5f";
    }
    {
      to = "cloudflare_dns_record.txt__acme_challenge_plane_arsfeld_dev";
      id = "5b658a2265b2562c6f51ac93de8d21bf/dc9bbc8e55cbb76f37bdc55a3617871c";
    }
    {
      to = "cloudflare_dns_record.txt__acme_challenge_sumwhere_arsfeld_dev_1";
      id = "5b658a2265b2562c6f51ac93de8d21bf/733f682927f992779a6b498b69ab2b7a";
    }
    {
      to = "cloudflare_dns_record.txt__acme_challenge_sumwhere_arsfeld_dev_2";
      id = "5b658a2265b2562c6f51ac93de8d21bf/5be59f9ddb57697249e99ea1ae61d69c";
    }
    {
      to = "cloudflare_dns_record.txt__acme_challenge_windmill_arsfeld_dev";
      id = "5b658a2265b2562c6f51ac93de8d21bf/6e577d67c1f0cea5ca694673b1610880";
    }
    {
      to = "cloudflare_dns_record.txt_arsfeld_dev";
      id = "5b658a2265b2562c6f51ac93de8d21bf/15ee0f5d4586a5a165260af1ee5b24da";
    }
  ];
}
