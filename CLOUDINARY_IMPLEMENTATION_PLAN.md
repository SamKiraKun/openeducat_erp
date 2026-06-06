# Cloudinary Images and Files Implementation Plan

## Implementation Status

Repo-side implementation status as of June 4, 2026:

- Milestone 1 decisions are captured in section 16 and reflected in code
- Milestone 2 is implemented in `openeducat_cloudinary_storage/`
- Milestone 3 is implemented for new uploads plus Odoo-proxied reads through
  the attachment layer
- Milestone 4 is implemented with migration and reverse-migration helpers in
  `ops/database_dr/bin/migrate_cloudinary_attachments.sh`
- Milestone 6 repo artifacts are implemented in `ops/database_dr/`

Still requiring live infrastructure execution:

- install the `cloudinary` Python package on the real Odoo host
- configure the real Cloudinary credentials and school code
- run staged migration batches against the actual Odoo database
- run manual smoke tests and restore/failover drills in the target environment
- decide whether committed module `static/` assets should be moved to a separate
  Cloudinary/CDN phase after runtime media rollout

## 1. Objective

Move runtime images and uploaded files for OpenEduCat/Odoo to Cloudinary, while
keeping PostgreSQL as the source of record for business data and Cloudinary
asset metadata.

Target architecture:

```text
Odoo / OpenEduCat
  -> PostgreSQL: records, attachment metadata, Cloudinary public IDs
  -> Cloudinary: uploaded image and file bytes
  -> Local filestore: temporary fallback during migration only
```

The goal is not to move committed module assets first. The first production
target is user/runtime media:

- student and faculty profile images
- admission applicant images
- program images
- company logos/signatures where stored as Odoo binary fields
- chatter attachments and any standard `ir.attachment` uploads
- uploaded PDFs, documents, spreadsheets, and other raw files

## 2. Repo Findings

The repo currently has three media categories.

### 2.1 Committed Static Assets

Most images are committed inside module `static/` directories. Examples:

- `theme_web_openeducat/static/src/img/banner/*`
- `openeducat_core/static/img/student_*.jpg`
- `openeducat_core/static/description/*`
- module icons referenced through `web_icon`
- module screenshots declared in `__manifest__.py`

These are served by Odoo from the deployed addons directory. They are not user
uploads and do not need Cloudinary in the first phase.

### 2.2 Odoo Image and Binary Fields

The repo uses Odoo image/binary fields and Odoo's standard rendering helpers:

- `op.program.image_1920 = fields.Image('Image', attachment=True)`
- `op.admission.image = fields.Image('image')`
- `res.company.signature = fields.Binary('Signature')`
- `op.student` and `op.faculty` inherit `res.partner`, so their profile images
  come through partner image fields such as `image_1920`
- views render images with `widget="image"`
- reports render images with `image_data_uri(...)`
- activity views render with `activity_image(...)`

These should be handled through the standard Odoo attachment layer instead of
rewriting every OpenEduCat model and report.

### 2.3 Import Templates and Other Static Files

Files such as `static/xls/op_student.xls`, `static/xls/op_faculty.xls`, and
`static/xls/op_admission.xls` are shipped as import templates and returned by
`get_import_templates()`.

These should stay in the repo unless there is a separate CDN requirement for
public static downloads.

## 3. Recommended Approach

Create a new custom addon:

```text
openeducat_cloudinary_storage/
```

This addon should integrate Cloudinary at the Odoo attachment layer by extending
`ir.attachment`. That gives the broadest coverage with the smallest change
surface because most Odoo binary/image uploads eventually pass through
`ir.attachment` or Odoo binary field handling.

Do not edit every student, faculty, admission, report, and view template unless
testing proves a specific binary field bypasses `ir.attachment`.

## 4. Non-Goals

- Do not store Cloudinary API secrets in Git.
- Do not make Cloudinary the source of truth for Odoo business records.
- Do not migrate committed module screenshots/icons/theme images in phase 1.
- Do not remove local filestore backups until migration and restore drills pass.
- Do not expose private school documents through public unauthenticated URLs.

## 5. Data Model Changes

Extend `ir.attachment` with Cloudinary metadata fields:

```text
cloudinary_public_id
cloudinary_version
cloudinary_resource_type
cloudinary_type
cloudinary_secure_url
cloudinary_format
cloudinary_bytes
cloudinary_etag
cloudinary_migrated
cloudinary_deleted
cloudinary_last_sync_at
```

Recommended behavior:

- PostgreSQL keeps attachment metadata and model relationships.
- Cloudinary stores the file bytes.
- Existing Odoo `checksum`, `mimetype`, `name`, `res_model`, `res_id`, and
  access control fields remain authoritative for Odoo behavior.
- Store only stable Cloudinary identifiers in PostgreSQL; avoid depending on
  generated transformation URLs as the only pointer.

## 6. Configuration

Use Odoo system parameters or environment variables:

