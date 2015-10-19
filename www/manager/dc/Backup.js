Ext.define('PVE.dc.BackupEdit', {
    extend: 'PVE.window.Edit',
    alias: ['widget.pveDcBackupEdit'],

    initComponent : function() {
	/*jslint confusion: true */
         var me = this;

        me.create = !me.jobid;

	var url;
	var method;

	if (me.create) {
            url = '/api2/extjs/cluster/backup';
            method = 'POST';
        } else {
            url = '/api2/extjs/cluster/backup/' + me.jobid;
            method = 'PUT';
        }

	var vmidField = Ext.create('Ext.form.field.Hidden', {
	    name: 'vmid'
	});

	var selModeField =  Ext.create('PVE.form.KVComboBox', {
	    xtype: 'pveKVComboBox',
	    data: [
		['include', gettext('Include selected VMs')],
		['all', gettext('All')],
		['exclude', gettext('Exclude selected VMs')]
	    ],
	    fieldLabel: gettext('Selection mode'),
	    name: 'selMode',
	    value: ''
	});

	var insideUpdate = false;
	
	var sm = Ext.create('Ext.selection.CheckboxModel', {
	    mode: 'SIMPLE',
	    listeners: {
		selectionchange: function(model, selected) {
		    if (!insideUpdate) { // avoid endless loop
			var sel = [];
			Ext.Array.each(selected, function(record) {
			    sel.push(record.data.vmid);
			});

			insideUpdate = true;
			vmidField.setValue(sel);
			insideUpdate = false;
		    }
		}
	    }
	});

	var storagesel = Ext.create('PVE.form.StorageSelector', {
	    fieldLabel: gettext('Storage'),
	    nodename: 'localhost',
	    storageContent: 'backup',
	    allowBlank: false,
	    name: 'storage'
	});

	var store = new Ext.data.Store({
	    model: 'PVEResources',
	    sorters: { 
		property: 'vmid', 
		order: 'ASC' 
	    }
	});

	var vmgrid = Ext.createWidget('grid', {
	    store: store,
	    border: true,
	    height: 300,
	    selModel: sm,
	    disabled: true,
	    columns: [
		{ 
		    header: 'ID',
		    dataIndex: 'vmid',
		    width: 60
		},
		{ 
		    header: gettext('Node'),
		    dataIndex: 'node'
		},
		{ 
		    header: gettext('Status'),
		    dataIndex: 'uptime',
		    renderer: function(value) {
			if (value) {
			    return PVE.Utils.runningText;
			} else {
			    return PVE.Utils.stoppedText;
			}
		    }
		},
		{ 
		    header: gettext('Name'), 
		    dataIndex: 'name',
		    flex: 1 
		},
		{ 
		    header: gettext('Type'), 
		    dataIndex: 'type'
		}
	    ]
	});

	var nodesel = Ext.create('PVE.form.NodeSelector', {
	    name: 'node',
	    fieldLabel: gettext('Node'),
	    allowBlank: true,
	    editable: true,
	    autoSelect: false,
	    emptyText: '-- ' + gettext('All') + ' --',
	    listeners: {
		change: function(f, value) {
		    storagesel.setNodename(value || 'localhost');
		    var mode = selModeField.getValue();
		    store.clearFilter();
		    store.filterBy(function(rec) {
			return (!value || rec.get('node') === value);
		    });
		    if (mode === 'all') {
			sm.selectAll(true);
		    }
		}
	    }
	});

	var column1 = [
	    nodesel,
	    storagesel,
	    {
		xtype: 'pveDayOfWeekSelector',
		name: 'dow',
		fieldLabel: gettext('Day of week'),
		multiSelect: true,
		value: ['sat'],
		allowBlank: false
	    },
	    {
		xtype: 'timefield',
		fieldLabel: gettext('Start Time'),
		name: 'starttime',
		format: 'H:i',
		value: '00:00',
		allowBlank: false
	    },
	    selModeField,
        {
            xtype: 'pvecheckbox',
            fieldLabel: gettext('Rsync'),
            uncheckedValue: 0,
            defaultValue: 0,
            checked: false,
            name: 'rsync',
            listeners: {
                change: function(checkbox, value) {
                    if (value) {
                        Ext.getCmp('rsync_destination_host').enable();
                        Ext.getCmp('rsync_port').enable();
                        Ext.getCmp('rsync_keyfile').enable();
                        Ext.getCmp('rsync_destination_dir').enable();
                        Ext.getCmp('rsync_user').enable();
                    } else {
                        Ext.getCmp('rsync_destination_host').disable();
                        Ext.getCmp('rsync_port').disable();
                        Ext.getCmp('rsync_keyfile').disable();
                        Ext.getCmp('rsync_destination_dir').disable();
                        Ext.getCmp('rsync_user').disable();
                    }
                }
            }
        },
	    {
			xtype: 'textfield',
			fieldLabel: gettext('Rsync Host'),
			name: 'rsync_destination_host',
			id: 'rsync_destination_host',
			disabled: true
	    },
	    {
			xtype: 'textfield',
			fieldLabel: gettext('Rsync Keyfile'),
			name: 'rsync_keyfile',
			id: 'rsync_keyfile',
			disabled: true
	    },
	];

	var column2 = [
	    {
		xtype: 'textfield',
		fieldLabel: gettext('Send email to'),
		name: 'mailto'
	    },
	    {
		xtype: 'pveEmailNotificationSelector',
		fieldLabel: gettext('Email notification'),
		name: 'mailnotification',
		deleteEmpty: me.create ? false : true,
		value: me.create ? 'always' : ''
	    },
	    {
		xtype: 'pveCompressionSelector',
		fieldLabel: gettext('Compression'),
		name: 'compress',
		deleteEmpty: me.create ? false : true,
		value: me.create ? 'lzo' : ''
	    },
	    {
		xtype: 'pveBackupModeSelector',
		fieldLabel: gettext('Mode'),
		value: 'snapshot',
		name: 'mode'
	    },
        {
            xtype: 'numberfield',
            fieldLabel: gettext('BW Limit(KB/s)'),
            name: 'bwlimit',
            minValue: 0,
        },
	    {
			xtype: 'numberfield',
			fieldLabel: gettext('Rsync Port'),
			name: 'rsync_port',
			id: 'rsync_port',
			disabled: true
	    },
	    {
			xtype: 'textfield',
			fieldLabel: gettext('Rsync Directory'),
			name: 'rsync_destination_dir',
			id: 'rsync_destination_dir',
			disabled: true
	    },
	    {
			xtype: 'textfield',
			fieldLabel: gettext('Rsync User'),
			name: 'rsync_user',
			id: 'rsync_user',
			disabled: true
	    },
	    vmidField
	];

	var ipanel = Ext.create('PVE.panel.InputPanel', {
	    column1: column1,
	    column2:  column2,
	    onGetValues: function(values) {
		if (!values.node) {
		    if (!me.create) {
			PVE.Utils.assemble_field_data(values, { 'delete': 'node' }); 
		    }
		    delete values.node;
		}

		var selMode = values.selMode;
		delete values.selMode;

		if (selMode === 'all') {
		    values.all = 1;
		    values.exclude = '';
		    delete values.vmid;
		} else if (selMode === 'exclude') {
		    values.all = 1;
		    values.exclude = values.vmid;
		    delete values.vmid;
		}
		return values;
	    }
	});

	var update_vmid_selection = function(list, mode) {
	    if (insideUpdate) {
		return; // should not happen - just to be sure
	    }
	    insideUpdate = true;
	    if (mode !== 'all') {
		sm.deselectAll(true);
		if (list) {
		    Ext.Array.each(list.split(','), function(vmid) {
			var rec = store.findRecord('vmid', vmid);
			if (rec) {
			    sm.select(rec, true);
			}
		    });
		}
	    }
	    insideUpdate = false;
	};

	vmidField.on('change', function(f, value) {
	    var mode = selModeField.getValue();
	    update_vmid_selection(value, mode);
	});

	selModeField.on('change', function(f, value, oldValue) {
	    if (value === 'all') {
		sm.selectAll(true);
		vmgrid.setDisabled(true);
	    } else {
		vmgrid.setDisabled(false);
	    }
	    if (oldValue === 'all') {
		sm.deselectAll(true);
		vmidField.setValue('');
	    }
	    var list = vmidField.getValue();
	    update_vmid_selection(list, value);
	});
		 
	var reload = function() {
	    store.load({
		params: { type: 'vm' },
		callback: function() {
		    var node = nodesel.getValue();
		    store.clearFilter();
		    store.filterBy(function(rec) {
			return (!node || rec.get('node') === node);
		    });
		    var list = vmidField.getValue();
		    var mode = selModeField.getValue();
		    if (mode === 'all') {
			sm.selectAll(true);
		    } else {
			update_vmid_selection(list, mode);
		    }
		}
	    });
	};

        Ext.applyIf(me, {
            subject: gettext("Backup Job"),
            url: url,
            method: method,
	    items: [ ipanel, vmgrid ]
        });

        me.callParent();

        if (me.create) {
	    selModeField.setValue('include');
	} else {
            me.load({
		success: function(response, options) {
		    var data = response.result.data;

		    data.dow = data.dow.split(',');

		    if (data.all || data.exclude) {
			if (data.exclude) {
			    data.vmid = data.exclude;
			    data.selMode = 'exclude';
			} else {
			    data.vmid = '';
			    data.selMode = 'all';
			}
		    } else {
			data.selMode = 'include';
		    }

		    me.setValues(data);
               }
            });
        }

	reload();
    }
});


