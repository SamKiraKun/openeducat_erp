import logging

from dateutil.relativedelta import relativedelta

from odoo import api, fields, models

from ..services.cloudinary_service import CloudinaryService

_LOGGER = logging.getLogger(__name__)


class CloudinaryDeletionQueue(models.Model):
    _name = 'openeducat.cloudinary.deletion.queue'
    _description = 'Cloudinary Attachment Deletion Queue'
    _order = 'delete_after asc, id asc'

    attachment_name = fields.Char(required=True)
    source_attachment_id = fields.Integer(copy=False, index=True)
    cloudinary_public_id = fields.Char(required=True, index=True)
    cloudinary_resource_type = fields.Char(required=True)
    cloudinary_type = fields.Char(required=True)
    delete_after = fields.Datetime(required=True, index=True)
    state = fields.Selection(
        [
            ('pending', 'Pending'),
            ('deleted', 'Deleted'),
            ('failed', 'Failed'),
        ],
        default='pending',
        required=True,
        index=True,
    )
    attempt_count = fields.Integer(default=0)
    last_error = fields.Text(copy=False)
    processed_at = fields.Datetime(copy=False)

    @api.model
    def create_from_attachment(self, attachment):
        delete_after = fields.Datetime.now() + relativedelta(
            days=max(attachment._cloudinary_delete_retention_days(), 0)
        )
        return self.sudo().create({
            'attachment_name': attachment.name or 'attachment_%s' % attachment.id,
            'source_attachment_id': attachment.id,
            'cloudinary_public_id': attachment.cloudinary_public_id,
            'cloudinary_resource_type': (
                attachment.cloudinary_resource_type
                or CloudinaryService(self.env)._resource_type_for_attachment(attachment)
            ),
            'cloudinary_type': attachment.cloudinary_type or attachment._cloudinary_delivery_mode(),
            'delete_after': delete_after,
        })

    @api.model
    def _cron_cloudinary_cleanup_due_assets(self, limit=100):
        service = CloudinaryService(self.env)
        queue_records = self.search(
            [
                ('state', 'in', ('pending', 'failed')),
                ('delete_after', '<=', fields.Datetime.now()),
            ],
            limit=limit,
            order='delete_after asc, id asc',
        )

        for queue_record in queue_records:
            values = {
                'attempt_count': queue_record.attempt_count + 1,
            }
            try:
                result = service.delete_asset(
                    public_id=queue_record.cloudinary_public_id,
                    resource_type=queue_record.cloudinary_resource_type,
                    delivery_type=queue_record.cloudinary_type,
                )
                if result is False:
                    raise ValueError('Cloudinary deletion is unavailable or misconfigured.')
                values.update({
                    'state': 'deleted',
                    'processed_at': fields.Datetime.now(),
                    'last_error': False,
                })
            except Exception as exc:  # pragma: no cover - defensive logging
                _LOGGER.warning(
                    "Cloudinary cleanup failed for %s: %s",
                    queue_record.cloudinary_public_id,
                    exc,
                )
                values.update({
                    'state': 'failed',
                    'last_error': str(exc),
                })
            queue_record.sudo().write(values)
        return True
