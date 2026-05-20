# Neo4j User Manual — LXC 107

> Self-hosted Neo4j 5.26 LTS (Community Edition) at **192.168.178.87**
> Backed by 2-tier daily backup (local PVE + NAS).

---

## 1. First-Time Login (Browser UI)

### Step 1 — Open the Browser UI

Open **one** of these URLs in your web browser (Firefox, Chrome, Edge):

| URL | Notes |
|-----|-------|
| **`https://192.168.178.87:7473/browser/`** | ✅ **Recommended.** Neo4j's own HTTPS — fewer mixed-content issues |
| `http://192.168.178.87/browser/` | Plain HTTP via Caddy. Redirected to HTTPS automatically |
| `https://192.168.178.87/browser/` | HTTPS via Caddy reverse-proxy |

⚠️ Your browser will warn about the **self-signed certificate** (issued for `neo4j.lan` + IPs). This is expected — Neo4j and Caddy generate their own LAN-only certs.

- **Firefox**: "Advanced…" → "Accept the Risk and Continue"
- **Chrome/Edge**: "Advanced" → "Proceed to 192.168.178.87 (unsafe)"
- **One-time** per browser; the cert is valid for 10 years.

### Step 2 — Fill in the connection form

When the Neo4j Browser loads, you'll see a connection dialog:

| Field | Value |
|-------|-------|
| **Connect URL** | **`neo4j+s://192.168.178.87:7687`** (recommended)<br/>or `bolt+s://192.168.178.87:7687`<br/>or `bolt+ssc://192.168.178.87:7687` (accepts self-signed) |
| **Authentication type** | `Username / Password` |
| **Username** | `neo4j` |
| **Password** | *(your generated password — see openclaw_ops.md "Neo4j LXC")* |

> **What do the URL schemes mean?**
> - `neo4j+s://` — Bolt over TLS, with cluster routing. **Recommended.**
> - `bolt+s://` — Plain Bolt over TLS, no routing. Single-instance only.
> - `bolt+ssc://` — Bolt over TLS with **s**elf-**s**igned-**c**ert tolerance. Use this if `+s` rejects the cert.
> - `bolt://` / `neo4j://` — Plain Bolt (no TLS). **Will fail from an HTTPS-loaded Browser** due to mixed-content blocking.

### Step 3 — Run your first query

After login you'll see a Cypher prompt. Try:

```cypher
RETURN "Hello from Neo4j!" AS greeting;
```

Press `Ctrl+Enter` (or click the ▶ play button) to execute.

To see what's installed:

```cypher
SHOW DATABASES;
CALL dbms.components() YIELD name, versions, edition;
```

---

## 2. CLI Access (cypher-shell)

### Inside the LXC

```bash
ssh root@192.168.178.108
pct enter 107
docker exec -it neo4j cypher-shell -a bolt://localhost:7687 -u neo4j -p '<PASSWORD>'
```

### From any LAN host with Java

```bash
# Install cypher-shell (Debian/Ubuntu)
apt install cypher-shell

# Connect via TLS (accepting self-signed cert)
cypher-shell -a bolt+ssc://192.168.178.87:7687 -u neo4j -p '<PASSWORD>'

# Or without TLS (only works from CLI, browsers block it)
cypher-shell -a bolt://192.168.178.87:7687 -u neo4j -p '<PASSWORD>'
```

### Common cypher-shell commands

```cypher
:help                    -- list shell commands
:server status           -- connection info
:exit                    -- quit
SHOW DATABASES;          -- list databases
SHOW USERS;              -- list users
RETURN 1+1;              -- ad-hoc query
```

---

## 3. Driver Connection (Python / Node.js / Java / Go)

### Python

```python
from neo4j import GraphDatabase

URI = "neo4j+ssc://192.168.178.87:7687"   # self-signed cert tolerant
AUTH = ("neo4j", "<PASSWORD>")

with GraphDatabase.driver(URI, auth=AUTH) as driver:
    driver.verify_connectivity()
    with driver.session() as session:
        result = session.run("MATCH (n) RETURN count(n) AS nodes")
        print(result.single()["nodes"])
```

Install: `pip install neo4j`

### Node.js

```javascript
import neo4j from 'neo4j-driver';

const driver = neo4j.driver(
    'neo4j+ssc://192.168.178.87:7687',
    neo4j.auth.basic('neo4j', '<PASSWORD>')
);

const session = driver.session();
const result = await session.run('MATCH (n) RETURN count(n) AS nodes');
console.log(result.records[0].get('nodes').toNumber());
await session.close();
await driver.close();
```

