# Local PostgreSQL Primary with Aiven PostgreSQL Cloud Backup/Standby Plan

## 1. Objective

Run OpenEduCat/Odoo 18 with the live database on local PostgreSQL on the same server, while maintaining an Aiven PostgreSQL cloud database as a disaster-recovery backup or standby target.

The target architecture is:

```text
Users
  -> Odoo 18 / OpenEduCat server
      -> Local PostgreSQL primary database
          -> Backup and/or replication pipeline
              -> Aiven PostgreSQL cloud database
```

Odoo should not write to two PostgreSQL databases directly. Odoo should connect to one primary database at a time. Aiven should be used as a backup, restore target, or standby database until a controlled failover is needed.

## 4. Dual-Write Requirement

If the requirement is that both PostgreSQL databases must accept writes at the same time, that is an active-active dual-write design. For this Odoo codebase, that should be treated as a special-case architecture, not the default.

Reasons:

- Odoo is designed around one active database connection per running instance.
- PostgreSQL does not provide safe multi-master writes by default.
- Dual-write introduces conflict handling for inserts, updates, deletes, and retries.
- Odoo attachments live in the filestore, so database writes alone are incomplete.
- Module upgrades can change schema and break synchronization rules.

Practical options:

1. Recommended: one active write database, one synced standby database.
2. Possible but high risk: application-level dual-write with explicit conflict resolution.
3. Not recommended: two independent writable databases without a synchronization layer.

If you still want both systems to be writable, the implementation must define:

- which database is authoritative when conflicts happen
- how transaction ordering is preserved
- how deletions are reconciled
- how attachments and file uploads are mirrored
- how schema changes are propagated
- how failed writes are retried without duplication

For this project, the safer interpretation is:

- write locally first
- replicate to Aiven continuously or on schedule
- promote Aiven to writable only during failover

That avoids split-brain behavior while still protecting the data.

## 2. What This Plan Solves

- Reduces risk of data loss if the local server fails.
- Keeps the live application fast by using local PostgreSQL as the primary database.
- Adds a cloud recovery path through Aiven PostgreSQL.
- Creates a repeatable backup, restore, and failover process.
- Preserves Odoo compatibility by avoiding unsupported dual-write database behavior.

## 3. What This Plan Does Not Do

- It does not make Odoo use two active database engines.
- It does not make PostgreSQL and another database type work together.
- It does not implement automatic multi-master writes.
- It does not remove the need to back up the Odoo filestore.

Odoo uses PostgreSQL as its database engine. Multiple tenants are possible, but they are multiple PostgreSQL databases, not different database technologies.

## 5. Recommended Approach

Use a two-stage implementation:

1. **Stage 1: Scheduled cloud backup**

   Take scheduled backups from local PostgreSQL and restore or store them in Aiven/cloud storage. This is simpler, lower risk, and gives immediate disaster recovery.

2. **Stage 2: Aiven standby database**

   Add PostgreSQL logical replication from local PostgreSQL to Aiven after the basic backup and restore process has been proven.

The final target can be a near-real-time Aiven standby, but the first production milestone should be a reliable backup and restore pipeline.

## 6. Components

### 6.1 Local Production Server

The local server should run:

- Odoo 18
- OpenEduCat custom addons from this repository
- PostgreSQL primary database
- Odoo filestore
- Nginx or another reverse proxy
- backup scripts
- monitoring agent or cron-based health checks

### 6.2 Aiven PostgreSQL

Aiven should host:

- a PostgreSQL service matching the local PostgreSQL major version where possible
- a backup/standby database for OpenEduCat
- SSL-enforced database access
- restricted network access from approved server IPs
- a dedicated user for backup or replication tasks

### 6.3 Odoo Filestore

Odoo stores attachments and uploaded files outside PostgreSQL in the filestore. A database backup alone is not enough.

Common filestore location:

```text
~/.local/share/Odoo/filestore/<database_name>
```

The exact path depends on `data_dir` in `odoo.conf`.

The backup process must include:

- PostgreSQL database dump
- Odoo filestore
- Odoo config file
- custom addons repo or release artifact
- restore instructions

