import base64
from unittest.mock import patch

from odoo.tests import TransactionCase


class TestCloudinaryAttachment(TransactionCase):

    def setUp(self):
        super().setUp()
        self.attachment_model = self.env['ir.attachment']
        self.deletion_queue_model = self.env['openeducat.cloudinary.deletion.queue']
        self.settings_model = self.env['res.config.settings']
        self.config_parameters = self.env['ir.config_parameter'].sudo()

    def test_cloudinary_settings_are_persisted(self):
        settings = self.settings_model.create({
            'cloudinary_enabled': True,
            'cloudinary_cloud_name': 'demo-cloud',
            'cloudinary_api_key': 'key-123',
            'cloudinary_api_secret': 'secret-123',
            'cloudinary_folder_prefix': 'openeducat/test',
            'cloudinary_delivery_mode': 'authenticated',
            'cloudinary_max_upload_mb': 32,
        })
        settings.execute()

        self.assertEqual(self.config_parameters.get_param('cloudinary.enabled'), 'True')
        self.assertEqual(self.config_parameters.get_param('cloudinary.cloud_name'), 'demo-cloud')
        self.assertEqual(self.config_parameters.get_param('cloudinary.folder_prefix'), 'openeducat/test')
        self.assertEqual(self.config_parameters.get_param('cloudinary.delivery_mode'), 'authenticated')

    def test_attachment_create_stays_disabled_when_feature_flag_is_off(self):
        self.config_parameters.set_param('cloudinary.enabled', 'False')
        attachment = self.attachment_model.create({
            'name': 'student-photo.png',
            'type': 'binary',
            'datas': base64.b64encode(b'fake-image-bytes').decode(),
            'mimetype': 'image/png',
        })

        self.assertEqual(attachment.cloudinary_sync_state, 'disabled')
        self.assertFalse(attachment.cloudinary_public_id)

    def test_attachment_create_syncs_when_feature_flag_is_on(self):
        self.config_parameters.set_param('cloudinary.enabled', 'True')
        self.config_parameters.set_param('cloudinary.cloud_name', 'demo-cloud')
        self.config_parameters.set_param('cloudinary.api_key', 'key-123')
        self.config_parameters.set_param('cloudinary.api_secret', 'secret-123')
        self.config_parameters.set_param('cloudinary.school_code', 'main-campus')

        with patch(
            'odoo.addons.openeducat_cloudinary_storage.services.cloudinary_service.CloudinaryService.upload_attachment',
            return_value={
                'state': 'synced',
                'public_id': 'openeducat/test/attachment_1',
                'version': '42',
                'resource_type': 'image',
                'type': 'authenticated',
                'secure_url': 'https://res.cloudinary.com/demo/image/upload/v42/openeducat/test/attachment_1.png',
                'format': 'png',
                'bytes': 128,
                'etag': 'etag-123',
            },
        ):
            attachment = self.attachment_model.create({
                'name': 'student-photo.png',
                'type': 'binary',
                'datas': base64.b64encode(b'fake-image-bytes').decode(),
                'mimetype': 'image/png',
            })

        self.assertEqual(attachment.cloudinary_sync_state, 'synced')
        self.assertEqual(attachment.cloudinary_public_id, 'openeducat/test/attachment_1')
        self.assertTrue(attachment.cloudinary_migrated)
        self.assertEqual(
            attachment.store_fname,
            'cloudinary://openeducat/test/attachment_1',
        )
        self.assertFalse(attachment.db_datas)

    def test_attachment_unlink_queues_remote_delete(self):
        self.config_parameters.set_param('cloudinary.enabled', 'True')
        self.config_parameters.set_param('cloudinary.delete_remote_on_unlink', 'True')
        self.config_parameters.set_param('cloudinary.delete_retention_days', '15')

        attachment = self.attachment_model.with_context(skip_cloudinary_sync=True).create({
            'name': 'student-photo.png',
            'type': 'binary',
            'datas': base64.b64encode(b'fake-image-bytes').decode(),
            'mimetype': 'image/png',
            'cloudinary_public_id': 'openeducat/prod/school/db/op.student/7/student-photo',
            'cloudinary_resource_type': 'image',
            'cloudinary_type': 'authenticated',
        })

        attachment.unlink()

        queue_record = self.deletion_queue_model.search(
            [('cloudinary_public_id', '=', 'openeducat/prod/school/db/op.student/7/student-photo')],
            limit=1,
        )
        self.assertTrue(queue_record)
        self.assertEqual(queue_record.state, 'pending')

    def test_remote_backed_file_read_returns_base64_payload(self):
        attachment = self.attachment_model.with_context(skip_cloudinary_sync=True).create({
            'name': 'student-photo.png',
            'type': 'binary',
            'store_fname': 'cloudinary://openeducat/test/student-photo',
            'cloudinary_public_id': 'openeducat/test/student-photo',
            'cloudinary_resource_type': 'image',
            'cloudinary_type': 'authenticated',
            'cloudinary_bytes': 16,
        })

        with patch(
            'odoo.addons.openeducat_cloudinary_storage.services.cloudinary_service.CloudinaryService.download_attachment',
            return_value=b'cloudinary-bytes',
        ):
            payload = self.attachment_model._file_read(attachment.store_fname)

        self.assertEqual(payload, base64.b64encode(b'cloudinary-bytes'))

    def test_reverse_restore_downloads_remote_payload_back_to_local_storage(self):
        attachment = self.attachment_model.with_context(skip_cloudinary_sync=True).create({
            'name': 'student-photo.png',
            'type': 'binary',
            'store_fname': 'cloudinary://openeducat/test/student-photo',
            'cloudinary_public_id': 'openeducat/test/student-photo',
            'cloudinary_resource_type': 'image',
            'cloudinary_type': 'authenticated',
        })

        with patch(
            'odoo.addons.openeducat_cloudinary_storage.services.cloudinary_service.CloudinaryService.download_attachment',
            return_value=b'cloudinary-bytes',
        ):
            restored = attachment._cloudinary_restore_local_storage()

        self.assertTrue(restored)
        self.assertNotEqual(attachment.store_fname, 'cloudinary://openeducat/test/student-photo')

    def test_migrate_existing_attachments_dry_run_reports_selected_ids(self):
        self.config_parameters.set_param('cloudinary.enabled', 'True')
        attachment = self.attachment_model.create({
            'name': 'student-photo.png',
            'type': 'binary',
            'datas': base64.b64encode(b'fake-image-bytes').decode(),
            'mimetype': 'image/png',
        })

        result = self.attachment_model._cloudinary_migrate_existing_attachments(
            dry_run=True,
            limit=10,
        )

        self.assertIn(attachment.id, result['selected_ids'])
