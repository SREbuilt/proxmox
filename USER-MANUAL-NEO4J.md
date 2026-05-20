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
