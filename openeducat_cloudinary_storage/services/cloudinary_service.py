import base64
import io
import logging
import os
import re
from urllib.request import urlopen

try:
    import cloudinary
    from cloudinary import api as cloudinary_api
    from cloudinary import uploader
    from cloudinary import utils as cloudinary_utils
except ImportError:  # pragma: no cover - depends on deployment environment
    cloudinary = None
    cloudinary_api = None
    uploader = None
    cloudinary_utils = None

_LOGGER = logging.getLogger(__name__)


class CloudinaryService:
    def __init__(self, env):
        self.env = env

    def is_available(self):
        return all([cloudinary, cloudinary_api, uploader, cloudinary_utils])

    def upload_attachment(self, attachment):
        config = self._get_config()
        enabled = str(config['enabled']).lower() in ('1', 'true', 'yes', 'on')

        if not enabled:
            return {'state': 'disabled', 'error': False}
        if not self.is_available():
            return {
                'state': 'failed',
                'error': 'Cloudinary Python package is not installed on the Odoo server.',
            }

        missing = [
            key for key in ('cloud_name', 'api_key', 'api_secret', 'school_code')
            if not config[key]
        ]
        if missing:
            return {
                'state': 'failed',
                'error': 'Cloudinary configuration is incomplete: %s' % ', '.join(missing),
            }

        resource_type = self._resource_type_for_attachment(attachment)
        if resource_type == 'image' and not config['upload_images']:
            return {'state': 'disabled', 'error': False}
        if resource_type == 'raw' and not config['upload_raw_files']:
            return {'state': 'disabled', 'error': False}

        payload_b64 = attachment.with_context(bin_size=False).datas
        if not payload_b64:
            return {'state': 'failed', 'error': 'Attachment has no binary payload to mirror.'}

        if isinstance(payload_b64, bytes):
            payload_b64 = payload_b64.decode()

        payload = base64.b64decode(payload_b64)
        return self.upload_bytes(
            payload=payload,
            public_id=self._build_public_id(attachment, config),
            resource_type=resource_type,
            delivery_type=config['delivery_mode'],
            filename=attachment.name or ('attachment_%s' % attachment.id),
            max_upload_mb=config['max_upload_mb'],
        )

    def upload_bytes(
        self,
        payload,
        public_id,
        resource_type,
        delivery_type,
        filename,
        max_upload_mb,
    ):
        config = self._get_config()
        max_bytes = max(max_upload_mb, 1) * 1024 * 1024
        if len(payload) > max_bytes:
            return {
                'state': 'failed',
                'error': 'Attachment exceeds Cloudinary max upload size of %s MB.' % max_upload_mb,
            }

        self._configure_client(config)

        try:
            response = uploader.upload(
                io.BytesIO(payload),
                resource_type=resource_type,
                public_id=public_id,
                overwrite=True,
                unique_filename=False,
                use_filename=False,
                type=delivery_type,
                filename_override=filename,
            )
        except Exception as exc:  # pragma: no cover - network/sdk behavior
            _LOGGER.warning("Cloudinary upload failed for public_id %s: %s", public_id, exc)
            return {'state': 'failed', 'error': str(exc)}

        return {
            'state': 'synced',
            'public_id': response.get('public_id'),
            'version': str(response.get('version') or ''),
            'resource_type': response.get('resource_type') or resource_type,
            'type': response.get('type') or delivery_type,
            'secure_url': response.get('secure_url'),
            'format': response.get('format'),
            'bytes': response.get('bytes') or len(payload),
            'etag': response.get('etag'),
        }

    def delete_attachment(self, attachment):
        if not attachment.cloudinary_public_id:
            return False

        return self.delete_asset(
            public_id=attachment.cloudinary_public_id,
            resource_type=(
                attachment.cloudinary_resource_type or self._resource_type_for_attachment(attachment)
            ),
            delivery_type=attachment.cloudinary_type or self._get_config()['delivery_mode'],
        )

    def delete_asset(self, public_id, resource_type='raw', delivery_type='authenticated'):
        config = self._get_config()
        if not self.is_available() or not public_id or not self._has_required_credentials(config):
            return False

        self._configure_client(config)
        return uploader.destroy(
            public_id,
            resource_type=resource_type,
            type=delivery_type,
            invalidate=True,
        )

    def asset_exists(self, attachment):
        config = self._get_config()
        if (
            not self.is_available()
            or not attachment.cloudinary_public_id
            or not self._has_required_credentials(config)
        ):
            return False

        self._configure_client(config)
        try:
            cloudinary_api.resource(
                attachment.cloudinary_public_id,
                resource_type=attachment.cloudinary_resource_type or self._resource_type_for_attachment(attachment),
                type=attachment.cloudinary_type or config['delivery_mode'],
            )
        except Exception:  # pragma: no cover - network/sdk behavior
            return False
        return True

    def build_delivery_url(self, attachment, sign_url=None):
        config = self._get_config()
        if (
            not self.is_available()
            or not attachment.cloudinary_public_id
            or not self._has_required_credentials(config)
        ):
            return False

        if sign_url is None:
            sign_url = (attachment.cloudinary_type or config['delivery_mode']) != 'upload'

        self._configure_client(config)
        options = {
            'resource_type': attachment.cloudinary_resource_type or self._resource_type_for_attachment(attachment),
            'type': attachment.cloudinary_type or config['delivery_mode'],
            'secure': True,
            'sign_url': sign_url,
        }
        return cloudinary_utils.cloudinary_url(attachment.cloudinary_public_id, **options)[0]

    def download_attachment(self, attachment, sign_url=None):
        delivery_type = attachment.cloudinary_type or self._get_config()['delivery_mode']
        if sign_url is None:
            sign_url = delivery_type != 'upload'

        delivery_url = self.build_delivery_url(attachment, sign_url=sign_url)
        if not delivery_url:
            delivery_url = attachment.cloudinary_secure_url
        if not delivery_url:
            return False

        with urlopen(delivery_url) as response:  # pragma: no cover - network call
            return response.read()

    def _get_config(self):
        params = self.env['ir.config_parameter'].sudo()
        return {
            'enabled': params.get_param('cloudinary.enabled', default='False'),
            'cloud_name': params.get_param('cloudinary.cloud_name', default=''),
            'api_key': params.get_param('cloudinary.api_key', default=''),
            'api_secret': params.get_param('cloudinary.api_secret', default=''),
            'folder_prefix': params.get_param('cloudinary.folder_prefix', default='openeducat'),
            'environment_name': params.get_param('cloudinary.environment_name', default='prod'),
            'school_code': params.get_param('cloudinary.school_code', default=''),
            'delivery_mode': params.get_param('cloudinary.delivery_mode', default='authenticated'),
            'upload_images': str(
                params.get_param('cloudinary.upload_images', default='True')
            ).lower() in ('1', 'true', 'yes', 'on'),
            'upload_raw_files': str(
                params.get_param('cloudinary.upload_raw_files', default='True')
            ).lower() in ('1', 'true', 'yes', 'on'),
            'delete_retention_days': int(
                params.get_param('cloudinary.delete_retention_days', default='15') or 15
            ),
            'max_upload_mb': int(params.get_param('cloudinary.max_upload_mb', default='8') or 8),
        }

    def _configure_client(self, config):
        cloudinary.config(
            cloud_name=config['cloud_name'],
            api_key=config['api_key'],
            api_secret=config['api_secret'],
            secure=True,
        )

    def _resource_type_for_attachment(self, attachment):
        mimetype = attachment.mimetype or ''
        if mimetype.startswith('image/'):
            return 'image'
        return 'raw'

    def _build_public_id(self, attachment, config):
        parts = [
            self._sanitize_segment(config['folder_prefix'] or 'openeducat'),
            self._sanitize_segment(config['environment_name']),
            self._sanitize_segment(config['school_code']),
            self._sanitize_segment(self.env.cr.dbname),
            self._sanitize_segment(attachment.res_model or 'ir_attachment'),
            self._sanitize_segment(str(attachment.res_id or '0')),
            self._sanitize_segment(
                '%s_%s' % (
                    attachment.id,
                    os.path.splitext(attachment.name or 'attachment')[0],
                )
            ),
        ]
        return '/'.join([part for part in parts if part])

    def _sanitize_segment(self, value):
        value = re.sub(r'[^0-9A-Za-z/_-]+', '_', value or '')
        value = re.sub(r'_+', '_', value)
        return value.strip('/_')

    def _has_required_credentials(self, config):
        return all(config.get(key) for key in ('cloud_name', 'api_key', 'api_secret'))
