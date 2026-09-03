# EthiopiaEMR: Initializer and content package

How OpenMRS Initializer loads metadata in this distro, how CSV changes affect existing databases, checksums, and how to reload roles/privileges locally with the OpenMRS SDK.

This distro uses **OpenMRS Platform 2.8.7** and **initializer-omod 2.11.1-SNAPSHOT** (Palladium Kenya fork).

---

## 1. What Initializer is

Initializer (Iniz) is an **API-only** OpenMRS module. On module startup it reads files from the application-data `configuration/` folder and upserts metadata into the database (privileges, roles, concepts, forms, global properties, and more).

It is **not** a runtime permission engine. Privilege checks at request time use OpenMRS `User` / `Role` objects (and caches), not a fresh read of the CSV.

Initializer:

- Creates or updates an object **for each CSV line that is still present**.
- Does **not** delete objects that disappear from a file.
- Writes a **checksum** per file and skips unchanged files on the next load.

---

## 2. How this distro wires it

### Content package (source of CSVs)

```
ethiopiaemr-openmrs-content/
  configuration/
    backend_configuration/     ← Initializer domains (roles, privileges, concepts, …)
    frontend_configuration/    ← O3 SPA config (not Initializer)
```

Maven packs this as `ethiopiaemr-package` (`org.ethiopiaemr.content`). The OpenMRS SDK unpacks `backend_configuration/` into the server’s `configuration/` directory.

Distro inclusion (`ethiopiaemr-distro-referenceapplication/distro/distro.properties`):

```
content.ethiopiaemr-package=${ethiopiaemr-package.version}
content.ethiopiaemr-package.groupId=org.ethiopiaemr.content
omod.initializer=${initializer.version}
```

Version and OMOD dependency: `ethiopiaemr-distro-referenceapplication/distro/pom.xml` (`initializer.version`, `initializer-omod`).

### Git vs Maven

| What | Where |
|------|--------|
| Source repo (Palladium fork) | https://github.com/palladiumkenya/openmrs-module-initializer |
| Maven packages | `https://maven.pkg.github.com/palladiumkenya/openmrs-module-initializer` |
| Declared in | `distro/pom.xml` and parent `pom.xml` as repository id `github-palladiumkennya-initializer` |
| Upstream docs | https://github.com/mekomsolutions/openmrs-module-initializer |

GitHub Packages needs a PAT in `~/.m2/settings.xml` with server id `github-palladiumkennya-initializer`.

Change **CSV content** in `ethiopiaemr-openmrs-content`. Change **loader behaviour** in the Palladium Initializer fork.

---

## 3. Startup: domains and order

Initializer scans `configuration/` and loads domains in a **fixed order**. Privileges run **before** roles so a role CSV can name privileges that were just created.

Relevant slice:

1. Privileges (`configuration/privileges/*.csv`)
2. Roles (`configuration/roles/*.csv`)
3. Then global properties, locations, concepts, AMPATH forms, …

Each CSV **line** is one metadata object: create if missing, update if found (UUID, or name when UUID is blank).

### File order inside a domain

Header `_order:N` controls order **within** that domain. Lower runs first. Files with no `_order` run last.

In this repo:

| File | `_order` | Typical contents |
|------|----------|------------------|
| `_ethiopiaemr-security-roles.csv` | 1 | Clinical API Read/Write, System Administrator |
| `facility_wide.csv` | 1000 | o3: Nurse, o3: Pharmacist, … |
| `stock-roles.csv` | 1000 | Inventory roles |
| `ethio-emr.csv` | none (last) | ethiopiaemr: Physician, Nurse, triage roles, … |

Same `_order` → alphabetical filename. That is why API-read/write roles exist before Physician/Nurse inherit them.

Initializer does **not** assign roles to users (`user_role`). That is still Admin UI / REST.

---

## 4. Checksums

After a file is loaded, Initializer writes a checksum next to the config:

```
configuration/               ← CSVs
configuration_checksums/     ← one .checksum per file
```

On the next load, if the file hash matches, **that file is skipped**. Unchanged CSVs do not touch the DB again.

Checksums live beside the **runtime** config, not in git. On SDK that is typically:

```
~/openmrs/ethiopiaemr/configuration/
~/openmrs/ethiopiaemr/configuration_checksums/
```

Example: `configuration_checksums/roles/ethio-emr.checksum`

Deleting a checksum (or changing the CSV) forces a reload of that file.

`initializer.skip.checksums=true` reprocesses every included file every load. Useful for a tight local loop; avoid on a shared DB.

---

## 5. How a roles CSV is applied

Privileges CSV: mostly **creates** named privileges. The privilege name is the identifier; do not rename after create.

Roles CSV columns: `Uuid`, `Role name`, `Description`, `Inherited roles`, `Privileges`. Lists are `;`-separated.

