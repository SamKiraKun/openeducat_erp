###############################################################################
#
#    OpenEduCat Inc
#    Copyright (C) 2009-TODAY OpenEduCat Inc(<https://www.openeducat.org>).
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU Lesser General Public License as
#    published by the Free Software Foundation, either version 3 of the
#    License, or (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU Lesser General Public License for more details.
#
#    You should have received a copy of the GNU Lesser General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
###############################################################################

{
    'name': 'OpenEduCat Cloudinary Storage',
    'version': '18.0.1.0',
    'license': 'LGPL-3',
    'category': 'Education',
    'summary': 'Store OpenEduCat runtime attachments in Cloudinary',
    'author': 'OpenEduCat Inc',
    'website': 'https://www.openeducat.org',
    'depends': ['openeducat_core', 'mail', 'web'],
    'data': [
        'security/ir.model.access.csv',
        'views/res_config_settings_view.xml',
        'data/ir_cron.xml',
    ],
    'installable': True,
    'auto_install': False,
    'application': False,
    'external_dependencies': {
        'python': ['cloudinary'],
    },
}
