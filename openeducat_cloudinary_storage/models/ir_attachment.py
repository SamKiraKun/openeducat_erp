import base64
import logging

from odoo import api, fields, models

from ..services.cloudinary_service import CloudinaryService

_LOGGER = logging.getLogger(__name__)


class IrAttachment(models.Model):
    _inherit = 'ir.attachment'

    _cloudinary_store_prefix = 'cloudinary://'

    cloudinary_public_id = fields.Char(copy=False, index=True)
    cloudinary_version = fields.Char(copy=False)
    cloudinary_resource_type = fields.Char(copy=False)
    cloudinary_type = fields.Char(copy=False)
    cloudinary_secure_url = fields.Char(copy=False)
    cloudinary_format = fields.Char(copy=False)
    cloudinary_bytes = fields.Integer(copy=False)
    cloudinary_etag = fields.Char(copy=False)
    cloudinary_migrated = fields.Boolean(default=False, copy=False)
    cloudinary_deleted = fields.Boolean(default=False, copy=False)
    cloudinary_last_sync_at = fields.Datetime(copy=False)
    cloudinary_sync_state = fields.Selection(
        [
            ('disabled', 'Disabled'),
            ('synced', 'Synced'),
            ('failed', 'Failed'),
        ],
        default='disabled',
        copy=False,
        index=True,
    )
    cloudinary_last_error = fields.Text(copy=False)

    @api.model_create_multi
    def create(self, vals_list):
        attachments = super().create(vals_list)
        if self.env.context.get('skip_cloudinary_sync'):
            return attachments

        for attachment, vals in zip(attachments, vals_list):
            if attachment.type != 'binary':
                continue
            if any(key in vals for key in ('datas', 'db_datas', 'raw')):
                attachment._cloudinary_sync_attachment()
            else:
                attachment._cloudinary_update_sync_state('disabled')
        return attachments

    def write(self, vals):
        result = super().write(vals)
        if self.env.context.get('skip_cloudinary_sync'):
            return result

        if any(key in vals for key in ('datas', 'db_datas', 'raw')):
            self.filtered(lambda attachment: attachment.type == 'binary')._cloudinary_sync_attachment(
                force=True
            )
        elif 'type' in vals:
            self.filtered(lambda attachment: attachment.type == 'binary')._cloudinary_update_sync_state(
                'disabled'
            )
        return result

    def unlink(self):
        cloudinary_enabled = self._cloudinary_feature_enabled()
        delete_remote = self._cloudinary_delete_remote_on_unlink()

        if cloudinary_enabled and delete_remote:
            queue_model = self.env['openeducat.cloudinary.deletion.queue']
            for attachment in self.filtered('cloudinary_public_id'):
                try:
                    queue_model.create_from_attachment(attachment)
                except Exception as exc:  # pragma: no cover - defensive logging
                    _LOGGER.warning(
                        "Cloudinary delete queueing failed for attachment %s: %s",
                        attachment.id,
                        exc,
                    )

        return super().unlink()

    def action_cloudinary_resync(self):
        self._cloudinary_sync_attachment(force=True)
        return True

    def action_cloudinary_restore_local_storage(self):
        self._cloudinary_restore_local_storage()
        return True

    @api.model
    def _cron_cloudinary_retry_failed_uploads(self, limit=100):
        attachments = self.search(
            [
                ('type', '=', 'binary'),
                ('cloudinary_sync_state', '=', 'failed'),
            ],
            limit=limit,
            order='id',
        )
        attachments._cloudinary_sync_attachment(force=True)
        return True

    @api.model
    def _cron_cloudinary_verify_recent_uploads(self, limit=100):
        service = CloudinaryService(self.env)
        if not self._cloudinary_feature_enabled() or not service.is_available():
            return True

        attachments = self.search(
            [
                ('type', '=', 'binary'),
                ('cloudinary_sync_state', '=', 'synced'),
                ('cloudinary_public_id', '!=', False),
            ],
            limit=limit,
            order='cloudinary_last_sync_at desc, id desc',
        )

        for attachment in attachments:
            exists = service.asset_exists(attachment)
            if not exists:
                attachment.with_context(skip_cloudinary_sync=True).write({
                    'cloudinary_sync_state': 'failed',
                    'cloudinary_last_error': 'Remote Cloudinary asset could not be verified.',
                })
        return True

    @api.model
    def _cron_cloudinary_cleanup_due_assets(self, limit=100):
        self.env['openeducat.cloudinary.deletion.queue']._cron_cloudinary_cleanup_due_assets(
            limit=limit
        )
        return True

    @api.model
    def _cloudinary_migrate_existing_attachments(
        self,
        dry_run=False,
        limit=100,
        model=False,
        mimetype=False,
        since_id=False,
        retry_failed=False,
    ):
        domain = [('type', '=', 'binary')]

        if model:
            domain.append(('res_model', '=', model))

        if mimetype:
            operator = '=like' if '%' in mimetype or '*' in mimetype else '='
            domain.append(('mimetype', operator, mimetype.replace('*', '%')))

        if since_id:
            domain.append(('id', '>=', int(since_id)))

        if retry_failed:
            domain.append(('cloudinary_sync_state', '=', 'failed'))
        else:
            domain.extend([
                '|',
                ('cloudinary_public_id', '=', False),
                ('store_fname', 'not like', '%s%%' % self._cloudinary_store_prefix),
            ])

        total_count = self.search_count(domain)
        attachments = self.search(domain, limit=limit, order='id')
        summary = {
            'dry_run': bool(dry_run),
            'domain': domain,
            'matched_total': total_count,
            'selected_ids': attachments.ids,
            'selected_count': len(attachments),
            'synced': 0,
            'failed': 0,
            'disabled': 0,
        }

        if dry_run:
            return summary

        attachments._cloudinary_sync_attachment(force=True)
        for attachment in attachments:
            summary[attachment.cloudinary_sync_state] = (
                summary.get(attachment.cloudinary_sync_state, 0) + 1
            )
        return summary

    @api.model
    def _cloudinary_restore_remote_attachments(
        self,
        dry_run=False,
        limit=100,
        model=False,
        mimetype=False,
        since_id=False,
    ):
        domain = [
            ('type', '=', 'binary'),
            ('cloudinary_public_id', '!=', False),
            ('store_fname', '=like', '%s%%' % self._cloudinary_store_prefix),
        ]

        if model:
            domain.append(('res_model', '=', model))

        if mimetype:
            operator = '=like' if '%' in mimetype or '*' in mimetype else '='
            domain.append(('mimetype', operator, mimetype.replace('*', '%')))

        if since_id:
            domain.append(('id', '>=', int(since_id)))

        total_count = self.search_count(domain)
        attachments = self.search(domain, limit=limit, order='id')
        summary = {
            'dry_run': bool(dry_run),
            'domain': domain,
            'matched_total': total_count,
            'selected_ids': attachments.ids,
            'selected_count': len(attachments),
            'restored': 0,
            'failed': 0,
        }

        if dry_run:
            return summary

        for attachment in attachments:
            if attachment._cloudinary_restore_local_storage():
                summary['restored'] += 1
            else:
                summary['failed'] += 1
        return summary

    def _cloudinary_sync_attachment(self, force=False):
        service = CloudinaryService(self.env)
        enabled = self._cloudinary_feature_enabled()

        for attachment in self.filtered(lambda record: record.type == 'binary'):
            if not enabled:
                attachment._cloudinary_update_sync_state('disabled')
                continue
            if attachment.cloudinary_public_id and not force:
                continue

            result = service.upload_attachment(attachment)
            state = result.get('state', 'failed')

            if state == 'synced':
                attachment.with_context(skip_cloudinary_sync=True).write({
                    'cloudinary_public_id': result.get('public_id'),
                    'cloudinary_version': result.get('version'),
                    'cloudinary_resource_type': result.get('resource_type'),
                    'cloudinary_type': result.get('type'),
                    'cloudinary_secure_url': result.get('secure_url'),
                    'cloudinary_format': result.get('format'),
                    'cloudinary_bytes': result.get('bytes'),
                    'cloudinary_etag': result.get('etag'),
                    'cloudinary_migrated': True,
                    'cloudinary_deleted': False,
                    'cloudinary_last_sync_at': fields.Datetime.now(),
                    'cloudinary_sync_state': 'synced',
                    'cloudinary_last_error': False,
                })
                attachment._cloudinary_offload_local_storage()
            else:
                attachment.with_context(skip_cloudinary_sync=True).write({
                    'cloudinary_last_sync_at': fields.Datetime.now(),
                    'cloudinary_sync_state': state,
                    'cloudinary_last_error': result.get('error'),
                })
        return True

    def _cloudinary_update_sync_state(self, state, error=False):
        self.filtered(lambda attachment: attachment.type == 'binary').with_context(
            skip_cloudinary_sync=True
        ).write({
            'cloudinary_sync_state': state,
            'cloudinary_last_error': error or False,
        })
        return True

    @api.model
    def _cloudinary_feature_enabled(self):
        value = self.env['ir.config_parameter'].sudo().get_param(
            'cloudinary.enabled',
            default='False',
        )
        return str(value).lower() in ('1', 'true', 'yes', 'on')

    @api.model
    def _cloudinary_delete_remote_on_unlink(self):
        value = self.env['ir.config_parameter'].sudo().get_param(
            'cloudinary.delete_remote_on_unlink',
            default='True',
        )
        return str(value).lower() in ('1', 'true', 'yes', 'on')

    @api.model
    def _cloudinary_delete_retention_days(self):
        value = self.env['ir.config_parameter'].sudo().get_param(
            'cloudinary.delete_retention_days',
            default='15',
        )
        try:
            return int(value)
        except (TypeError, ValueError):
            return 15

    @api.model
    def _cloudinary_delivery_mode(self):
        value = self.env['ir.config_parameter'].sudo().get_param(
            'cloudinary.delivery_mode',
            default='authenticated',
        )
        return value or 'authenticated'

    @api.model
    def _file_read(self, fname, *args, **kwargs):
        if not self._cloudinary_is_store_fname(fname):
            return super()._file_read(fname, *args, **kwargs)

        attachment = self.sudo().search([('store_fname', '=', fname)], limit=1)
        if not attachment:
            return super()._file_read(fname, *args, **kwargs)

        bin_size = self._cloudinary_bin_size_requested(args=args, kwargs=kwargs)
        if bin_size:
            return self._cloudinary_human_size(attachment.cloudinary_bytes or 0)

        payload = CloudinaryService(self.env).download_attachment(attachment)
        if payload is False:
            _LOGGER.warning(
                "Cloudinary read failed for attachment %s with store_fname %s",
                attachment.id,
                fname,
            )
            return b''
        return base64.b64encode(payload)

    @api.model
    def _file_delete(self, fname, *args, **kwargs):
        if self._cloudinary_is_store_fname(fname):
            return True
        return super()._file_delete(fname, *args, **kwargs)

    def _cloudinary_offload_local_storage(self):
        for attachment in self.filtered(lambda record: record.type == 'binary'):
            if not attachment.cloudinary_public_id:
                continue

            new_store_fname = attachment._cloudinary_store_fname_value()
            old_store_fname = attachment.store_fname

            if old_store_fname == new_store_fname and not attachment.db_datas:
                continue

            attachment.with_context(skip_cloudinary_sync=True).write({
                'store_fname': new_store_fname,
                'db_datas': False,
                'file_size': attachment.cloudinary_bytes or attachment.file_size,
            })

            if old_store_fname and old_store_fname != new_store_fname:
                try:
                    super(IrAttachment, attachment)._file_delete(old_store_fname)
                except Exception as exc:  # pragma: no cover - defensive logging
                    _LOGGER.warning(
                        "Local filestore cleanup failed for attachment %s: %s",
                        attachment.id,
                        exc,
                    )
        return True

    def _cloudinary_restore_local_storage(self):
        service = CloudinaryService(self.env)

        for attachment in self.filtered(lambda record: record.type == 'binary'):
            payload = service.download_attachment(attachment)
            if payload is False:
                attachment.with_context(skip_cloudinary_sync=True).write({
                    'cloudinary_sync_state': 'failed',
                    'cloudinary_last_error': 'Unable to download payload from Cloudinary for rollback.',
                })
                return False

            attachment.with_context(
                skip_cloudinary_sync=True,
            ).write({
                'datas': base64.b64encode(payload).decode(),
                'cloudinary_last_error': False,
            })
        return True

    def _cloudinary_store_fname_value(self):
        self.ensure_one()
        return '%s%s' % (self._cloudinary_store_prefix, self.cloudinary_public_id)

    @api.model
    def _cloudinary_is_store_fname(self, fname):
        return bool(fname and str(fname).startswith(self._cloudinary_store_prefix))

    @api.model
    def _cloudinary_bin_size_requested(self, args=(), kwargs=None):
        kwargs = kwargs or {}
        if 'bin_size' in kwargs:
            return bool(kwargs['bin_size'])
        if args:
            return bool(args[0])
        return False

    @api.model
    def _cloudinary_human_size(self, size):
        size = int(size or 0)
        units = ['B', 'KB', 'MB', 'GB', 'TB']
        value = float(size)
        for unit in units:
            if value < 1024.0 or unit == units[-1]:
                if unit == 'B':
                    return '%d %s' % (int(value), unit)
                return '%.1f %s' % (value, unit)
            value /= 1024.0
