from odoo import fields, models


class ResConfigSettings(models.TransientModel):
    _inherit = 'res.config.settings'

    cloudinary_enabled = fields.Boolean(
        string='Enable Cloudinary Storage',
        config_parameter='cloudinary.enabled',
    )
    cloudinary_cloud_name = fields.Char(
        string='Cloud Name',
        config_parameter='cloudinary.cloud_name',
    )
    cloudinary_api_key = fields.Char(
        string='API Key',
        config_parameter='cloudinary.api_key',
    )
    cloudinary_api_secret = fields.Char(
        string='API Secret',
        config_parameter='cloudinary.api_secret',
    )
    cloudinary_folder_prefix = fields.Char(
        string='Folder Prefix',
        config_parameter='cloudinary.folder_prefix',
        default='openeducat',
    )
    cloudinary_environment_name = fields.Char(
        string='Environment Name',
        config_parameter='cloudinary.environment_name',
        default='prod',
    )
    cloudinary_school_code = fields.Char(
        string='School Code',
        config_parameter='cloudinary.school_code',
    )
    cloudinary_upload_images = fields.Boolean(
        string='Mirror Image Uploads',
        config_parameter='cloudinary.upload_images',
        default=True,
    )
    cloudinary_upload_raw_files = fields.Boolean(
        string='Mirror Raw Files',
        config_parameter='cloudinary.upload_raw_files',
        default=True,
    )
    cloudinary_delete_remote_on_unlink = fields.Boolean(
        string='Delete Remote Asset On Attachment Delete',
        config_parameter='cloudinary.delete_remote_on_unlink',
        default=True,
    )
    cloudinary_delete_retention_days = fields.Integer(
        string='Remote Delete Retention (Days)',
        config_parameter='cloudinary.delete_retention_days',
        default=15,
    )
    cloudinary_delivery_mode = fields.Selection(
        [
            ('upload', 'Public Upload'),
            ('private', 'Private'),
            ('authenticated', 'Authenticated'),
        ],
        string='Delivery Mode',
        config_parameter='cloudinary.delivery_mode',
        default='authenticated',
    )
    cloudinary_max_upload_mb = fields.Integer(
        string='Max Upload Size (MB)',
        config_parameter='cloudinary.max_upload_mb',
        default=8,
    )