## 7. Deployment Configuration

### 7.1 Normal Local Production Configuration

In normal operation, Odoo should connect to local PostgreSQL.

Example `odoo.conf`:

```ini
[options]
addons_path = /opt/odoo/odoo/addons,/opt/odoo/custom-addons/openeducat_erp
data_dir = /var/lib/odoo

db_host = localhost
db_port = 5432
db_user = odoo
db_password = CHANGE_ME

proxy_mode = True
workers = 4
max_cron_threads = 2
```

### 7.2 Emergency Aiven Failover Configuration

During failover, Odoo can be pointed to Aiven PostgreSQL.

Example failover `odoo.conf` database section:

```ini
db_host = <aiven-postgresql-host>
db_port = <aiven-postgresql-port>
db_user = <aiven-user>
db_password = <aiven-password>
db_sslmode = require
```

Only switch to this after confirming the Aiven database and filestore are in a usable state.

## 8. Stage 1: Scheduled Cloud Backup

### 8.1 Goal

Create a reliable recovery copy of local PostgreSQL and the Odoo filestore.

### 8.2 Backup Frequency

Recommended minimum:

- database backup every night
- filestore backup every night
- before every Odoo module upgrade
- before every production deployment
- before large imports or bulk operations

Recommended retention:

- 7 daily backups
- 4 weekly backups
- 3 monthly backups

### 8.3 PostgreSQL Backup Command

Use custom-format PostgreSQL dumps because they restore better with `pg_restore`.

Example:

```bash
pg_dump \
  --host=localhost \
  --port=5432 \
  --username=odoo \
  --format=custom \
  --blobs \
  --file=/var/backups/odoo/openeducat_$(date +%F_%H-%M).dump \
  openeducat_prod
```

### 8.4 Filestore Backup Command

Example:

```bash
tar -czf /var/backups/odoo/openeducat_filestore_$(date +%F_%H-%M).tar.gz \
  /var/lib/odoo/filestore/openeducat_prod
```

### 8.5 Upload or Restore to Aiven

There are two acceptable Stage 1 patterns.

Pattern A: Store backup files in cloud storage:

```text
Local PostgreSQL
  -> pg_dump file
  -> encrypted/compressed backup
  -> cloud storage
```

Pattern B: Restore latest backup into Aiven:

```text
Local PostgreSQL
  -> pg_dump file
  -> pg_restore into Aiven backup database
```

Pattern B gives faster failover testing because the Aiven database is already restored.

Example restore to Aiven:

```bash
pg_restore \
  --host=<aiven-host> \
  --port=<aiven-port> \
  --username=<aiven-user> \
  --dbname=openeducat_backup \
  --clean \
  --if-exists \
  --no-owner \
  --no-privileges \
  /var/backups/odoo/latest.dump
```

Use SSL for Aiven connections. Aiven connection strings usually include SSL requirements.

### 8.6 Stage 1 Acceptance Checklist

- A full database dump completes successfully.
- A full filestore backup completes successfully.
- Backups are stored outside the local server.
- Latest backup can be restored into Aiven or a test PostgreSQL instance.
- Odoo can start against the restored database in a test environment.
- Attachments work after restoring the filestore.
- A restore test is documented.

## 9. Stage 2: Aiven Standby with Logical Replication

### 9.1 Goal

Keep Aiven PostgreSQL near real time with the local PostgreSQL primary database.

This is more complex than scheduled dumps because Odoo upgrades can change schemas. Logical replication should be implemented only after Stage 1 is stable.

### 9.2 Local PostgreSQL Requirements

Local PostgreSQL must support logical replication.

Required settings in `postgresql.conf`:

```conf
wal_level = logical
max_replication_slots = 10
max_wal_senders = 10
```

After changing these settings, PostgreSQL must be restarted.

### 9.3 Create Replication User

Example:

```sql
CREATE USER aiven_repl WITH PASSWORD 'CHANGE_ME' REPLICATION LOGIN;
GRANT CONNECT ON DATABASE openeducat_prod TO aiven_repl;
```