Ext.define('PVE.dc.BackupView', {
    extend: 'Ext.grid.GridPanel',

    alias: ['widget.pveDcBackupView'],

    allText: '-- ' + gettext('All') + ' --',
    allExceptText: gettext('All except {0}'),

    initComponent : function() {
	var me = this;

	var store = new Ext.data.Store({
	    model: 'pve-cluster-backup',
	    proxy: {
                type: 'pve',
		url: "/api2/json/cluster/backup"
	    }
	});

	var reload = function() {
	    store.load();
	};

	var sm = Ext.create('Ext.selection.RowModel', {});

	var run_editor = function() {
	    var rec = sm.getSelection()[0];
	    if (!rec) {
		return;
	    }

            var win = Ext.create('PVE.dc.BackupEdit',{
                jobid: rec.data.id
            });
            win.on('destroy', reload);
            win.show();
	};

	var edit_btn = new PVE.button.Button({
	    text: gettext('Edit'),
	    disabled: true,
	    selModel: sm,
	    handler: run_editor
	});

	var remove_btn = new PVE.button.Button({
	    text: gettext('Remove'),
	    disabled: true,
	    selModel: sm,
	    confirmMsg: gettext('Are you sure you want to remove this entry'),
	    handler: function(btn, event, rec) {
		PVE.Utils.API2Request({
		    url: '/cluster/backup/' + rec.data.id,
		    method: 'DELETE',
		    waitMsgTarget: me,
		    callback: function() {
			reload();
		    },
		    failure: function (response, opts) {
			Ext.Msg.alert(gettext('Error'), response.htmlStatus);
		    }
		});
	    }
	});

	PVE.Utils.monStoreErrors(me, store);

	Ext.apply(me, {
	    store: store,
	    selModel: sm,
	    stateful: false,
	    viewConfig: {
		trackOver: false
	    },
	    tbar: [
		{
		    text: gettext('Add'),
		    handler: function() {
			var win = Ext.create('PVE.dc.BackupEdit',{});
			win.on('destroy', reload);
			win.show();
		    }
		},
		remove_btn,
		edit_btn
	    ],		
	    columns: [
		{
		    header: gettext('Node'),
		    width: 100,
		    sortable: true,
		    dataIndex: 'node',
		    renderer: function(value) {
			if (value) {
			    return value;
			}
			return me.allText;
		    }
		},
		{
		    header: gettext('Day of week'),
		    width: 200,
		    sortable: false,
		    dataIndex: 'dow'
		},
		{
		    header: gettext('Start Time'),
		    width: 60,
		    sortable: true,
		    dataIndex: 'starttime'
		},
		{
		    header: gettext('Storage'),
		    width: 100,
		    sortable: true,
		    dataIndex: 'storage'
		},
		{
		    header: gettext('Rsync'),
		    sortable: false,
		    dataIndex: 'rsync',
		    renderer: function(value) {
				if (value) {
					return "Yes";
				}
				return "No";
		    }
		},
		{
		    header: gettext('Selection'),
		    flex: 1,
		    sortable: false,
		    dataIndex: 'vmid',
		    renderer: function(value, metaData, record) {
			/*jslint confusion: true */
			if (record.data.all) {
			    if (record.data.exclude) {
				return Ext.String.format(me.allExceptText, record.data.exclude);
			    }
			    return me.allText;
			}
			if (record.data.vmid) {
			    return record.data.vmid;
			}

			return "-";
		    }
		}
	    ],
	    listeners: {
		show: reload,
		itemdblclick: run_editor
	    }
	});
	
	me.callParent();
    }
}, function() {

    Ext.define('pve-cluster-backup', {
	extend: 'Ext.data.Model',
	fields: [ 
	    'id', 'starttime', 'dow',
	    'storage', 'node', 'vmid', 'exclude',
	    'mailto', 'rsync',
	    { name: 'all', type: 'boolean' },
	    { name: 'snapshot', type: 'boolean' },
	    { name: 'stop', type: 'boolean' },
	    { name: 'suspend', type: 'boolean' },
	    { name: 'compress', type: 'boolean' }
	]
    });
});