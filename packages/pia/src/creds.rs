//! The PIA credentials env file (`PIA_USER`, `PIA_PASS`).

use anyhow::{Result, bail};

pub struct Credentials {
    pub user: String,
    pub pass: String,
}

/// Parses the env file: blank lines and `#` comments skipped, optional `export `,
/// surrounding quote characters stripped. Split on the first `=` only.
pub fn parse(text: &str) -> Result<Credentials> {
    let (mut user, mut pass) = (None, None);
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let line = line.strip_prefix("export ").unwrap_or(line);
        let Some((key, val)) = line.split_once('=') else {
            continue;
        };
        // Exactly the Python's `.strip().strip('"').strip("'")`.
        let val = val.trim().trim_matches('"').trim_matches('\'').to_string();
        match key.trim() {
            "PIA_USER" => user = Some(val),
            "PIA_PASS" => pass = Some(val),
            _ => {}
        }
    }
    let Some(user) = user.filter(|v| !v.is_empty()) else {
        bail!("missing PIA_USER in credentials file");
    };
    let Some(pass) = pass.filter(|v| !v.is_empty()) else {
        bail!("missing PIA_PASS in credentials file");
    };
    Ok(Credentials { user, pass })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_pairs() {
        let c = parse("PIA_USER=p123\nPIA_PASS=secret\n").unwrap();
        assert_eq!((c.user.as_str(), c.pass.as_str()), ("p123", "secret"));
    }

    #[test]
    fn export_quotes_and_comments() {
        let c = parse("# x\n\nexport PIA_USER=\"p123\"\nexport PIA_PASS='s e'\n").unwrap();
        assert_eq!(c.pass, "s e");
        assert_eq!(c.user, "p123");
    }

    #[test]
    fn unbalanced_quotes_strip_like_python() {
        assert_eq!(parse("PIA_USER=u\nPIA_PASS=\"abc\n").unwrap().pass, "abc");
        assert_eq!(parse("PIA_USER=u\nPIA_PASS=abc'\n").unwrap().pass, "abc");
        assert_eq!(parse("PIA_USER=u\nPIA_PASS=\"a'\"\n").unwrap().pass, "a");
    }

    #[test]
    fn password_with_equals_and_hash() {
        assert_eq!(parse("PIA_USER=u\nPIA_PASS=a=b#c\n").unwrap().pass, "a=b#c");
    }

    #[test]
    fn missing_user_is_named() {
        assert!(parse("PIA_PASS=x\n").err().unwrap().to_string().contains("PIA_USER"));
    }

    #[test]
    fn missing_pass_is_named() {
        assert!(parse("PIA_USER=x\n").err().unwrap().to_string().contains("PIA_PASS"));
    }
}
