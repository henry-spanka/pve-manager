/*jslint confusion: true */
Ext.define('PVE.qemu.Options', {
    extend: 'PVE.grid.ObjectGrid',
    alias: ['widget.PVE.qemu.Options'],

    initComponent : function() {
	var me = this;
	var i;

	var nodename = me.pveSelNode.data.node;
	if (!nodename) {
	    throw "no node name specified";
	}

	var vmid = me.pveSelNode.data.vmid;
	if (!vmid) {
	    throw "no VM ID specified";
	}

	var caps = Ext.state.Manager.get('GuiCap');

	var rows = {
	    name: {
		required: true,
		defaultValue: me.pveSelNode.data.name,
		header: gettext('Name'),
		editor: caps.vms['VM.Config.Options'] ? {
		    xtype: 'pveWindowEdit',
		    subject: gettext('Name'),
		    items: {
			xtype: 'textfield',
			name: 'name',
			vtype: 'DnsName',
			value: '',
			fieldLabel: gettext('Name'),
			allowBlank: true
		    }
		} : undefined
	    },
	    onboot: {
		header: gettext('Start at boot'),
		defaultValue: '',
		renderer: PVE.Utils.format_boolean,
		editor: caps.vms['VM.Config.Options'] ? {
		    xtype: 'pveWindowEdit',
		    subject: gettext('Start at boot'),
		    items: {
			xtype: 'pvecheckbox',
			name: 'onboot',
			uncheckedValue: 0,
			defaultValue: 0,
			deleteDefaultValue: true,
			fieldLabel: gettext('Start at boot')
		    }
		} : undefined
	    },
	    startup: {
		header: gettext('Start/Shutdown order'),
		defaultValue: '',
		renderer: PVE.Utils.render_kvm_startup,
		editor: caps.vms['VM.Config.Options'] && caps.nodes['Sys.Modify'] ? 
		    'PVE.qemu.StartupEdit' : undefined
	    },
	    ostype: {
		header: gettext('OS Type'),
		editor: caps.vms['VM.Config.Options'] ? 'PVE.qemu.OSTypeEdit' : undefined,
		renderer: PVE.Utils.render_kvm_ostype,
		defaultValue: 'other'
	    },
	    bootdisk: {
		visible: false
	    },
	    boot: {
		header: gettext('Boot order'),
		defaultValue: 'cdn',
		editor: caps.vms['VM.Config.Disk'] ? 'PVE.qemu.BootOrderEdit' : undefined,
		renderer: function(order) {
		    var i;
		    var text = '';
		    var bootdisk = me.getObjectValue('bootdisk');
		    order = order || 'cdn';
		    for (i = 0; i < order.length; i++) {
			var sel = order.substring(i, i + 1);
			if (text) {
			    text += ', ';
			}
			if (sel === 'c') {
			    if (bootdisk) {
				text += "Disk '" + bootdisk + "'";
			    } else {
				text += "Disk";
			    }
			} else if (sel === 'n') {
			    text += 'Network';
			} else if (sel === 'a') {
			    text += 'Floppy';
			} else if (sel === 'd') {
			    text += 'CD-ROM';
			} else {
			    text += sel;
			}
		    }
		    return text;
		}
	    },
	    tablet: {
		header: gettext('Use tablet for pointer'),
		defaultValue: true,
		renderer: PVE.Utils.format_boolean,
		editor: caps.vms['VM.Config.HWType'] ? {
		    xtype: 'pveWindowEdit',
		    subject: gettext('Use tablet for pointer'),
		    items: {
			xtype: 'pvecheckbox',
			name: 'tablet',
			checked: true,
			uncheckedValue: 0,
			defaultValue: 1,
			deleteDefaultValue: true,
			fieldLabel: gettext('Enabled')
		    }
		} : undefined
	    },
	    hotplug: {
		header: gettext('Hotplug'),
		defaultValue: '',
		renderer: PVE.Utils.format_boolean,
		editor: caps.vms['VM.Config.HWType'] ? {
		    xtype: 'pveWindowEdit',
		    subject: gettext('Hotplug'),
		    items: {
			xtype: 'pvecheckbox',
			name: 'hotplug',
			uncheckedValue: 0,
			defaultValue: 0,
			deleteDefaultValue: true,
			fieldLabel: gettext('Hotplug')
		    }
		} : undefined
	    },
	    acpi: {
		header: gettext('ACPI support'),
		defaultValue: true,
		renderer: PVE.Utils.format_boolean,
		editor: caps.vms['VM.Config.HWType'] ? {
		    xtype: 'pveWindowEdit',
		    subject: gettext('ACPI support'),
		    items: {
			xtype: 'pvecheckbox',
			name: 'acpi',
			checked: true,
			uncheckedValue: 0,
			defaultValue: 1,
			deleteDefaultValue: true,
			fieldLabel: gettext('Enabled')
		    }
		} : undefined
	    },
	    scsihw: {
		header: gettext('SCSI Controller Type'),
		editor: caps.vms['VM.Config.Options'] ? 'PVE.qemu.ScsiHwEdit' : undefined,
		renderer: PVE.Utils.render_scsihw,
		defaultValue: ''
	    },
	    kvm: {
		header: gettext('KVM hardware virtualization'),
		defaultValue: true,
		renderer: PVE.Utils.format_boolean,
		editor: caps.vms['VM.Config.HWType'] ? {
		    xtype: 'pveWindowEdit',
		    subject: gettext('KVM hardware virtualization'),
		    items: {
			xtype: 'pvecheckbox',
			name: 'kvm',
			checked: true,
			uncheckedValue: 0,
			defaultValue: 1,
			deleteDefaultValue: true,
			fieldLabel: gettext('Enabled')
		    }
		} : undefined
	    },
	    cpuunits: {
		header: gettext('CPU units'),
		defaultValue: '1000',
		editor: caps.vms['VM.Config.CPU'] ? {
		    xtype: 'pveWindowEdit',
		    subject: gettext('CPU units'),
		    items: {
			xtype: 'numberfield',
			name: 'cpuunits',
			fieldLabel: gettext('CPU units'),
			minValue: 8,
			maxValue: 500000,
			defaultValue: 1000,
			allowBlank: false
		    }
		} : undefined
	    },
	    freeze: {
		header: gettext('Freeze CPU at startup'),
		defaultValue: false,
		renderer: PVE.Utils.format_boolean,
		editor: caps.vms['VM.PowerMgmt'] ? {
		    xtype: 'pveWindowEdit',
		    subject: gettext('Freeze CPU at startup'),
		    items: {
			xtype: 'pvecheckbox',
			name: 'freeze',
			uncheckedValue: 0,
			defaultValue: 0,
			deleteDefaultValue: true,
			labelWidth: 140,
			fieldLabel: gettext('Freeze CPU at startup')
		    }
		} : undefined
	    },
		cpulimit: {
			header: gettext('CPU limit'),
			defaultValue: '0',
			editor: caps.vms['VM.Config.CPU'] ? {
				xtype: 'pveWindowEdit',
				subject: gettext('CPU limit'),
				items: {
					xtype: 'numberfield',
					name: 'cpulimit',
					fieldLabel: gettext('CPU limit'),
					minValue: 0,
					maxValue: 16000,
					defaultValue: 0,
					allowBlank: false
				}
			} : undefined
		},
	    localtime: {
		header: gettext('Use local time for RTC'),
		defaultValue: false,
		renderer: PVE.Utils.format_boolean,
		editor: caps.vms['VM.Config.Options'] ? {
		    xtype: 'pveWindowEdit',
		    subject: gettext('Use local time for RTC'),
		    items: {
			xtype: 'pvecheckbox',
			name: 'localtime',
			uncheckedValue: 0,
			defaultValue: 0,
			deleteDefaultValue: true,
			labelWidth: 140,
			fieldLabel: gettext('Use local time for RTC')
		    }
		} : undefined
	    },
	    startdate: {
		header: gettext('RTC start date'),
		defaultValue: 'now',
		editor: caps.vms['VM.Config.Options'] ? {
		    xtype: 'pveWindowEdit',
		    subject: gettext('RTC start date'),
		    items: {
			xtype: 'pvetextfield',
			name: 'startdate',
			deleteEmpty: true,
			value: 'now',
			fieldLabel: gettext('RTC start date'),
			vtype: 'QemuStartDate',
			allowBlank: true
		    }
		} : undefined
	    },
	    smbios1: {
		header: gettext('SMBIOS settings (type1)'),
		defaultValue: '',
		editor: caps.vms['VM.Config.HWType'] ? 'PVE.qemu.Smbios1Edit' : undefined
	    }
	};

	var baseurl = 'nodes/' + nodename + '/qemu/' + vmid + '/config';

	var reload = function() {
	    me.rstore.load();
	};

	var run_editor = function() {
	    var sm = me.getSelectionModel();
	    var rec = sm.getSelection()[0];
	    if (!rec) {
		return;
	    }

	    var rowdef = rows[rec.data.key];
	    if (!rowdef.editor) {
		return;
	    }

	    var win;
	    if (Ext.isString(rowdef.editor)) {
		win = Ext.create(rowdef.editor, {
		    pveSelNode: me.pveSelNode,
		    confid: rec.data.key,
		    url: '/api2/extjs/' + baseurl
		});
	    } else {
		var config = Ext.apply({
		    pveSelNode: me.pveSelNode,
		    confid: rec.data.key,
		    url: '/api2/extjs/' + baseurl
		}, rowdef.editor);
		win = Ext.createWidget(rowdef.editor.xtype, config);
		win.load();
	    }

	    win.show();
	    win.on('destroy', reload);
	};

	var edit_btn = new Ext.Button({
	    text: gettext('Edit'),
	    disabled: true,
	    handler: run_editor
	});

	var set_button_status = function() {
	    var sm = me.getSelectionModel();
	    var rec = sm.getSelection()[0];

	    if (!rec) {
		edit_btn.disable();
		return;
	    }
	    var rowdef = rows[rec.data.key];
	    edit_btn.setDisabled(!rowdef.editor);
	};

	Ext.applyIf(me, {
	    url: "/api2/json/nodes/" + nodename + "/qemu/" + vmid + "/config",
	    cwidth1: 170,
	    tbar: [ edit_btn ],
	    rows: rows,
	    listeners: {
		itemdblclick: run_editor,
		selectionchange: set_button_status
	    }
	});

	me.callParent();

	me.on('show', reload);
    }
});

