Ext.define('PVE.window.Reinstall', {
    extend: 'Ext.window.Window',

    resizable: false,

    reinstall: function(ostemplate, password) {
	var me = this;
	PVE.Utils.API2Request({
	    params: { ostemplate: ostemplate, password: password },
	    url: '/nodes/' + me.nodename + '/openvz/' + me.vmid + "/reinstall",
	    waitMsgTarget: me,
	    method: 'POST',
	    failure: function(response, opts) {
		Ext.Msg.alert(gettext('Error'), response.htmlStatus);
	    },
	    success: function(response, options) {
		var upid = response.result.data;

		var win = Ext.create('PVE.window.TaskViewer', { 
		    upid: upid
		});
		win.show();
		me.close();
	    }
	});
    },

    initComponent : function() {
	var me = this;

	if (!me.nodename) {
	    throw "no node name specified";
	}

	if (!me.vmid) {
	    throw "no VM ID specified";
	}

	if (!me.vmtype) {
	    throw "no VM type specified";
	}

	var running = false;
	var vmrec = PVE.data.ResourceStore.findRecord('vmid', me.vmid,
						      0, false, false, true);
	if (vmrec && vmrec.data && vmrec.data.running) {
	    running = true;
	}

	var tmplsel = Ext.create('PVE.form.FileSelector', {
	    name: 'ostemplate',
	    storageContent: 'vztmpl',
	    fieldLabel: gettext('Template'),
	    allowBlank: false
	});
	
	var tmplstoragesel = Ext.create('PVE.form.StorageSelector', {
	    name: 'tmplstorage',
	    fieldLabel: gettext('Storage'),
	    storageContent: 'vztmpl',
	    autoSelect: true,
	    allowBlank: false,
	    listeners: {
		change: function(f, value) {
		    tmplsel.setStorage(value);
		}
	    }
	});
	tmplstoragesel.setNodename(me.nodename);
	tmplsel.setStorage(undefined, me.nodename);

	me.formPanel = Ext.create('Ext.form.Panel', {
	    bodyPadding: 10,
	    border: false,
	    fieldDefaults: {
		labelWidth: 100,
		anchor: '100%'
	    },
	    items: [
			{
			    xtype: 'textfield',
			    inputType: 'password',
			    name: 'password',
			    value: '',
			    fieldLabel: gettext('Password'),
			    allowBlank: false,
			    minLength: 5,
			    change: function(f, value) {
				if (!me.rendered) {
				    return;
				}
				me.down('field[name=confirmpw]').validate();
			    }
			},
			{
			    xtype: 'textfield',
			    inputType: 'password',
			    name: 'confirmpw',
			    value: '',
			    fieldLabel: gettext('Confirm password'),
			    allowBlank: false,
			    validator: function(value) {
				var pw = me.down('field[name=password]').getValue();
				if (pw !== value) {
				    return "Passwords does not match!";
				}
				return true;
			    }
			},
		tmplstoragesel,
		tmplsel
	    ]
	});

	var form = me.formPanel.getForm();

	var submitBtn = Ext.create('Ext.Button', {
	    text: gettext('Reinstall'),
	    handler: function() {
		var values = form.getValues();
		if(values.password != values.confirmpw) {
			return false;
		}
		me.reinstall(values.ostemplate, values.password);
	    }
	});

	Ext.apply(me, {
	    title: gettext('Reinstall') + ' VM ' + me.vmid,
	    width: 350,
	    modal: true,
	    layout: 'auto',
	    border: false,
	    items: [ me.formPanel ],
	    buttons: [ submitBtn ]
	});

	me.callParent();
    }
});