Install: `npm install neo4j-driver`

### Java

```xml
<dependency>
    <groupId>org.neo4j.driver</groupId>
    <artifactId>neo4j-java-driver</artifactId>
    <version>5.26.0</version>
</dependency>
```

```java
import org.neo4j.driver.*;

try (Driver driver = GraphDatabase.driver(
        "neo4j+ssc://192.168.178.87:7687",
        AuthTokens.basic("neo4j", "<PASSWORD>"))) {
    driver.verifyConnectivity();
    try (Session session = driver.session()) {
        Result result = session.run("MATCH (n) RETURN count(n) AS nodes");
        System.out.println(result.single().get("nodes").asLong());
    }
}
```

---

## 4. Change the Admin Password

```cypher
-- In Browser or cypher-shell:
ALTER CURRENT USER SET PASSWORD FROM '<OLD>' TO '<NEW>';
```

> Password must be at least 8 chars. To enforce stricter rules, set environment
> variable `NEO4J_dbms_security_auth__minimum__password__length` in compose.

To create additional users:

```cypher
CREATE USER alice SET PASSWORD 'TempPw123!' CHANGE REQUIRED;
GRANT ROLE reader TO alice;
```

---

## 5. Loading Data

### Import from CSV

Place files in `/import` inside the container (volume `neo4j-import`):

```bash
# From the PVE host, copy a CSV into the LXC
scp users.csv root@192.168.178.87:/tmp/
pct exec 107 -- docker cp /tmp/users.csv neo4j:/import/users.csv
```

Then in Cypher:

```cypher
LOAD CSV WITH HEADERS FROM 'file:///users.csv' AS row
CREATE (:User {id: row.id, name: row.name, email: row.email});
```

### Import from URL

```cypher
LOAD CSV WITH HEADERS FROM 'https://example.com/data.csv' AS row
CREATE (:Product {sku: row.sku, name: row.name});
```

---

## 6. Backup & Restore

### Manual backup

```bash
ssh root@192.168.178.108 'pct exec 107 -- neo4j-backup'
```

