//! The countries a Home Assistant dropdown offers for an exit slot.

use crate::api::Region;

#[derive(Debug, Clone, PartialEq)]
pub struct Offered {
    pub label: String,
    pub id: String,
    pub country: String,
}

/// Regions that are up and have a WireGuard server, labelled for a dropdown.
/// Two regions sharing a label both get their id appended, so every label is unique.
pub fn offered(regions: &[Region]) -> Vec<Offered> {
    let mut out: Vec<Offered> = regions
        .iter()
        .filter(|r| !r.offline && !r.servers.wg.is_empty())
        .map(|r| Offered {
            label: if r.geo { format!("{} (virtual)", r.name) } else { r.name.clone() },
            id: r.id.clone(),
            country: r.country.clone(),
        })
        .collect();
    let dup: Vec<String> = out
        .iter()
        .filter(|o| out.iter().filter(|p| p.label == o.label).count() > 1)
        .map(|o| o.label.clone())
        .collect();
    for o in &mut out {
        if dup.contains(&o.label) {
            o.label = format!("{} ({})", o.label, o.id);
        }
    }
    out.sort_by(|a, b| a.label.cmp(&b.label).then(a.id.cmp(&b.id)));
    out
}

/// "Off", every offered label, then each in-use id the list no longer offers, as its own label.
pub fn options(offered: &[Offered], in_use: &[&str]) -> Vec<String> {
    let mut out = vec!["Off".to_string()];
    out.extend(offered.iter().map(|o| o.label.clone()));
    for id in in_use {
        if !offered.iter().any(|o| o.id == *id) && !out.iter().any(|l| l == id) {
            out.push((*id).to_string());
        }
    }
    out
}

pub fn id_for<'a>(offered: &'a [Offered], label: &str) -> Option<&'a Offered> {
    offered.iter().find(|o| o.label == label)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::{parse_server_list, Server, Servers};

    fn fixture() -> Vec<Region> {
        parse_server_list(include_str!("../../tests/fixtures/servers-v6.txt")).unwrap()
    }

    fn region(id: &str, name: &str, geo: bool, offline: bool, wg: usize) -> Region {
        Region {
            id: id.into(),
            name: name.into(),
            country: "XX".into(),
            geo,
            offline,
            port_forward: false,
            servers: Servers {
                wg: (0..wg).map(|_| Server { ip: "1.1.1.1".into(), cn: "x".into() }).collect(),
            },
        }
    }

    fn labels(o: &[Offered]) -> Vec<&str> {
        o.iter().map(|x| x.label.as_str()).collect()
    }

    #[test]
    fn offline_and_serverless_regions_dropped() {
        let o = offered(&[
            region("up", "Up", false, false, 1),
            region("down", "Down", false, true, 1),
            region("none", "None", false, false, 0),
        ]);
        assert_eq!(labels(&o), ["Up"]);
        let o = offered(&fixture());
        assert!(o.iter().all(|x| x.id != "nowg"));
        assert!(o.iter().any(|x| x.id == "br-so"));
    }

    #[test]
    fn geo_regions_marked_virtual() {
        let o = offered(&fixture());
        let dz = o.iter().find(|x| x.id == "dz").unwrap();
        assert_eq!(dz.label, "Algeria (virtual)");
        assert_eq!(dz.country, "DZ");
        assert!(!o.iter().find(|x| x.id == "br-so").unwrap().label.ends_with("(virtual)"));
    }

    #[test]
    fn labels_sorted() {
        let o = offered(&fixture());
        let l = labels(&o);
        let mut s = l.clone();
        s.sort();
        assert_eq!(l, s);
    }

    #[test]
    fn duplicate_labels_get_ids() {
        let o = offered(&[region("b", "Same", false, false, 1), region("a", "Same", false, false, 1), region("c", "Other", false, false, 1)]);
        assert_eq!(labels(&o), ["Other", "Same (a)", "Same (b)"]);
    }

    #[test]
    fn options_start_with_off() {
        let o = offered(&fixture());
        let opts = options(&o, &[]);
        assert_eq!(opts[0], "Off");
        assert_eq!(opts.len(), o.len() + 1);
    }

    #[test]
    fn in_use_region_missing_from_list_still_offered() {
        let o = offered(&fixture());
        let opts = options(&o, &["gone", "br-so"]);
        assert_eq!(opts.iter().filter(|x| *x == "gone").count(), 1);
        assert!(!opts.iter().any(|x| x == "br-so"));
    }

    #[test]
    fn id_for_unknown_label_is_none() {
        let o = offered(&fixture());
        assert!(id_for(&o, "Nowhere").is_none());
        assert_eq!(id_for(&o, "Algeria (virtual)").unwrap().id, "dz");
    }
}
