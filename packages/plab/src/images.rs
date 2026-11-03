//! The image cache: `img/<sha1 of url>` under the state directory, ported from store.py's
//! `key`, `image_path`, `ensure_image`, `prune_images` and `_write`, and main.py's `sniff`.

use sha1::{Digest, Sha1};
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

/// sha1 hex of the URL. Must equal store.py's `key()`, so the imported `img/` cache keeps
/// working.
pub fn key(url: &str) -> String {
    hex::encode(Sha1::digest(url.as_bytes()))
}

/// The image type of `data` by its magic bytes, or None if it is not an image.
pub fn sniff(data: &[u8]) -> Option<&'static str> {
    if data.starts_with(b"\xff\xd8\xff") {
        Some("image/jpeg")
    } else if data.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some("image/png")
    } else if data.starts_with(b"GIF8") {
        Some("image/gif")
    } else if data.starts_with(b"RIFF") && data.get(8..12) == Some(&b"WEBP"[..]) {
        Some("image/webp")
    } else {
        None
    }
}

/// Distinguishes temp files of concurrent writers within one process; the pid distinguishes
/// processes (the daemon and a one-shot `refresh` share the directory).
static TMP_SEQ: AtomicU64 = AtomicU64::new(0);

#[derive(Clone)]
pub struct ImageCache {
    pub dir: PathBuf,
}

impl ImageCache {
    pub fn new(dir: PathBuf) -> std::io::Result<ImageCache> {
        std::fs::create_dir_all(&dir)?;
        Ok(ImageCache { dir })
    }

    pub fn path(&self, url: &str) -> PathBuf {
        self.dir.join(key(url))
    }

    #[cfg(test)]
    pub fn get(&self, url: &str) -> Option<Vec<u8>> {
        std::fs::read(self.path(url)).ok()
    }

    /// Write-then-rename, so a reader sees the old file or the new one, never half of either.
    pub fn put(&self, url: &str, data: &[u8]) -> std::io::Result<PathBuf> {
        let path = self.path(url);
        let tmp = self.dir.join(format!(
            "{}.{}.{}.tmp",
            key(url),
            std::process::id(),
            TMP_SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        let result = std::fs::write(&tmp, data).and_then(|()| std::fs::rename(&tmp, &path));
        if result.is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
        result.map(|()| path)
    }

    /// Remove every cached image whose URL is not in `keep_urls`. In-flight temp files
    /// belong to a concurrent writer, so names ending ".tmp" are left alone.
    pub fn prune(&self, keep_urls: &[String]) -> std::io::Result<()> {
        let keep: HashSet<String> = keep_urls.iter().map(|u| key(u)).collect();
        for entry in std::fs::read_dir(&self.dir)? {
            let name = entry?.file_name();
            let name = name.to_string_lossy();
            if keep.contains(name.as_ref()) || name.ends_with(".tmp") {
                continue;
            }
            match std::fs::remove_file(self.dir.join(name.as_ref())) {
                Ok(()) => {}
                // Another process pruned it first.
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(e),
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn key_is_sha1_hex_of_url() {
        assert_eq!(key("https://x/y.jpg").len(), 40);
        // hashlib.sha1(b"https://x/y.jpg").hexdigest()
        assert_eq!(
            key("https://x/y.jpg"),
            "a96fd4ace65037d5b2af3c163768cb4d3f3eaf44"
        );
    }

    #[test]
    fn sniff_types() {
        assert_eq!(sniff(b"\xff\xd8\xff\xe0"), Some("image/jpeg"));
        assert_eq!(sniff(b"\x89PNG\r\n\x1a\n...."), Some("image/png"));
        assert_eq!(sniff(b"GIF89a"), Some("image/gif"));
        assert_eq!(sniff(b"RIFF\0\0\0\0WEBPVP8 "), Some("image/webp"));
        assert_eq!(sniff(b"<html>"), None);
    }

    #[test]
    fn sniff_is_none_for_short_input() {
        assert_eq!(sniff(b""), None);
        assert_eq!(sniff(b"RIFF\0\0\0\0WEB"), None);
    }

    #[test]
    fn prune_keeps_listed_and_tmp() {
        let d = tempfile::tempdir().unwrap();
        let c = ImageCache::new(d.path().into()).unwrap();
        c.put("a", b"1").unwrap();
        c.put("b", b"2").unwrap();
        std::fs::write(d.path().join("x.tmp"), b"").unwrap();
        c.prune(&["a".into()]).unwrap();
        assert!(c.get("a").is_some());
        assert!(c.get("b").is_none());
        assert!(d.path().join("x.tmp").exists());
    }

    #[test]
    fn put_stores_bytes_under_key_and_leaves_no_tmp() {
        let d = tempfile::tempdir().unwrap();
        let c = ImageCache::new(d.path().join("img")).unwrap();
        let path = c.put("https://x/a.jpg", b"\xff\xd8\xffdata").unwrap();
        assert_eq!(
            path.file_name().unwrap().to_str().unwrap(),
            key("https://x/a.jpg")
        );
        assert_eq!(std::fs::read(&path).unwrap(), b"\xff\xd8\xffdata");
        let names: Vec<_> = std::fs::read_dir(&c.dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .collect();
        assert_eq!(names, vec![key("https://x/a.jpg")]);
    }

    #[test]
    fn put_twice_for_same_url_is_fine() {
        let d = tempfile::tempdir().unwrap();
        let c = ImageCache::new(d.path().into()).unwrap();
        c.put("a", b"first").unwrap();
        c.put("a", b"second").unwrap();
        assert_eq!(c.get("a").unwrap(), b"second");
    }

    #[test]
    fn get_missing_is_none() {
        let d = tempfile::tempdir().unwrap();
        let c = ImageCache::new(d.path().into()).unwrap();
        assert!(c.get("nope").is_none());
    }

    #[test]
    fn new_creates_the_directory() {
        let d = tempfile::tempdir().unwrap();
        let dir = d.path().join("a").join("img");
        let c = ImageCache::new(dir.clone()).unwrap();
        assert!(dir.is_dir());
        assert_eq!(c.dir, dir);
    }
}