```text
cloudinary.cloud_name
cloudinary.api_key
cloudinary.api_secret
cloudinary.folder_prefix
cloudinary.enabled
cloudinary.upload_images
cloudinary.upload_raw_files
cloudinary.delete_remote_on_unlink
cloudinary.delivery_mode
cloudinary.max_upload_mb
```

Suggested deployment values:

```text
cloudinary.enabled = False initially
cloudinary.folder_prefix = openeducat/<database_name>/<environment>
cloudinary.upload_images = True
cloudinary.upload_raw_files = True
cloudinary.delete_remote_on_unlink = False initially
cloudinary.delivery_mode = authenticated for private school files
```

Secrets should be provided through the production secret manager or an
environment file readable only by the Odoo service user.

## 7. Upload and Read Strategy

### 7.1 Upload

Override the attachment write path in `ir.attachment`:

1. Detect attachments that contain binary data.
2. Decide Cloudinary `resource_type`:
   - `image` for image MIME types
   - `raw` or `auto` for PDFs, spreadsheets, documents, and other files
3. Upload bytes to Cloudinary.
4. Store Cloudinary metadata on the `ir.attachment` row.
5. Clear or avoid writing large binary payloads to the local filestore after the
   remote upload succeeds.

### 7.2 Read

Support two read modes:

1. Proxy mode:
   - Odoo reads from Cloudinary and streams the bytes through existing Odoo
     attachment routes.
   - Best compatibility for access control, reports, and private documents.
2. Redirect/signed URL mode:
   - Odoo redirects to signed Cloudinary delivery URLs for eligible assets.
   - Best performance for public or low-risk image delivery.

Start with proxy mode for correctness. Add redirect/signed URL mode only after
access control tests pass.

### 7.3 Delete

Initial production behavior should be conservative:

- deleting an Odoo attachment marks local metadata as deleted
- do not immediately delete the Cloudinary asset until retention policy is
  confirmed
- add a scheduled cleanup job for remote deletions after a grace period

## 8. Security and Privacy

School media can include student photos, identity documents, fee documents, and
private reports. Treat all runtime uploads as private by default.

Required controls:

- use Cloudinary authenticated/private delivery for non-public files
- generate signed URLs only server-side
- keep Cloudinary credentials out of Git
- restrict admin access to Cloudinary dashboard
- include folder/database/environment separation
- log asset IDs, not full secrets or signed URLs
- document retention and deletion policy

Public delivery can be considered only for deliberate public website assets.

## 9. Migration Plan

### 9.1 Discovery

Run SQL/Odoo discovery to count current attachments:

```sql
SELECT mimetype, COUNT(*), SUM(file_size)
FROM ir_attachment
GROUP BY mimetype
ORDER BY COUNT(*) DESC;
```

Also identify whether large binaries are in database columns or filestore:

```sql
SELECT COUNT(*) FILTER (WHERE db_datas IS NOT NULL) AS db_backed,
       COUNT(*) FILTER (WHERE store_fname IS NOT NULL) AS filestore_backed
FROM ir_attachment;
```

### 9.2 Dry Run

Create a migration command:

```bash
odoo-bin shell -d <db> -c <odoo.conf> \
  --load=web \
  -m openeducat_cloudinary_storage
```

The command should support:

```text
--dry-run
--limit
--model
--mimetype
--since-id
--retry-failed
```

### 9.3 Migration Execution

1. Take PostgreSQL and filestore backups.
2. Enable Cloudinary addon with `cloudinary.enabled = False`.
3. Run dry-run migration and record counts.
4. Migrate a small batch of image attachments.
5. Verify student/faculty/admission image display.
6. Migrate raw file attachments.
7. Run report generation smoke tests.
8. Enable new writes to Cloudinary.
9. Keep local filestore for rollback until two successful restore drills pass.

## 10. Code Work Items

### 10.1 New Addon Skeleton

Create:

```text
openeducat_cloudinary_storage/
  __init__.py
  __manifest__.py
  models/
    __init__.py
    ir_attachment.py
    res_config_settings.py
  data/
    ir_cron.xml
  security/
    ir.model.access.csv
  tests/
    test_cloudinary_attachment.py
```

Dependencies:

```text
base
web
mail
```

External Python dependency:

```text
cloudinary
```

### 10.2 Attachment Service

Create a small internal service/helper for:

- upload bytes
- download bytes
- delete or soft-delete remote asset
- generate signed delivery URL
- normalize public IDs
- map MIME type to Cloudinary resource type
- handle retries and timeouts

Keep Cloudinary SDK usage behind this helper so tests can mock it cleanly.

### 10.3 Odoo Attachment Override

Extend `ir.attachment` to cover:

- create/write with `datas`
- binary content read
- unlink behavior
- metadata updates
- fallback to local filestore when Cloudinary is disabled

The override must preserve Odoo access checks. Do not bypass Odoo routes for
private content until signed URL access has been tested.

