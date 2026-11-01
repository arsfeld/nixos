Per-host enabled features at the start of the dendritic restructure, from `scripts/dendritic/enabled.nix`; drives which hosts import each feature.

```
feature                   basest blackb cylon- galact octopi pegasu r2s    raider raspi3 router
@blocky                   .      .      .      .      .      .      .      .      .      .
@caddy                    Y      .      .      Y      .      Y      .      .      .      Y
@check-stock              .      .      .      Y      .      .      .      .      .      .
@cloudflared              .      .      .      Y      .      Y      .      .      .      .
@gamemode                 .      Y      .      .      .      .      .      Y      .      .
@media.gateway.services   2      0      0      56     0      6      0      0      0      0
@media.services           2      0      0      66     0      7      0      0      0      0
@pantheon                 .      Y      .      .      .      .      .      Y      .      .
@tsnsrv                   Y      .      .      Y      Y      Y      .      Y      Y      .
@tsnsrv-sidecars          .      .      .      .      .      .      .      .      .      .
backrest                  Y      .      .      Y      .      Y      .      Y      .      .
backupNotify              Y      .      .      Y      .      Y      .      Y      .      .
backupStatus              Y      .      .      Y      .      Y      .      Y      .      .
backupSummary             .      .      .      Y      .      .      .      .      .      .
common                    Y      Y      Y      Y      Y      Y      Y      Y      Y      Y
desktop                   .      Y      .      .      .      .      .      Y      .      .
development               .      Y      .      Y      .      .      .      Y      .      .
email                     Y      Y      Y      Y      Y      Y      Y      Y      Y      Y
forgejo-runner            .      .      .      Y      .      .      .      .      .      .
gaming                    .      Y      .      .      .      .      .      Y      .      .
mediaSync                 -      -      -      -      -      .      -      -      -      -
netdataClient             Y      Y      .      .      Y      Y      Y      Y      Y      .
podman                    Y      .      .      Y      .      Y      .      .      .      Y
sops                      Y      Y      Y      Y      Y      Y      Y      Y      Y      Y
users                     Y      Y      Y      Y      Y      Y      Y      Y      Y      Y
virtualization            Y      Y      .      Y      Y      Y      Y      Y      Y      .
vpnExitNodes              -      -      -      .      -      -      -      -      -      -
```