The parser **replaces** (does not merge) inherited roles and privileges:

```java
role.setInheritedRoles(new HashSet(parsedInheritedRoles));
role.setPrivileges(new HashSet(parsedPrivileges));
```

When a roles file is actually processed:

- Extra `role_privilege` rows you added only in SQL are **removed**.
- Privileges listed in the CSV are **added**.
- Inherited roles are replaced the same way.

Lookup: UUID first, then **role name**. Several rows in `ethio-emr.csv` leave Uuid blank, so re-adding `ethiopiaemr: Physician` later finds the existing row by name.

`Void/Retire=true` is the supported way to retire a row. Initializer does **not** call `purgeRole()`. OpenMRS roles were not originally retirable; confirm in Admin if retire actually stuck.

---

## 6. CSV changes vs already-seeded databases

Initializer is **upsert-by-row**, not desired-state sync.

| Change | Already-seeded DB | New / never-loaded DB |
|--------|-------------------|------------------------|
| Add a role/privilege line | Created/updated on next **successful load** of that file | Same |
| Edit Privileges / Inherited roles | Full replace of that role’s mapping | Same |
| Delete a line from the CSV | **Role stays**. Users keep it. Privileges unchanged. | Role is never created → **drift** |
| Delete the whole CSV file | File is not processed; existing roles stay | Those roles never appear |
| Add `Void/Retire=true` on the row | Attempts to retire (keep the row) | Creates retired, or retires if it exists |

Removing a CSV line only stops **future** installs from getting that role. Seeded sites keep it until you retire/purge on purpose.

Hard delete is outside Initializer: Admin UI, `UserService.purgeRole()`, or SQL. Purge fails if the role has child roles. Clear `user_role` separately if users should lose the assignment.

---

## 7. Direct SQL edits (not CSV)

Updating `role_privilege` in MySQL does **not** update a running app.

Stale layers:

1. **Hibernate L2 cache** — `Role` is `@Cacheable` (Infinispan on 2.8.x). SQL bypasses Hibernate.
2. **HTTP `UserContext`** — authenticated `User` and roles live on the session.
3. **O3 session** — SPA uses `GET /ws/rest/v1/session` → `session.user.privileges`.

Logout/login alone is often **not** enough: login may still load `Role` from L2 cache.

Do **not** call `saveRole()` after a raw SQL edit until the entity is evicted; the in-memory role can write old privileges back to the DB.

Reliable approaches:

- Change the CSV and let Initializer `saveRole()` (evicts via the API), **or**
- Restart the backend, **or**
- Evict caches then force re-login (see below).

If the mapping should survive restarts, put it in the CSV. Otherwise a later Initializer load of that file will overwrite SQL.

### Clear caches without a full JVM restart (Groovy)

`/openmrs/module/groovy/groovy.form` (needs legacy admin, e.g. `View Legacy Admin`):

```groovy
import org.openmrs.Role
import org.openmrs.Privilege
import org.openmrs.api.context.Context

Context.evictAllEntities(Role.class)
Context.evictAllEntities(Privilege.class)
Context.clearEntireCache()
Context.refreshAuthenticatedUser()

"caches cleared"
```

`refreshAuthenticatedUser()` only reloads **your** user. Other sessions keep the old `User`. There is no “kick all users” API: each user must log out (O3 logout or `DELETE /openmrs/ws/rest/v1/session`) or you restart Tomcat/SDK.

---

## 8. Local SDK: test a CSV without rebuilding the distro

Initializer reads the **SDK server directory**, not git.

Typical layout (`serverId=ethiopiaemr`):

```
~/openmrs/ethiopiaemr/configuration/roles/ethio-emr.csv
~/openmrs/ethiopiaemr/configuration_checksums/roles/ethio-emr.checksum
```

### Fast loop

1. Edit git, e.g. `ethiopiaemr-openmrs-content/configuration/backend_configuration/roles/ethio-emr.csv`.
2. Copy into the SDK config and drop the checksum:

```bash
cp ethiopiaemr-openmrs-content/configuration/backend_configuration/roles/ethio-emr.csv \
  ~/openmrs/ethiopiaemr/configuration/roles/ethio-emr.csv

rm -f ~/openmrs/ethiopiaemr/configuration_checksums/roles/ethio-emr.checksum
```

3. Restart the SDK **or** trigger load via Groovy (section 10).

```bash
mvn openmrs-sdk:run -DserverId=ethiopiaemr
```

Initializer only auto-runs at **module startup** unless you call the API.

If the role uses a **new** privilege, copy that privileges CSV and delete its checksum too. Inherited roles (e.g. `ethiopiaemr: Clinical API Read Access`) must already exist (`_ethiopiaemr-security-roles.csv`, `_order:1`).

