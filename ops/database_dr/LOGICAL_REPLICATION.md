# Logical Replication

This is the Stage 2 path from `DBplan.md`: local PostgreSQL remains the only
writer, Aiven becomes the near-real-time standby.

## Prerequisites

- Stage 1 backups and restore drills are already working
- local PostgreSQL has `wal_level=logical`, `max_replication_slots>=1`, and
  `max_wal_senders>=1`
- Aiven can reach the local PostgreSQL host over a restricted network path
- the matching filestore backup process remains in place

## Commands

Check prerequisites:

```bash
ops/database_dr/bin/setup_logical_replication.sh check-prereqs
```

Create the replication role and publications on the local primary:

```bash
ops/database_dr/bin/setup_logical_replication.sh apply-primary
```

Preview the subscriber SQL:

```bash
ops/database_dr/bin/setup_logical_replication.sh print-subscriber-sql
```

If the subscriber databases already exist and the local server can reach Aiven,
create subscriptions directly:

```bash
ops/database_dr/bin/setup_logical_replication.sh apply-subscriber
```

Verify the created objects:

```bash
ops/database_dr/bin/setup_logical_replication.sh verify
ops/database_dr/bin/check_replication_health.sh
```

## Notes

- one publication, subscription, and replication slot are created per Odoo
  database
- subscription database names are derived from the original Odoo database names
  plus `SUBSCRIBER_DB_PREFIX` / `SUBSCRIBER_DB_SUFFIX`
- Cloudinary-backed attachment bytes are not part of PostgreSQL replication;
  keep the Cloudinary credentials, health checks, and inventory comparison in
  place on both primary and failover hosts
- the replication role is granted `SELECT` on current tables and default
  privileges for the configured owner role
- after major schema changes, use the module-upgrade runbook rather than trying
  to improvise around a broken subscription