Depending on PostgreSQL version and table ownership, additional grants may be needed.

### 9.4 Create Publication on Local PostgreSQL

Example:

```sql
\c openeducat_prod

CREATE PUBLICATION openeducat_pub FOR ALL TABLES;
```

For a large production database, a table-specific publication may be safer, but it requires more maintenance when Odoo creates new tables.

### 9.5 Create Subscription on Aiven

Example direction:

```sql
CREATE SUBSCRIPTION openeducat_sub
CONNECTION 'host=<local-db-public-or-private-host> port=5432 dbname=openeducat_prod user=aiven_repl password=CHANGE_ME sslmode=require'
PUBLICATION openeducat_pub
WITH (copy_data = true);
```

The exact command depends on network access, SSL setup, Aiven permissions, and whether the local database is reachable from Aiven.

### 9.6 Network Requirements

Choose one secure connectivity pattern:

- Aiven can connect to local PostgreSQL through a restricted public IP and firewall rule.
- A VPN/private network connects Aiven and the local server.
- A migration/replication tool runs from a controlled worker that can reach both databases.

Do not expose local PostgreSQL broadly to the internet.

Minimum firewall rule:

```text
Allow PostgreSQL port 5432 only from Aiven-required source addresses or a secure private network.
```

### 9.7 Replication Monitoring

Monitor on the local primary:

```sql
SELECT * FROM pg_stat_replication;
```

Monitor on the standby/subscriber:

```sql
SELECT * FROM pg_stat_subscription;
```

Track:

- replication lag
- failed subscription workers
- slot retention and WAL growth
- table sync status
- disk growth on both sides

### 9.8 Stage 2 Acceptance Checklist

- Initial copy from local PostgreSQL to Aiven completes.
- New records created in Odoo appear in Aiven.
- Updates and deletes replicate.
- Replication lag is monitored.
- Odoo module upgrade process is tested.
- A recovery drill confirms Aiven can run Odoo after filestore restore.

## 10. Odoo Module Upgrade Rules

Odoo module upgrades can change tables and columns. This matters for replication.

Before upgrading modules:

- take a full database backup
- take a full filestore backup
- confirm replication is healthy
- record current Odoo and module versions

During upgrade:

- monitor PostgreSQL errors
- monitor replication lag
- avoid additional manual schema changes

After upgrade:

- check that new tables exist on Aiven
- refresh publication if needed
- verify subscription status
- run Odoo smoke tests

If replication breaks after a major schema change, the safest recovery may be:

1. disable the subscription
2. take a fresh backup from local PostgreSQL
3. restore into Aiven
4. recreate publication/subscription

## 11. Failover Plan

### 11.1 When to Fail Over

Fail over only when:

- local PostgreSQL is down and cannot be restored quickly
- local server storage is corrupted
- local server is unavailable
- disaster recovery is required

Avoid failover for minor local issues that can be fixed quickly.

### 11.2 Manual Failover Steps

1. Stop Odoo on the local server.
2. Confirm the latest usable Aiven database state.
3. Confirm the latest usable filestore backup.
4. Restore filestore to the recovery server.
5. Update `odoo.conf` to point to Aiven PostgreSQL.
6. Start Odoo.
7. Test login.
8. Test student records.
9. Test admissions.
10. Test fees/invoices.
11. Test attachments and uploaded files.
12. Test reports.
13. Update DNS or reverse proxy if the application server changed.

### 11.3 Failback Plan

After running from Aiven, do not simply point Odoo back to the old local database. The local database will be stale.

Failback options:

1. Keep Aiven as the new primary database.
2. Rebuild local PostgreSQL from Aiven backup.
3. Recreate local primary and restore from the latest Aiven dump.
4. Reconfigure replication in the new direction if needed.

## 12. Backup Security

Required controls:

- encrypt backup files before storing them outside the server
- restrict access to backup directories
- use dedicated database users
- rotate credentials
- require SSL for Aiven PostgreSQL
- do not commit database passwords to Git
- store secrets in environment variables or a secrets manager

Recommended file permissions:

