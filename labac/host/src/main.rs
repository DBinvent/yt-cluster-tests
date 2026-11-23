//! labac-host: the host program of the labac login environment (`yt-cluster-tests/labac`).
//!
//! signon is a library: a site of its own mounts it and decides what a sign-in gives. This is
//! the smallest such site, for the tests - a person signs in at an OIDC identity provider
//! (FerrisKey here) and brings the id_token; the host
//!
//! 1. verifies it against the provider's keys (its issuer, its audience, its signature),
//! 2. finds the signon account of the token's address, or makes one,
//! 3. runs signon's mapping rules over the token's `groups` (`labac::remap`): the account's
//!    subject - its ABAC groups, its PostgreSQL role, its named levels,
//! 4. answers signon's labac token for it: what the person enters ytproxy with.
//!
//! The other commands set the environment up, so the scripts need no SQL of signon's own:
//!
//! ```text
//! labac-host serve                       the sign-in, on LABAC_LISTEN (POST /login, GET /health)
//! labac-host seed <fixture.json>         the mapping rules, the resources and the ACL entries
//! labac-host deploy <db> <yaml> <mode>   a schema with its `security` declarations: lsr or rls
//! labac-host key <db> <key file>         labac's SQL part and its key in a database (rls)
//! labac-host schema-map <db> <cluster>   the schema map's keys of a database, as ytserv writes
//!                                        them into etcd: `<key><TAB><value>` lines
//! ```
//!
//! Settings come from the environment: `LABAC_DB_URL` (signon's database), and for `serve`
//! `LABAC_TOKEN_KEY_FILE` (signon's labac token key, ytproxy's `token_key_file`), `LABAC_ISSUER`,
//! `LABAC_JWKS_URL`, `LABAC_AUDIENCE` (the provider's client id), `LABAC_LISTEN`.

use std::collections::BTreeMap;
use std::sync::Arc;

