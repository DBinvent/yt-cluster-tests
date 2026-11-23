# labac: sign in at an identity provider, read through ytproxy

A test environment for the whole path of a person's access: the groups an identity provider
says a person is in, signon's labac rules that turn them into what the person may reach, and
ytproxy, which lets each person see exactly those rows - in both of its security modes.

```
 a person                                                           the rows it may reach
    |                                                                         ^
    | name, password                                                          |
    v                                                                         |
 FerrisKey (OIDC)  --- id_token: groups ["/dept/sales", "/clearance/2"] --+   |
                                                                          |   |
 labac-host  <------------------------------------------------------------+   |
   signon: the mapping rules  ->  the subject (groups, role, levels)          |
   answers the labac token  ----------------------------------------------+   |
                                                                          v   |
 psql  -- SET labac.token = '...'; SELECT ... -->  ytproxy  -->  PostgreSQL --+
                                                   lsr: rewrites the SQL (app_lsr)
                                                   rls: row-level security (app_rls)
```

Several projects meet here, which is why it lives in this repository: FerrisKey (the provider),
signon (accounts, labac), schema_guard (the tables' `security` declarations, the rls policies),
ytproxy (the lsr rewrite, the rls entry), and `host/`, a small program of this folder that is the
site signon is mounted in.

## Run it

```sh
labac/run_all.sh                 # build, up, set up, every check, down
LABAC_KEEP=1 labac/run_all.sh    # leave it up; labac/90_down.sh takes it down
nightly/locked.sh labac/run_all.sh   # on hosts the nightly also uses: under its lock
```

It needs, where the scripts run: `cargo`, `curl`, `python3`, `ssh` to the docker host; a ytproxy
checkout beside this repository (or `YTPROXY`); the libc of the image the binaries run in
(`LABAC_BASE_IMAGE`, `ubuntu:24.04`). The containers run on the docker host of `../.env`
(`YX_HOST`, an ssh target or `local`); two ports are published there, FerrisKey's and the host
program's (`LABAC_FK_PORT` 13333, `LABAC_HOST_PORT` 13380), and the scripts reach them at the
host's address (`LABAC_ADDR`; unset, the first address the docker host says of itself).

`host/` builds on signon 1.1 and schema_guard_tokio 2.5. Until they are published, a local
`host/.cargo/config.toml` (not committed) points both at sibling checkouts:

```toml
[patch.crates-io]
signon = { path = "../../../signon" }
schema_guard_tokio = { path = "../../../schema_guard" }
```

| script | what |
|---|---|
| `00_build.sh` | ytproxy with its `labac` feature, and `host/` |
| `10_up.sh` | PostgreSQL (the databases `ferriskey`, `signon`, `app_lsr`, `app_rls`), etcd, FerrisKey |
| `20_ferriskey.sh` | the realm, the client, the `groups` scope, the organization's group tree, the people |
| `30_setup.sh` | the host program; signon's rules and ACL (`signon.json`); the test schema (`schema.yaml`) deployed under lsr and under rls, its rows (`data.sql`); the schema map in etcd; ytproxy twice |
| `40_login.sh` | every person signs in; what the rules made of each; a token for a level; what is no id_token |
| `50_queries.sh` | every person against every table, in both modes |
| `60_regroup.sh` | a person's groups change at the provider |
| `90_down.sh` | everything down |

## The fixture

The groups at FerrisKey are a tree, and a token says a group by its path. signon's rules
(`signon.json`) read the paths:

| group | rule | gives |
|---|---|---|
| `/dept/<d>` | `^/dept/([a-z0-9_]+)$` | the ABAC group `dept-<d>`, the PostgreSQL role `labac_staff` |
| `/reviewers` | by name | the ABAC group `reviewers`, the role |
| `/clearance/<n>` | `^/clearance/([0-9]+)$` | the level `sal` = n: the security access level |
| `/review/<n>` | `^/review/([0-9]+)$` | the level `review` = n |

The ACL: `dept-sales` and `dept-eng` have the level 4 on their department (select, insert,
update, soft delete), `dept-hr` 5 on its own (delete too), and `reviewers` 1 - select - on
resource `*`: every department.

| person | groups | so |
|---|---|---|
| alice | dept/sales, clearance/2, review/1 | sales, sal 2, review 1 |
| bob | dept/eng, clearance/4, review/2 | eng, sal 4, review 2 |
| carol | reviewers, clearance/3, review/3 | reads every department, sal 3, review 3 |
| dave | dept/sales, dept/hr, clearance/1 | sales and hr, sal 1, no review level |
| erin | none | signs in at FerrisKey; no rule maps her: no token |
| frank | dept/sales | sales, no level |

The test schema (`schema.yaml`) has the four shapes of a table's `security`:

```yaml
projects: {schemaPath: {dml: [dept], sal: [sal]}, alias: dept}    # a department and a level of its own
docs:                                                             # several paths by name:
  schemaPath:
    dml: [public.docs.project_id, public.projects.dept]           #   its project's department
    sal: [public.docs.project_id, public.projects.sal]            #   its project's level
    review: [review]                                              #   a level of its own
  softDelete: deleted_at
tasks: {schemaPath: [public.tasks.project_id, public.projects.dept]}   # the dml path alone, a list
notices: {schemaPath: {sal: [sal]}}                               # a level alone
```

## What the checks show

- **By department and action.** A row's department must be one of the person's for what the
  statement does: alice reads and updates sales, never eng; carol reads everything and changes
  nothing; dave deletes in hr, not in sales.
- **By level.** A table that declares a level is reached at that level or higher. A row with no
  level counts as 0; a person with no level reaches no row of such a table (frank).
- **A hidden parent denies.** A row that follows a path through another covered table is reached
  only when that table's row is read: a task of a project above the person's level is hidden,
  though `tasks` declares no level - by ytproxy's rewrite under lsr, by PostgreSQL itself under
  rls.
- **The level asked.** A token may be minted for a lower level (`/login?level=1`), a session may
  lower it (`SET labac.level = 2`, `SET labac.level.review = 1`, `RESET labac.level`); never above
  the person's own, nor above the token's.
- **A change of groups** reaches signon at the person's next sign-in: the new token is the new
  access, the token from before is refused.
- **Both modes give the same rows.** They answer differently in one place: a statement refused
  inside an open transaction is an ERROR of the database under rls (the session goes on), and
  under lsr a refusal of ytproxy's own, which ends the session (FATAL). SQLSTATE 42501 in both.

## Notes

- **The sign-in is scripted**: the OIDC password grant (the client's direct access grants), no
  browser. `host/` takes the id_token at `POST /login`, checks it against FerrisKey's keys, its
  issuer and its audience, and does what a site does at a sign-in: `labac::remap`, then the token.
- **FerrisKey** (tested with 0.10.0) puts no groups into a token until a mapper says so: the
  client scope `groups` with an `oidc-group-membership-mapper` (claim `groups`). A member of a
  group is said to be in its parents too (`/dept` beside `/dept/sales`): the rules match the whole
  path. A password is 12 characters or more. The issuer in a token is the URL FerrisKey was asked
  at, so every sign-in goes through the published one.
- **The schema map** in etcd (each table's structure, its primary key, its grants, its `security`
  declaration) is what ytproxy reads the covered tables and their join keys from. In YT Cluster
  ytserv keeps it; no node runs here, so `labac-host schema-map` says the keys and the scripts put
  them.
- **Service accounts.** ytproxy reads signon's service accounts with the ACL: the host program
  migrates signon with that feature for the table's sake. No service account is used.
- The passwords in `env.sh` are of containers that live for one run; the keys are made per run
  and go with it.