```bash
chmod 700 /var/backups/odoo
chmod 600 /etc/odoo/odoo.conf
```

## 13. Monitoring and Alerts

Minimum alerts:

- no successful database backup in 24 hours
- no successful filestore backup in 24 hours
- Aiven restore job failed
- replication lag above threshold
- local PostgreSQL unavailable
- local disk usage above 80%
- Aiven disk usage above 80%
- WAL directory growing unexpectedly
- failed Odoo database connection

Suggested thresholds:

- warning: replication lag above 5 minutes
- critical: replication lag above 30 minutes
- warning: disk usage above 80%
- critical: disk usage above 90%

## 14. Restore Testing

Backups are not complete until restore is tested.

Monthly restore drill:

1. Create a temporary test database.
2. Restore latest database backup.
3. Restore matching filestore.
4. Start Odoo against the restored database.
5. Login as admin.
6. Open student, admission, fees, and report screens.
7. Open an attachment.
8. Record restore time and issues.

Target recovery metrics:

- RPO for Stage 1: up to 24 hours, depending on backup frequency
- RPO for Stage 2: minutes, depending on replication lag
- RTO for Stage 1: time to restore dump and filestore
- RTO for Stage 2: time to switch Odoo config and restore filestore

## 15. Multi-Tenant Consideration

If this Odoo server hosts multiple school databases, repeat the backup/replication plan per database.

Example:

```text
openeducat_school_1
openeducat_school_2
openeducat_school_3
```

Each tenant database needs:

- its own PostgreSQL backup
- its own filestore backup
- restore testing
- replication coverage if Stage 2 is used

The filestore path is database-specific:

```text
/var/lib/odoo/filestore/openeducat_school_1
/var/lib/odoo/filestore/openeducat_school_2
```

## 16. Implementation Timeline

### 16.1 Milestone 1: Discovery

- identify current PostgreSQL version
- identify Odoo database name
- identify `odoo.conf`
- identify `data_dir`
- identify filestore path
- measure database size
- measure filestore size
- confirm server operating system

### 16.2 Milestone 2: Aiven Setup

- create Aiven PostgreSQL service
- create database
- create backup/replication user
- configure SSL
- restrict network access
- test `psql` connection from the local server

### 16.3 Milestone 3: Backup Automation

- create database backup script
- create filestore backup script
- schedule backups with cron/systemd timer
- send logs to a known location
- add success/failure alerting
- store backups outside the local server

### 16.4 Milestone 4: Restore Validation

- restore latest database backup into Aiven or test PostgreSQL
- restore matching filestore into test Odoo environment
- run smoke tests
- document restore time

### 16.5 Milestone 5: Logical Replication

- enable logical replication on local PostgreSQL
- create replication user
- create publication
- create Aiven subscription or use a controlled migration/replication process
- monitor sync status
- test schema changes from Odoo module updates

### 16.6 Milestone 6: Failover Drill

- stop test Odoo instance
- point test Odoo to Aiven
- restore filestore
- start Odoo
- run smoke tests
- document exact failover commands

## 17. Open Questions Before Implementation

- What is the production database name?
- What PostgreSQL version is running locally?
- Where is `odoo.conf` located?
- What is the current Odoo `data_dir`?
- How large is the PostgreSQL database?
- How large is the Odoo filestore?
- Is this for one school database or multiple tenant databases?
- Should Aiven be only backup storage, a restored standby, or a near-real-time logical replica?
- What recovery point objective is acceptable: 24 hours, 1 hour, or near real time?
- What recovery time objective is acceptable: minutes or hours?

## 18. Final Recommended Production Setup

Start with this:

```text
Odoo 18
  -> Local PostgreSQL primary
  -> nightly pg_dump backup
  -> nightly filestore backup
  -> off-server storage
  -> scheduled restore validation into Aiven/test DB
```

Then upgrade to this:

```text
Odoo 18
  -> Local PostgreSQL primary
  -> Aiven PostgreSQL logical standby
  -> separate filestore backup
  -> documented manual failover
```

The most important rule is that Odoo should have one active database target at a time. Aiven should be treated as disaster recovery until a planned failover happens.