### 10.4 Admin Settings

Add settings under Odoo Settings:

- Cloudinary enabled
- cloud name
- API key
- folder prefix
- delivery mode
- upload images
- upload raw files
- delete remote on unlink
- max upload size

Do not display API secret in plain text after save.

### 10.5 Scheduled Jobs

Add crons for:

- retry failed Cloudinary uploads
- verify remote asset existence for recently uploaded attachments
- cleanup remote assets that passed deletion retention

## 11. Report and View Compatibility

The current repo uses standard image rendering:

- `widget="image"` in forms and kanban views
- `image_data_uri(...)` in reports
- `activity_image(...)` in activity views

These should keep working if reads are proxied through Odoo and return bytes.

Specific smoke tests:

- student form image
- faculty form image
- admission form image
- program image
- student ID card PDF
- library card PDF
- exam hall ticket PDF
- chatter attachment download
- import template download remains local/static

## 12. DR Plan Changes

Once Cloudinary owns runtime media, the database DR plan changes:

- PostgreSQL backup remains required for business data and Cloudinary metadata.
- Filestore backup remains required during migration and rollback windows.
- Long-term filestore backup can be downgraded only after all attachments are
  migrated and restore drills prove Cloudinary recovery.
- Cloudinary asset inventory export becomes part of the monthly restore drill.
- Failover must verify Cloudinary credentials and delivery access on the
  recovery Odoo server.

Update `ops/database_dr` after implementation:

- add Cloudinary environment keys to `.env.example`
- add `check_cloudinary_health.sh`
- add Cloudinary credential validation to restore drill
- add asset-count comparison between `ir_attachment` and Cloudinary search/API
- update failover runbook to include Cloudinary smoke tests

## 13. Testing Plan

### Unit Tests

- MIME type to Cloudinary resource type mapping
- public ID generation
- upload success metadata write
- upload failure leaves local fallback intact
- read fallback from local filestore when Cloudinary metadata is missing
- unlink behavior with remote deletion disabled/enabled

### Integration Tests

- create attachment with image bytes
- create attachment with PDF/raw bytes
- update existing attachment
- download attachment through Odoo route
- generate student ID card PDF with image
- generate hall ticket PDF with image

### Manual QA

- upload student photo
- upload faculty photo
- upload admission applicant photo
- upload a document in chatter
- download the document as a permitted user
- confirm unauthorized users cannot access the file
- restart Odoo and verify images still load
- run backup and restore drill against a test database

## 14. Rollback Plan

Keep local filestore fallback until production confidence is established.

Rollback options:

1. Disable `cloudinary.enabled` so new writes return to local/Odoo storage.
2. Keep existing Cloudinary metadata in PostgreSQL but read from local fallback
   where available.
3. If needed, run a reverse migration that downloads Cloudinary assets back into
   Odoo's local filestore.

Do not delete local filestore data until:

- all attachments have Cloudinary metadata
- reports and downloads pass smoke tests
- monthly restore drill passes
- reverse migration has been tested on a staging database

## 15. Implementation Milestones

### Milestone 1: Design Validation

- confirm Cloudinary account, plan, and allowed file types
- decide public/private/authenticated delivery policy
- decide retention policy for deleted assets
- confirm max upload sizes

### Milestone 2: Addon Foundation

- create `openeducat_cloudinary_storage`
- add config settings
- add Cloudinary helper service
- add attachment metadata fields

### Milestone 3: New Uploads

- route new image uploads to Cloudinary
- route new raw file uploads to Cloudinary
- keep reads proxied through Odoo
- add focused tests

### Milestone 4: Existing Attachment Migration

- add migration command
- run dry run
- migrate staging data
- validate forms, reports, and downloads

### Milestone 5: Production Rollout

- deploy addon disabled
- configure credentials
- run small production migration batch
- enable new writes
- monitor failures and latency

### Milestone 6: DR Integration

- update `ops/database_dr`
- add Cloudinary health checks
- update failover and restore drills
- decide when local filestore backups can be reduced

## 16. Open Questions

- Should all student/faculty photos be private/authenticated, or can profile
  images be public within signed URLs?

  ans: all student/faculty photos be private/authenticated


- What file types and maximum file sizes must be supported?

 ans: 8mb


- Do we need Cloudinary transformations for thumbnails, or should Odoo continue
  generating resized image variants?

  ans: Odoo continue
  generating resized image variants then upload on cloudinary


- Should delete in Odoo immediately delete the Cloudinary asset, or should there
  be a retention grace period?

ans: keep it on cloudinary for 15 days then delete

- Which environment naming convention should be used for Cloudinary folders:
  `prod`, `staging`, school code, database name, or all of them?

  ans: all of them

- Is Cloudinary intended only for runtime uploads, or also as CDN hosting for
  committed theme/static assets later?

  ans: i think we need cloudinary for all images/files tasks
