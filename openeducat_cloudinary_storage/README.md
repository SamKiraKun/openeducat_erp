# OpenEduCat Cloudinary Storage

This addon moves Odoo/OpenEduCat runtime attachments to Cloudinary while
keeping attachment metadata and access control in Odoo/PostgreSQL.

## What It Covers

- image and binary attachments handled through `ir.attachment`
- standard Odoo image widgets and attachment downloads
- report image reads that go through attachment storage
- Cloudinary-backed reads through the normal Odoo attachment layer
- 15-day retained remote deletion queue
- staged migration and rollback helpers

Committed module `static/` assets are still served from the addons repository.
This addon targets runtime uploads first.

## Installation

1. Install the Python dependency on the Odoo server:

```bash
pip install cloudinary
```

2. Add `openeducat_cloudinary_storage` to the Odoo addons path.
3. Install the module from Apps or with an Odoo module upgrade.

## Required Settings

Configure these values in Odoo Settings:

- Cloudinary enabled
- cloud name
- API key
- API secret
- folder prefix
- environment name
- school code
- delivery mode
- max upload size
- delete retention days

Recommended defaults for this repo:

- delivery mode: `authenticated`
- max upload size: `8`
- delete retention days: `15`

## Migration

Dry run:

```bash
ops/database_dr/bin/migrate_cloudinary_attachments.sh --dry-run
```

Migrate the first 100 attachments:

```bash
ops/database_dr/bin/migrate_cloudinary_attachments.sh --limit 100
```

Retry only failed rows:

```bash
ops/database_dr/bin/migrate_cloudinary_attachments.sh --retry-failed --limit 100
```

Rollback a batch back to local Odoo storage:

```bash
ops/database_dr/bin/migrate_cloudinary_attachments.sh --reverse --limit 100
```

## Notes

- When a sync succeeds, the attachment row keeps Cloudinary metadata and the
  `store_fname` becomes a Cloudinary marker.
- Normal Odoo attachment routes keep working because reads are proxied through
  `ir.attachment._file_read`.
- If Cloudinary is temporarily unavailable during rollback, the attachment
  stays marked remote-backed and the failure is recorded on the row.