This:
1. Stops Neo4j (~5 seconds downtime)
2. Runs `neo4j-admin database dump`
3. Restarts Neo4j
4. Writes to BOTH local (`/var/lib/neo4j-backups/`) AND NAS (`\\brain\backups\proxmox\neo4j\`)
5. Rotates: keeps 7 local + 30 NAS dumps

### Automatic backups

Daily at **03:00**, configured in `/etc/cron.d/neo4j-backup` inside LXC 107.
Logs: `/var/log/neo4j-backup.log` inside LXC.

### Restore

```bash
pct enter 107
cd /opt/neo4j

# Stop Neo4j
docker compose stop neo4j

# Load a specific dump (replace the filename)
docker compose run --rm \
    -v neo4j_neo4j-data:/data \
    -v /backups:/backups \
    --entrypoint "" \
    neo4j \
    neo4j-admin database load neo4j \
        --from-path=/backups \
        --overwrite-destination=true

# OR from a specific named file (rename it first):
# mv /var/lib/neo4j-backups/neo4j-20260520-072222.dump /var/lib/neo4j-backups/neo4j.dump
# (Neo4j 5 load expects 'neo4j.dump' by default)

# Restart
docker compose start neo4j
```

---

## 7. Stop / Start / Restart

```bash
ssh root@192.168.178.108

# Status
pct status 107
pct exec 107 -- docker ps

# Stop the whole LXC (Neo4j + Caddy)
pct stop 107

# Start
pct start 107

# Restart just Neo4j (without restarting the LXC)
pct exec 107 -- docker compose -f /opt/neo4j/docker-compose.yml restart neo4j

# View logs
pct exec 107 -- docker logs -f neo4j
```

---

## 8. Troubleshooting

### "Failed to fetch" / "Unable to connect" in Browser

The most common cause is **mixed content blocking** — your browser is on
HTTPS but the connect URL is plain `bolt://`. Use a TLS scheme:

✅ `neo4j+s://192.168.178.87:7687`
✅ `bolt+ssc://192.168.178.87:7687` (if the cert is rejected)
❌ `bolt://192.168.178.87:7687` (blocked from HTTPS pages)

### Certificate warning won't go away

The self-signed cert is valid for 10 years; you only need to accept it
once per browser. If it keeps prompting, you may have cleared cookies/cache.

To install the cert system-wide (no more warnings):
```bash
ssh root@192.168.178.108 'pct exec 107 -- cat /opt/neo4j/certs/cert.pem' > neo4j-cert.pem
# Then import into your OS trust store
# Windows: certutil -addstore -f "ROOT" neo4j-cert.pem
# macOS:   security add-trusted-cert -d -r trustRoot -k ~/Library/Keychains/login.keychain neo4j-cert.pem
# Linux:   sudo cp neo4j-cert.pem /usr/local/share/ca-certificates/neo4j.crt && sudo update-ca-certificates
```

### Connection times out

Check firewall:
```bash
ssh root@192.168.178.108 'nc -zv 192.168.178.87 7687 && nc -zv 192.168.178.87 7473'
```

If timeout: verify LXC is running (`pct status 107`) and firewall enables port (`cat /etc/pve/firewall/107.fw`).

### Forgot password

The admin password is stored hashed in `/data/dbms/auth` inside the container.
You can reset it (requires container restart with override):

```bash
pct enter 107
cd /opt/neo4j
docker compose stop neo4j
docker compose run --rm --entrypoint "" neo4j \
    neo4j-admin dbms set-initial-password 'NewStrongPw1!'
docker compose start neo4j
```

---

## 9. Resource Status

```bash
# Memory inside LXC
pct exec 107 -- free -h | head -2

# Container memory
pct exec 107 -- docker stats --no-stream

# Disk usage
pct exec 107 -- df -h /

# Database file sizes
pct exec 107 -- docker exec neo4j du -sh /data/databases/neo4j
```

Default budget (2 GB LXC):
- Neo4j: 512 MB heap + 512 MB pagecache
- Caddy + OS: ~500 MB
- Headroom: ~500 MB

---

## 10. Further Reading

- **Cypher reference**: https://neo4j.com/docs/cypher-manual/current/
- **Driver docs**: https://neo4j.com/docs/getting-started/languages-guides/
- **Operations manual**: https://neo4j.com/docs/operations-manual/5/
- **Browser shortcuts**: type `:help` in the Browser

---

# Part 2 — API Access for LLMs / Scripts / Automation

> This section is the **starter kit** for non-interactive consumers: Python
> scripts, LLM sessions, automation jobs, MCP servers, etc.

## 11. Purpose of This Database

This Neo4j instance is intended (among other uses) as a **smart-home
dependency graph**. The goal is to model "what depends on what" across:

- **Network layer**: IP addresses, MAC addresses, VLANs, VNETs, IP tunnels, VPNs, routes
- **Bus protocols**: KNX physical addresses, KNX group addresses, Zigbee device IDs
- **Application layer**: Home Assistant entities, automations, dashboards, scripts
- **Physical layer**: rooms, hardware devices, sensors, actuators

So that questions like the following become single Cypher queries:

```cypher
// Which HA automations break if Zigbee device 0x00158d000abcdef1 is renamed/removed?
MATCH (z:ZigbeeDevice {ieee: '00:15:8d:00:0a:bc:de:f1'})
      <-[:EXPOSES*1..3]-(:HAEntity)<-[:USES]-(a:HAAutomation)
RETURN DISTINCT a.alias, a.id;

// What depends on VLAN 30 (IoT)?
MATCH (v:VLAN {id: 30})<-[:ON_VLAN]-(d) RETURN d.name, labels(d);

// Which devices share IP 192.168.178.84 over time?
MATCH (ip:IPAddress {value: '192.168.178.84'})<-[r:HAS_IP]-(d)
RETURN d.name, r.from, r.to ORDER BY r.from DESC;
```

When you build new automations, provision new devices, or rename anything,
you (or another LLM session) must **update this graph** so future
impact-analysis queries stay accurate.

## 12. Connection — Three Endpoints

| Endpoint | Port | Use Case |
|----------|------|----------|
| **Bolt (binary, fast)** | 7687 | Python/Node/Java drivers — preferred for apps |
| **HTTP REST API** | 7473 (HTTPS) / 7474 (HTTP) | Simple curl / scripts without driver |
| **Browser UI** | 7473 / 443 | Interactive query exploration |

### Bolt connect URLs

| Scheme | When |
|--------|------|
| `neo4j+s://192.168.178.87:7687` | Default — TLS, with cluster routing (works for single-instance too) |
| `bolt+s://192.168.178.87:7687` | Plain Bolt + TLS, no routing |
| `bolt+ssc://192.168.178.87:7687` | TLS + self-signed-cert tolerant — use if `+s` rejects the cert |
| `bolt://192.168.178.87:7687` | Plain Bolt, no TLS — only from CLI/scripts (browsers block from HTTPS) |

> Since our cert is self-signed, drivers usually need `+ssc` OR you must
> install the cert in the OS trust store. See Section 8.

## 13. Service Accounts (LLMs / Scripts / Automations)

### Pre-created service account: `llm_smarthome`

Already created for the smart-home dependency project:

| Field | Value |
|-------|-------|
| Username | `llm_smarthome` |
| Password | `SmartHomeGraph2026!LLM` |
| Scope | Full read+write on default database (Community Edition has no RBAC) |
| Purpose | Smart home dependency graph ingestion + queries |

### Important caveat — Community Edition has NO roles

`SHOW ROLES` returns "Unsupported administration command".
**Every created user has admin-level rights**, including:
- ✅ Read and write all data
- ✅ Create/drop indexes, constraints, labels
- ✅ Create/drop additional users (any account can escalate)
- ❌ Cannot be restricted to read-only or specific labels

If you need true RBAC (read-only, label-restricted, etc.), you need
**Neo4j Enterprise Edition** (paid).

### What you CAN do for least privilege in Community

1. **Separate accounts per consumer** — so you can rotate one without
   breaking everything, and so audit logs identify the source
2. **Strong, unique passwords** — generated, not memorized
3. **Network-level restriction** — already in place: LXC firewall only
   allows LAN sources
4. **Use a dedicated database name** if you want isolation, but Community
   limits you to one user database

### Create a new service account

```bash
# As admin (run from anywhere with cypher-shell or via SSH)
echo "CREATE USER my_service SET PASSWORD 'PickAStrongOne123!' CHANGE NOT REQUIRED;" \
    | ssh root@192.168.178.108 \
        'pct exec 107 -- docker exec -i neo4j cypher-shell \
           -a bolt://localhost:7687 -u neo4j -p "<ADMIN_PW>" -d system'
```

Or via the Browser: open `:server user add` and fill in the form.

### Rotate a password

```cypher
-- As admin, in the `system` database:
ALTER USER llm_smarthome SET PASSWORD 'NewStrongPw2026Xyz!';
```

### Remove an account

```cypher
DROP USER my_service;
```

## 14. Connection Examples

### Python (recommended for ingestion scripts and LLMs)

```bash
pip install neo4j
```

```python
from neo4j import GraphDatabase

# Connection
URI = "bolt+ssc://192.168.178.87:7687"   # self-signed cert tolerant
AUTH = ("llm_smarthome", "SmartHomeGraph2026!LLM")

driver = GraphDatabase.driver(URI, auth=AUTH)
driver.verify_connectivity()

# Read
with driver.session() as session:
    result = session.run("MATCH (n) RETURN count(n) AS count")
    print(f"Total nodes: {result.single()['count']}")

# Write (idempotent — use MERGE not CREATE)
with driver.session() as session:
    session.run("""
        MERGE (d:Device {id: $id})
        SET d.name = $name,
            d.lastSeen = datetime(),
            d.source = 'home_assistant_api'
    """, id="sensor.living_room_temperature", name="Living Room Temperature")

driver.close()
```

### Node.js / TypeScript

```bash
npm install neo4j-driver
```

```javascript
import neo4j from 'neo4j-driver';

const driver = neo4j.driver(
    'bolt+ssc://192.168.178.87:7687',
    neo4j.auth.basic('llm_smarthome', 'SmartHomeGraph2026!LLM')
);

const session = driver.session();
try {
    const result = await session.run(
        'MERGE (d:Device {id: $id}) SET d.name = $name RETURN d',
        { id: 'light.kitchen', name: 'Kitchen Light' }
    );
    console.log(result.records[0].get('d').properties);
} finally {
    await session.close();
    await driver.close();
}
```

### HTTP REST API (curl, no driver)

For one-off scripts or LLMs that don't want a Bolt driver:

```bash
# Read query
curl -ks -u 'llm_smarthome:SmartHomeGraph2026!LLM' \
    https://192.168.178.87:7473/db/neo4j/tx/commit \
    -H 'Content-Type: application/json' \
    -d '{"statements":[{"statement":"MATCH (n) RETURN count(n) AS count"}]}'

# Write query (MERGE)
curl -ks -u 'llm_smarthome:SmartHomeGraph2026!LLM' \
    https://192.168.178.87:7473/db/neo4j/tx/commit \
    -H 'Content-Type: application/json' \
    -d '{
      "statements": [{
        "statement": "MERGE (d:Device {id: $id}) SET d.name = $name RETURN d",
        "parameters": {"id": "switch.porch", "name": "Porch Switch"}
      }]
    }'
```

Response is JSON. The TX endpoint also supports multi-statement transactions
and explicit BEGIN/COMMIT/ROLLBACK (see Neo4j HTTP API docs).

### Bash one-liner via cypher-shell

```bash
echo 'MATCH (n) RETURN count(n);' \
    | ssh root@192.168.178.108 \
        'pct exec 107 -- docker exec -i neo4j cypher-shell \
           -a bolt://localhost:7687 -u llm_smarthome -p "SmartHomeGraph2026!LLM"'
```

## 15. Ingestion Patterns (Important!)

### ALWAYS use `MERGE`, not `CREATE`, for entities that may already exist

```cypher
-- ❌ BAD — duplicates on re-run
CREATE (d:Device {id: $id}) SET d.name = $name;

-- ✅ GOOD — idempotent, safe to re-ingest
MERGE (d:Device {id: $id})
ON CREATE SET d.createdAt = datetime(), d.source = $source
ON MATCH  SET d.lastSeen  = datetime()
SET d.name = $name;
```

### Batch ingestion via `UNWIND`

Far faster than one query per row:

```cypher
UNWIND $devices AS row
MERGE (d:Device {id: row.id})
SET d.name = row.name, d.type = row.type, d.lastSeen = datetime();
```

```python
devices = [
    {"id": "light.kitchen",   "name": "Kitchen Light",  "type": "light"},
    {"id": "sensor.outdoor",  "name": "Outdoor Temp",   "type": "sensor"},
    # … hundreds of rows …
]
session.run("UNWIND $devices AS row MERGE (d:Device {id: row.id}) "
            "SET d.name = row.name, d.type = row.type, d.lastSeen = datetime()",
            devices=devices)
```

### Always track provenance

Every node/relationship should carry:
- `source` — which system/script ingested it (`home_assistant`, `knx_etx_export`, `manual`, etc.)
- `createdAt` / `lastSeen` — for staleness detection
- Optional: `version` for schema migration

### Create indexes for the lookup columns

```cypher
CREATE INDEX device_id IF NOT EXISTS FOR (d:Device) ON (d.id);
CREATE INDEX ip_value  IF NOT EXISTS FOR (ip:IPAddress) ON (ip.value);
CREATE INDEX mac_value IF NOT EXISTS FOR (m:MACAddress) ON (m.value);
CREATE CONSTRAINT device_id_unique IF NOT EXISTS FOR (d:Device) REQUIRE d.id IS UNIQUE;
```

Without indexes, MERGE on a million-node graph becomes very slow.

## 16. Suggested Schema for the Smart-Home Graph

> This is a starting point — extend as needed. The schema should evolve
> with the domain.

### Node labels

| Label | Required properties | Optional |
|-------|---------------------|----------|
| `Device` | `id` (unique), `name`, `type` | `vendor`, `model`, `room` |
| `IPAddress` | `value` (unique) | `family` (ipv4/ipv6) |
| `MACAddress` | `value` (unique, normalised) | `vendor` (OUI lookup) |
| `VLAN` | `id` (unique), `name` | `purpose` |
| `VNet` | `id` (unique), `cidr` | `description` |
| `IPTunnel` / `VPN` | `id`, `protocol` (wireguard/openvpn/gre) | `endpoint` |
| `KNXPhysicalAddress` | `address` (`1.1.42`) | `device_type` |
| `KNXGroupAddress` | `address` (`5/0/15`), `name` | `dpt` |
| `ZigbeeDevice` | `ieee` (unique, 64-bit hex), `nwk` | `vendor`, `model` |
| `HAEntity` | `entity_id` (unique, `light.kitchen`) | `state_class`, `device_class` |
| `HAAutomation` | `id` (unique), `alias` | `mode`, `triggers` |
| `HAScript` | `id`, `alias` | |
| `Room` | `name` (unique) | `floor` |

### Relationship types (verbs in PRESENT TENSE, ALL_CAPS)

| Type | From → To | Meaning |
|------|-----------|---------|
| `HAS_IP` | Device → IPAddress | Current IP binding; carry `from`/`to` for history |
| `HAS_MAC` | Device → MACAddress | Hardware address |
| `ON_VLAN` | Device → VLAN | Layer-2 membership |
| `IN_VNET` | Device → VNet | Layer-3 subnet |
| `ROUTES_VIA` | VNet → IPTunnel/VPN | Routing relationships |
| `LOCATED_IN` | Device → Room | Physical placement |
| `EXPOSES` | Device → HAEntity | A device exposes one or more HA entities |
| `CONFIGURED_BY` | HAEntity → HAAutomation | Entity used by automation |
| `TRIGGERS` | HAEntity → HAAutomation | Entity acts as a trigger |
| `KNX_ADDRESS` | Device → KNXPhysicalAddress | KNX physical binding |
| `KNX_GROUP` | Device → KNXGroupAddress | KNX group address subscription |
| `ZIGBEE_BINDING` | ZigbeeDevice → ZigbeeDevice | Direct binding |
| `DEPENDS_ON` | Anything → Anything | Generic dependency edge |
| `RENAMED_FROM` | Device → Device | History of renames (audit) |

### Example data point

```cypher
// Ingest a Home Assistant light entity that exposes a Zigbee bulb in the kitchen
MERGE (z:ZigbeeDevice {ieee: '00:15:8d:00:0a:bc:de:f1'})
SET z.vendor = 'IKEA', z.model = 'LED1623G12', z.lastSeen = datetime()

MERGE (h:HAEntity {entity_id: 'light.kitchen_ceiling'})
SET h.device_class = 'light', h.lastSeen = datetime()

MERGE (r:Room {name: 'Kitchen'})

MERGE (z)-[:LOCATED_IN]->(r)
MERGE (z)-[:EXPOSES]->(h)
```

### Impact query example

```cypher
// "If I rename this Zigbee device's HA entity, which automations break?"
MATCH (h:HAEntity {entity_id: 'light.kitchen_ceiling'})
      <-[:USES|TRIGGERS|CONFIGURED_BY]-(a:HAAutomation)
RETURN a.alias, a.id, collect(DISTINCT h.entity_id) AS used_entities
ORDER BY a.alias;
```

## 17. Starter Prompt for Another LLM Session

Copy-paste this into a new Copilot CLI / Claude / GPT session to bootstrap:

> ---
>
> **Context**: I have a Neo4j 5.26 LTS Community Edition graph database at
> `192.168.178.87:7687` (Bolt) and `192.168.178.87:7473` (HTTP/HTTPS),
> intended as a smart-home dependency graph. Read the user manual at
> `D:\src\c3bv\proxmox\USER-MANUAL-NEO4J.md` (sections 11–16 cover the
> intended use, API access, and suggested schema).
>
> **Service account for this project**:
> - Username: `llm_smarthome`
> - Password: `SmartHomeGraph2026!LLM`
> - Endpoint: `bolt+ssc://192.168.178.87:7687`
>
> **Constraints**:
> - Community Edition: every user has admin rights, no RBAC. Use the
>   dedicated `llm_smarthome` account, not the master `neo4j` admin.
> - Daily backups run at 03:00 (PVE local + NAS, see manual section 6).
> - Cert is self-signed. Use `bolt+ssc://` or install the root cert.
> - Always use `MERGE` (not `CREATE`) for entities to keep ingestion idempotent.
> - Tag every node/edge with `source` and `lastSeen` for provenance.
> - Use `UNWIND` for batch operations.
>
> **Task**: \<describe your specific ingestion/query task here\>
>
> ---

## 18. Health & Diagnostics

```cypher
-- Database size & node/relationship counts
CALL apoc.meta.stats() YIELD nodeCount, relCount, labelCount, relTypeCount;
-- (Note: APOC may not be installed; use built-ins instead:)
MATCH (n) RETURN count(n) AS nodes;
MATCH ()-[r]->() RETURN count(r) AS relationships;

-- Which labels exist?
CALL db.labels();

-- Which relationship types exist?
CALL db.relationshipTypes();

-- Indexes
SHOW INDEXES;

-- Constraints
SHOW CONSTRAINTS;

-- Current transactions (look for stuck ones)
SHOW TRANSACTIONS;
```

```bash
# Container-level metrics
ssh root@192.168.178.108 'pct exec 107 -- docker stats --no-stream neo4j'

# Disk usage of the graph data
ssh root@192.168.178.108 'pct exec 107 -- docker exec neo4j du -sh /data/databases/neo4j /data/transactions/neo4j'

# HTTP health probe (returns "pass" for healthy)
curl -ks https://192.168.178.87:7473/db/neo4j/cluster/available -u 'llm_smarthome:SmartHomeGraph2026!LLM'
```

