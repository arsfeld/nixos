//! The one HTTP client setup every service client uses: rustls, no automatic redirects.

use std::time::Duration;

/// rustls, redirects not followed (the tracker client follows them by hand to keep its
/// cookies), and the given whole-request timeout.
pub fn client(timeout_secs: u64) -> reqwest::Client {
    reqwest::Client::builder()
        .use_rustls_tls()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(timeout_secs))
        .build()
        .expect("the HTTP client's static configuration is valid")
}

fn with_headers(
    mut req: reqwest::RequestBuilder,
    headers: &[(&str, String)],
) -> reqwest::RequestBuilder {
    for (k, v) in headers {
        req = req.header(*k, v);
    }
    req
}

/// POST `body` as JSON and return the JSON reply; a non-2xx status is an error.
pub async fn post_json(
    c: &reqwest::Client,
    url: &str,
    body: &serde_json::Value,
    headers: &[(&str, String)],
) -> anyhow::Result<serde_json::Value> {
    let resp = with_headers(c.post(url).json(body), headers)
        .send()
        .await?
        .error_for_status()?;
    Ok(resp.json().await?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{body_json, header, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[tokio::test]
    async fn post_json_sends_body_and_headers() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api"))
            .and(header("ApiKey", "k"))
            .and(body_json(serde_json::json!({"q": 1})))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"ok": true})))
            .expect(1)
            .mount(&server)
            .await;
        let v = post_json(
            &client(5),
            &format!("{}/api", server.uri()),
            &serde_json::json!({"q": 1}),
            &[("ApiKey", "k".into())],
        )
        .await
        .unwrap();
        assert_eq!(v, serde_json::json!({"ok": true}));
    }

    #[tokio::test]
    async fn error_status_is_an_error() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(500))
            .mount(&server)
            .await;
        let c = client(5);
        assert!(
            post_json(&c, &server.uri(), &serde_json::json!({}), &[])
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn redirects_are_not_followed() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/a"))
            .respond_with(ResponseTemplate::new(302).insert_header("Location", "/b"))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/b"))
            .respond_with(ResponseTemplate::new(200))
            .expect(0)
            .mount(&server)
            .await;
        let r = client(5)
            .get(format!("{}/a", server.uri()))
            .send()
            .await
            .unwrap();
        assert_eq!(r.status().as_u16(), 302);
    }
}