use anyhow::{anyhow, bail, Context};
use axum::extract::{RawQuery, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::Json;
use serde::Deserialize;
use serde_json::json;
use signon::labac;
use sqlx::PgPool;

/// a labac token lasts an hour here: a test run is over long before
const TOKEN_TTL: i64 = 3600;

fn env(name: &str) -> anyhow::Result<String> {
    std::env::var(name).ok().filter(|v| !v.trim().is_empty()).ok_or_else(|| anyhow!("{name} is not set"))
}

async fn pool(db_url: &str) -> anyhow::Result<PgPool> {
    sqlx::postgres::PgPoolOptions::new().max_connections(4).connect(db_url).await.with_context(|| "the database does not answer".to_string())
}

/// a key as its file holds it: the text without the line end
fn read_key(path: &str) -> anyhow::Result<Vec<u8>> {
    let k = std::fs::read_to_string(path).with_context(|| format!("key file {path}"))?.trim().as_bytes().to_vec();
    if k.is_empty() {
        bail!("key file {path}: empty");
    }
    Ok(k)
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .with_writer(std::io::stderr)
        .init();
    let args: Vec<String> = std::env::args().skip(1).collect();
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    match args.as_slice() {
        ["serve"] => serve().await,
        ["seed", file] => seed(file).await,
        ["deploy", db, file, mode] => deploy(db, file, mode).await,
        ["key", db, file] => key(db, file).await,
        ["schema-map", db, cluster] => schema_map(db, cluster).await,
        _ => {
            eprintln!("usage: labac-host serve | seed <fixture.json> | deploy <db url> <schema.yaml> <lsr|rls> | \
                key <db url> <key file> | schema-map <db url> <cluster>");
            std::process::exit(2);
        }
    }
}

// ---- the sign-in ------------------------------------------------------------------------

struct Host {
    pool: PgPool,
    token_key: Vec<u8>,
    issuer: String,
    jwks_url: String,
    audience: String,
}

async fn serve() -> anyhow::Result<()> {
    let db_url = env("LABAC_DB_URL")?;
    // signon's own tables, its labac ones with them: schema_guard, the same on every start
    signon::migrate(&db_url).await?;
    let host = Arc::new(Host {
        pool: pool(&db_url).await?,
        token_key: read_key(&env("LABAC_TOKEN_KEY_FILE")?)?,
        issuer: env("LABAC_ISSUER")?,
        jwks_url: env("LABAC_JWKS_URL")?,
        audience: env("LABAC_AUDIENCE")?,
    });
    let listen = std::env::var("LABAC_LISTEN").unwrap_or_else(|_| "0.0.0.0:8080".to_string());
    let app = axum::Router::new()
        .route("/health", get(|| async { "ok" }))
        .route("/login", post(login))
        .with_state(host);
    let listener = tokio::net::TcpListener::bind(&listen).await.with_context(|| format!("listen {listen}"))?;
    tracing::info!(%listen, "labac-host serves");
    axum::serve(listener, app).await?;
    Ok(())
}

fn refuse(status: StatusCode, error: &str, detail: impl std::fmt::Display) -> Response {
    (status, Json(json!({ "error": error, "detail": detail.to_string() }))).into_response()
}

/// `POST /login[?level=<n>][&level.<name>=<n>]`, the body an id_token: the labac token of its
/// person. The query asks the levels the token is minted for - its tops - as signon's own token
/// page does (`/labac/token?level=2`).
///
/// [review 2026-11-22] The id_token is what signs the person in, for as long as it lasts (five
/// minutes at FerrisKey): a script's password grant has no browser attempt to bind it to, so no
/// nonce is asked. A site with a browser signs in through signon's own flow, which sends one and
/// checks it.
async fn login(State(host): State<Arc<Host>>, RawQuery(query): RawQuery, body: String) -> Response {
    // 1. the provider's word: its signature by its published keys, its issuer, its audience
    let claims = match signon::jwt::verify_id_token(body.trim(), &host.jwks_url, &host.issuer, &host.audience, None).await {
        Ok(c) => c,
        Err(e) => return refuse(StatusCode::UNAUTHORIZED, "id_token", e),
    };
    let Some(email) = claims.email.as_deref().map(str::trim).filter(|e| !e.is_empty()) else {
        return refuse(StatusCode::FORBIDDEN, "email", "the id_token names no address");
    };
    // an address the provider has not verified is nobody's yet: it would take over the account of
    // whoever owns it
    if !matches!(&claims.email_verified, Some(v) if v == &json!(true) || v == &json!("true")) {
        return refuse(StatusCode::FORBIDDEN, "email", "the provider has not verified the address");
    }
    // 2. the account of that address: signon's, made at the first sign-in. Its password is one
    // nobody knows - the person signs in at the provider, never here. [review 2026-11-22] An account
    // of that address whose address signon has not verified is somebody's claim to it, not this
    // person's account: the provider's groups are not given to it
    let user = match signon::user_id_by_email(&host.pool, email).await {
        Ok(Some(u)) => match signon::is_email_verified(&host.pool, email).await {
            Ok(true) => u,
            Ok(false) => return refuse(StatusCode::FORBIDDEN, "account", "an account of this address exists, its address not verified"),
            Err(e) => return refuse(StatusCode::INTERNAL_SERVER_ERROR, "account", e),
        },
        Ok(None) => {
            let unknown = format!("{}-{}", uuid::Uuid::new_v4(), uuid::Uuid::new_v4());
            match signon::api::add_account(&host.pool, email, &unknown).await {
                Ok(Some(u)) => u,
                // made by a sign-in of the same person at the same moment
                Ok(None) => match signon::user_id_by_email(&host.pool, email).await {
                    Ok(Some(u)) => u,
                    _ => return refuse(StatusCode::INTERNAL_SERVER_ERROR, "account", "not made"),
                },
                Err(e) => return refuse(StatusCode::INTERNAL_SERVER_ERROR, "account", e),
            }
        }
        Err(e) => return refuse(StatusCode::INTERNAL_SERVER_ERROR, "account", e),
    };
    // 3. the rules over what the provider said of the person: the subject, its version moved
    // when its access changed
    let subject = match labac::remap(&host.pool, user, &labac::claims_of_oidc(&claims)).await {
        Ok(s) => s,
        Err(e) => return refuse(StatusCode::INTERNAL_SERVER_ERROR, "remap", e),
    };
    // an account no rule gives anything has no way in: as signon's token page answers one no rule
    // has mapped yet
    if subject.groups.is_empty() && subject.labels.is_empty() && subject.levels.is_empty() && subject.pg_roles.is_empty() {
        return refuse(StatusCode::FORBIDDEN, "no_subject", "no mapping rule gives this account anything");
    }
    // 4. the token, for the levels asked: none asked, the person's own
    let asked = labac::asked_from_query(query.as_deref().unwrap_or("")).and_then(|a| labac::asked_levels(&subject.levels, &a));
    let tops = match asked {
        Ok(t) => t,
        Err(why) => return refuse(StatusCode::FORBIDDEN, "level", why),
    };
    match labac::issue_at(&host.token_key, &subject, TOKEN_TTL, &tops) {
        Ok(token) => Json(json!({ "token": token, "user_id": subject.user_id, "version": subject.version, "groups": subject.groups,
            "pg_roles": subject.pg_roles, "levels": subject.levels, "tops": tops })).into_response(),
        Err(e) => refuse(StatusCode::INTERNAL_SERVER_ERROR, "token", e),
    }
}

// ---- the setup --------------------------------------------------------------------------

/// the fixture: signon's mapping rules, its resources and its ACL entries, as the tests say them
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Fixture {
    rules: Vec<FixRule>,
    resources: Vec<FixResource>,
    entries: Vec<FixEntry>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct FixRule {
    /// `name`, `prefix`, `regex` or `id`
    kind: String,
    pattern: String,
    #[serde(default)]
    group: Option<String>,
    #[serde(default)]
    pg_role: Option<String>,
    #[serde(default)]
    level_name: Option<String>,
    #[serde(default)]
    level_value: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct FixResource {
    kind: String,
    id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct FixEntry {
    kind: String,
    /// a resource's id, or `*`: every resource of the kind
    resource: String,
    group: String,
    level: i16,
}

/// The fixture into signon's tables, in place of what they held: the rules read the id_token's
/// `groups` (source `oidc`)
async fn seed(file: &str) -> anyhow::Result<()> {
    let fixture: Fixture = serde_json::from_str(&std::fs::read_to_string(file).with_context(|| format!("fixture {file}"))?)
        .with_context(|| format!("fixture {file}"))?;
    let db_url = env("LABAC_DB_URL")?;
    signon::migrate(&db_url).await?;
    let pool = pool(&db_url).await?;
    // a fixture is the whole of it: a rule, a person's level or an action's level left from a run
    // before would still count. [review 2026-11-22] Cleared together, or not at all; the subjects
    // stay - each is made again, its version moved, at its person's next sign-in
    let mut tx = pool.begin().await?;
    sqlx::query("DELETE FROM labac_entries").execute(&mut *tx).await?;
    sqlx::query("DELETE FROM labac_resources").execute(&mut *tx).await?;
    sqlx::query("DELETE FROM labac_rules").execute(&mut *tx).await?;
    sqlx::query("DELETE FROM labac_levels").execute(&mut *tx).await?;
    sqlx::query("DELETE FROM labac_actions").execute(&mut *tx).await?;
    tx.commit().await?;
    for r in &fixture.rules {
        let kind = labac::MatchKind::parse(&r.kind).ok_or_else(|| anyhow!("rule {}: no match kind {}", r.pattern, r.kind))?;
        labac::add_rule(&pool, &labac::Rule { id: 0, source: "oidc".into(), claim: "groups".into(), kind, pattern: r.pattern.clone(),
            group: r.group.clone(), label_key: None, label_value: None, level: 0, ceiling: None, pg_role: r.pg_role.clone(),
            level_name: r.level_name.clone(), level_value: r.level_value.clone() }).await?;
    }
    for r in &fixture.resources {
        labac::put_resource(&pool, &labac::Resource { kind: r.kind.clone(), id: r.id.clone(), ..Default::default() }).await?;
    }
    for e in &fixture.entries {
        labac::add_entry(&pool, &labac::Entry { kind: e.kind.clone(), resource: e.resource.clone(), group: e.group.clone(), level: e.level,
            ..Default::default() }).await?;
    }
    println!("{} rules, {} resources, {} entries", fixture.rules.len(), fixture.resources.len(), fixture.entries.len());
    Ok(())
}

/// A schema YAML deployed by schema_guard with its tables' `security` declarations, under the mode
/// named: `lsr` - the tables registered for ytproxy's rewrite - or `rls` - a policy per action
async fn deploy(db_url: &str, file: &str, mode: &str) -> anyhow::Result<()> {
    use schema_guard_tokio::security::SecurityMode;
    let mode = match mode.parse::<SecurityMode>() {
        Ok(SecurityMode::Off) | Err(_) => bail!("mode {mode}: lsr or rls"),
        Ok(m) => m,
    };
    let schema = schema_guard_tokio::load_schema_from_src(std::fs::read_to_string(file).with_context(|| format!("schema {file}"))?)
        .map_err(|e| anyhow!("schema {file}: {e}"))?;
    let n = schema_guard_tokio::migrate_opt(schema, db_url, &schema_guard_tokio::MigrationOptions::new().security(mode)).await
        .map_err(|e| anyhow!("deploy {file}: {e}"))?;
    println!("{n} statements, security {mode:?}");
    Ok(())
}

/// labac's SQL part in a database with the key its tokens are signed with - the key ytproxy reads
/// back (`key_db_url`) to enter a subject. In YT Cluster ytserv writes it from the store
async fn key(db_url: &str, file: &str) -> anyhow::Result<()> {
    labac::apply_sql(&pool(db_url).await?, &read_key(file)?).await?;
    println!("labac.key set");
    Ok(())
}

/// A database's tables as the schema map has them - `schema/cluster:<cluster>/<db>/<schema>/<table>`,
/// the table's structure as JSON: its primary key, its grants, its `security` declaration - one
/// `<key><TAB><value>` line each. In YT Cluster ytserv puts them into etcd every tick; here no node
/// runs, so the scripts put these lines there for ytproxy's lsr mode to read.
///
/// [review 2026-11-22] The declaration comes with the table: schema_guard's loader reads the
/// registry (`labac.tables`) into `PgTable.security`, so nothing is merged in here. A name that
/// would break a line or the key's form (a `/`, a tab, a line end) is left out, and said
async fn schema_map(db_url: &str, cluster: &str) -> anyhow::Result<()> {
    let (mut client, conn) = tokio_postgres::connect(db_url, tokio_postgres::NoTls).await.context("the database does not answer")?;
    tokio::spawn(async move { let _ = conn.await; });
    let mut tx = client.transaction().await?;
    let db: String = tx.query_one("SELECT current_database()", &[]).await?.get(0);
    let info = schema_guard_tokio::loader::load_info_schema(&db, &mut tx).await.map_err(|e| anyhow!("load {db}: {e}"))?;
    let mut lines: BTreeMap<String, String> = BTreeMap::new();
    for (schema, tables) in &info {
        if schema == "labac" {
            continue;
        }
        for (name, table) in tables {
            if [schema.as_str(), name.as_str()].iter().any(|n| n.contains(['/', '\t', '\n', '\r'])) {
                eprintln!("schema-map: {schema}.{name} left out: its name does not fit a key");
                continue;
            }
            lines.insert(format!("schema/cluster:{cluster}/{db}/{schema}/{name}"), serde_json::to_string(table)?);
        }
    }
    for (k, v) in lines {
        println!("{k}\t{v}");
    }
    Ok(())
}