Then **assign the role to a user** and log out/in. Confirm in Legacy Admin → Roles, or:

```
GET /openmrs/ws/rest/v1/role?q=ethiopiaemr
```

Do **not** `mvn install` the content zip and rebuild the distro just to try one row. Do **not** `openmrs-sdk:setup` again; that is first-time server creation.

Use the full content-package → distro rebuild when the zip in `.m2` should match git, before sharing the change.

Watch backend / `initializer.log` for the domain table: **loaded** vs **skipped**.

---

## 9. Run only some domains at startup

Initializer already runs only at startup. To process **only** roles (skip concepts, forms, …), set an inclusion list.

This distro does not set that by default. Add to `~/openmrs/ethiopiaemr/openmrs-runtime.properties` or `openmrs-server.properties`:

```properties
initializer.domains=roles
```

If the role needs a new privilege:

```properties
initializer.domains=privileges,roles
```

Restart:

```bash
mvn openmrs-sdk:run -DserverId=ethiopiaemr
```

Or override:

```bash
mvn openmrs-sdk:run -DserverId=ethiopiaemr -Dinitializer.domains=privileges,roles
```

Unspecified `initializer.domains` means **all** domains. Exclude with `!`:

```properties
initializer.domains=!concepts,conceptsets,ampathforms
```

Other runtime properties:

| Property | Meaning |
|----------|---------|
| `initializer.exclude.roles=*tmp*` | Wildcard-skip files in a domain |
| `initializer.skip.checksums=true` | Reload included files every time |
| `initializer.startup.load=continue_on_error` | Default: log errors, keep starting |
| `initializer.startup.load=fail_on_error` | Fatal if a domain fails |
| `initializer.startup.load=disabled` | Do not load at startup; call the API yourself |

System properties override runtime properties (including an empty value).

Restricting domains does **not** bypass checksums.

---

## 10. Run loaders without restarting (Groovy)

There is **no** REST endpoint or Admin “run migrations” button. Initializer is API-only.

This distro includes `groovy-omod`. After copying CSVs and deleting checksums:

**Roles only:**

```groovy
import org.openmrs.api.context.Context
import org.openmrs.module.initializer.api.InitializerService

def iniz = Context.getService(InitializerService.class)
def roles = iniz.loaders.find { it.domainName == "roles" }
roles.loadUnsafe([], true)

"roles loaded"
```

**Privileges then roles:**

```groovy
import org.openmrs.api.context.Context
import org.openmrs.module.initializer.api.InitializerService

def iniz = Context.getService(InitializerService.class)
["privileges", "roles"].each { name ->
  def loader = iniz.loaders.find { it.domainName == name }
  loader.loadUnsafe([], true)
}

"privileges + roles loaded"
```

**Full load** (honours `initializer.domains` when `applyFilters` is true):

```groovy
Context.getService(org.openmrs.module.initializer.api.InitializerService.class)
  .loadUnsafe(true, true)
```

`loadUnsafe(..., true)` throws on the first error. `load()` logs and continues.

From another module: same `InitializerService`. That is what `initializer.startup.load=disabled` is for.

**Initializer Validator** is a dry-run fatjar against a config directory. It is not a live reload of the SDK database.

`saveRole()` goes through the API, so Hibernate should see the new mapping. Logged-in users still need to log out and back in.

---

## 11. Practical recipes

**Add a role locally (SDK)**

1. Add/edit the line in `backend_configuration/roles/*.csv` (and a privileges CSV if needed).
2. Copy into `~/openmrs/ethiopiaemr/configuration/…`.
3. `rm` the matching `.checksum`.
4. Optional: `initializer.domains=privileges,roles`.
5. Restart SDK **or** Groovy `loadUnsafe` on those loaders.
6. Assign the role to a test user; log out/in.
7. Confirm `/ws/rest/v1/session` privileges.

**Change a mapping forever**

Put it in git CSVs, ship via the content package. Do not rely on SQL on one environment.

**Stop shipping a role without breaking old sites**

Keep the row and set `Void/Retire=true`. Deleting the line only affects new DBs.

---

## 12. Pointers

- Initializer runtime properties: [readme/rtprops.md](https://github.com/mekomsolutions/openmrs-module-initializer/blob/master/readme/rtprops.md)
- Checksums: [readme/checksums.md](https://github.com/mekomsolutions/openmrs-module-initializer/blob/master/readme/checksums.md)
- CSV conventions (Uuid, Void/Retire, `_order`): [readme/csv_conventions.md](https://github.com/mekomsolutions/openmrs-module-initializer/blob/master/readme/csv_conventions.md)
- Roles domain: [readme/roles.md](https://github.com/mekomsolutions/openmrs-module-initializer/blob/master/readme/roles.md)
- Distro SDK notes: `ethiopiaemr-distro-referenceapplication/README.md`
