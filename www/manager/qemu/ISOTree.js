Ext.define('PVE.qemu.ISOUpload', {
    extend: 'Ext.window.Window',
    alias: ['widget.pveQemuISOUpload'],

    resizable: false,

    modal: true,

    initComponent : function() {
	/*jslint confusion: true */
        var me = this;

	var xhr;

	if (!me.nodename) {
	    throw "no node name specified";
	}

	if (!me.vmid) { 
	    throw "no vmid specified";
	}

	var baseurl = "/nodes/" + me.nodename + "/qemu/" + me.vmid + "/iso";

	var pbar = Ext.create('Ext.ProgressBar', {
            text: 'Ready',
	    hidden: true
	});

	me.formPanel = Ext.create('Ext.form.Panel', {
	    method: 'POST',
	    waitMsgTarget: true,
	    bodyPadding: 10,
	    border: false,
	    width: 300,
	    fieldDefaults: {
		labelWidth: 100,
		anchor: '100%'
            },
	    items: [
		{
		    xtype: 'filefield',
		    name: 'filename',
		    buttonText: gettext('Select File...'),
		    allowBlank: false
		},
		pbar
	    ]
	});

	var form = me.formPanel.getForm();

	var doStandardSubmit = function() {
	    form.submit({
		url: "/api2/htmljs" + baseurl,
		waitMsg: gettext('Uploading file...'),
		success: function(f, action) {
		    me.close();
		},
		failure: function(f, action) {
		    var msg = PVE.Utils.extractFormActionError(action);
                    Ext.Msg.alert(gettext('Error'), msg);
		}
	    });
	};

	var updateProgress = function(per, bytes) {
	    var text = (per * 100).toFixed(2) + '%';
	    if (bytes) {
		text += " (" + PVE.Utils.format_size(bytes) + ')';
	    }
	    pbar.updateProgress(per, text);
	};
 
	var abortBtn = Ext.create('Ext.Button', {
	    text: gettext('Abort'),
	    disabled: true,
	    handler: function() {
		me.close();
	    }
	});

	var submitBtn = Ext.create('Ext.Button', {
	    text: gettext('Upload'),
	    disabled: true,
	    handler: function(button) {
		var fd;
		try {
		    fd = new FormData();
		} catch (err) {
		    doStandardSubmit();
		    return;
		}

		button.setDisabled(true);
		abortBtn.setDisabled(false);

		field = form.findField('filename');
		var file = field.fileInputEl.dom;
		fd.append("filename", file.files[0]);
		field.setDisabled(true);

		pbar.setVisible(true);
		updateProgress(0);

		xhr = new XMLHttpRequest();

		xhr.addEventListener("load", function(e) {   
		    if (xhr.status == 200) {
			me.close();
		    } else {  
			var msg = gettext('Error') + " " + xhr.status.toString() + ": " + Ext.htmlEncode(xhr.statusText);
			var result = Ext.decode(xhr.responseText);
			result.message = msg;
			var htmlStatus = PVE.Utils.extractRequestError(result, true);
			Ext.Msg.alert(gettext('Error'), htmlStatus, function(btn) {
			    me.close();
			});

		    }  
		}, false);

		xhr.addEventListener("error", function(e) {
		    var msg = "Error " + e.target.status.toString() + " occurred while receiving the document.";
		    Ext.Msg.alert(gettext('Error'), msg, function(btn) {
			me.close();
		    });
		});
 
		xhr.upload.addEventListener("progress", function(evt) {
		    if (evt.lengthComputable) {  
			var percentComplete = evt.loaded / evt.total;  
			updateProgress(percentComplete, evt.loaded);
		    } 
		}, false);

		xhr.open("POST", "/api2/json" + baseurl, true);
		xhr.send(fd);		
	    }
	});

	form.on('validitychange', function(f, valid) {
	    submitBtn.setDisabled(!valid);
	});

        Ext.applyIf(me, {
            title: gettext('Upload'),
	    items: me.formPanel,
	    buttons: [ abortBtn, submitBtn ],
	    listeners: {
		close: function() {
		    if (xhr) {
			xhr.abort();
		    }
		}
	    }
	});

        me.callParent();
    }
});

Ext.define('PVE.qemu.ISODownload', {
    extend: 'Ext.window.Window',
    alias: ['widget.pveQemuISODownload'],

    resizable: false,

    modal: true,

    initComponent : function() {
	/*jslint confusion: true */
        var me = this;


	if (!me.nodename) {
	    throw "no node name specified";
	}

	if (!me.vmid) { 
	    throw "no vmid specified";
	}

	var baseurl = "/nodes/" + me.nodename + "/qemu/" + me.vmid + "/isodl";

	me.formPanel = Ext.create('Ext.form.Panel', {
	    method: 'POST',
	    waitMsgTarget: true,
	    bodyPadding: 10,
	    border: false,
	    width: 300,
	    fieldDefaults: {
		labelWidth: 100,
		anchor: '100%'
            },
	    items: [
		{
		    xtype: 'textfield',
		    name: 'url',
		    blankText: gettext('http://example.org/debian.iso'),
		    allowBlank: false
		}
	    ]
	});

	var form = me.formPanel.getForm();

	var submitBtn = Ext.create('Ext.Button', {
	    text: gettext('Download'),
	    disabled: true,
	    handler: function(button) {
			var values = form.getValues();
			PVE.Utils.API2Request({
				url: "/nodes/" + me.nodename + "/qemu/" + me.vmid + "/isodl",
				params: { url: values.url },
				method: 'POST',
				waitMsgTarget: me,
				failure: function(response, opts) {
				Ext.Msg.alert('Error', response.htmlStatus);
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
	    }
	});
	
	form.on('validitychange', function(f, valid) {
	    submitBtn.setDisabled(!valid);
	});

        Ext.applyIf(me, {
            title: gettext('Download'),
	    items: me.formPanel,
	    buttons: [ submitBtn ],
	});

        me.callParent();
    }
});

Ext.define('PVE.qemu.MountISO', {
    extend: 'Ext.window.Window',

    resizable: false,

    initComponent : function() {
	var me = this;

	if (!me.nodename) {
	    throw "no node name specified";
	}

	if (!me.vmid) {
	    throw "no VM ID specified";
	}

	if (!me.volid) {
	    throw "no volid specified";
	}

	var cddriveselector = Ext.create('PVE.form.ISOSelector', {
	    name: 'cddrive',
	    nodename: me.nodename,
		vmid: me.vmid,
	    storageContent: 'iso',
	    fieldLabel: gettext('CD ROM Drive'),
	    labelAlign: 'right',
	    allowBlank: false
	});

	me.formPanel = Ext.create('Ext.form.Panel', {
	    bodyPadding: 10,
	    border: false,
	    fieldDefaults: {
		labelWidth: 100,
		anchor: '100%'
	    },
	    items: [
		cddriveselector
	    ]
	});

	var form = me.formPanel.getForm();

	var submitBtn = Ext.create('Ext.Button', {
	    text: gettext('Mount'),
	    handler: function(){
		var values = form.getValues();
		var params = { };
		params[values.cddrive] = me.volid + ',media=cdrom';

		PVE.Utils.API2Request({
		    url: '/nodes/' + me.nodename + '/qemu/' + me.vmid + '/config',
		    params: params,
		    method: 'PUT',
		    failure: function (response, opts) {
			Ext.Msg.alert('Error',response.htmlStatus);
		    },
		    success: function(response, options) {
			me.close();
		    }
		});
	    }
	});

	var title = gettext('Backup') + " " + 
	    ((me.vmtype === 'openvz') ? "CT" : "VM") +
	    " " + me.vmid;

	Ext.apply(me, {
	    title: title,
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

Ext.define('PVE.qemu.ISOTree', {
    extend: 'Ext.grid.GridPanel',
    alias: ['widget.pveQemuISOTree'],


    initComponent : function() {
	var me = this;

	var nodename = me.pveSelNode.data.node;
	if (!nodename) {
	    throw "no node name specified";
	}

	var vmid = me.pveSelNode.data.vmid;
	if (!vmid) {
	    throw "no VM ID specified";
	}

	me.store = Ext.create('Ext.data.Store', {
	    model: 'pve-storage-content',
	    sorters: { 
		property: 'volid', 
		order: 'DESC' 
	    }
	});

	var reload = Ext.Function.createBuffered(function() {
	    if (me.store.proxy.url) {
		me.store.load();
	    }
	}, 100);

	var loadISOTree = function() {
	    var url = '/api2/json/nodes/' + nodename + '/qemu/' + vmid + '/iso';

	    me.store.setProxy({
		type: 'pve',
		url: url
	    });

	    reload();
	};

	var sm = Ext.create('Ext.selection.RowModel', {});
	
	var pbar = Ext.create('Ext.ProgressBar', {
            text: 'Ready',
	    hidden: true
	});
	
	var mount_btn = Ext.create('PVE.button.Button', {
	    text: gettext('Mount'),
	    disabled: true,
	    selModel: sm,
	    handler: function(b, e, rec){
			if (!vmid) {
				return;
			}
			var volid = rec.data.volid;
			var win = Ext.create('PVE.qemu.MountISO', {
				nodename: nodename,
				vmid: vmid,
				volid: volid,
			});
			win.show();
		}
	});

	var upload_btn = Ext.create('Ext.button.Button', {
	    text: gettext('Upload'),
	    handler: function() {
			var win = Ext.create('PVE.qemu.ISOUpload', {
			    nodename: nodename,
			    vmid: vmid
			});
			win.on('destroy', reload);
			win.show();
	    }
	});
	
	var download_btn = Ext.create('Ext.button.Button', {
	    text: gettext('Download'),
	    handler: function() {
			var win = Ext.create('PVE.qemu.ISODownload', {
			    nodename: nodename,
			    vmid: vmid
			});
			win.on('destroy', reload);
			win.show();
	    }
	});

	var delete_btn = Ext.create('PVE.button.Button', {
	    text: gettext('Remove'),
	    disabled: true,
	    selModel: sm,
	    dangerous: true,	    
	    confirmMsg: function(rec) {
		var msg = Ext.String.format(gettext('Are you sure you want to remove entry {0}'),
					    "'" + rec.data.volid + "'");
		msg += " " + gettext('This will permanently erase all image data.');

		return msg;
	    },
	    enableFn: function(rec) {
		return !!rec;
	    },
	    handler: function(b, e, rec){

		if (!vmid) {
		    return;
		}

		var volid = rec.data.volid;
		PVE.Utils.API2Request({
		    url: "/nodes/" + nodename + "/qemu/" + vmid + "/iso?volume=" + volid,
		    method: 'DELETE',
		    waitMsgTarget: me,
		    failure: function(response, opts) {
			Ext.Msg.alert('Error', response.htmlStatus);
		    },
		    success: function(response, options) {
			reload();
		    }
		});
	    }
	});

	Ext.apply(me, {
	    stateful: false,
	    selModel: sm,
	    tbar: [ mount_btn, upload_btn, download_btn, delete_btn ],
	    columns: [
		{
		    header: gettext('Name'),
		    flex: 1,
		    sortable: true,
		    renderer: PVE.Utils.render_storage_content,
		    dataIndex: 'volid'
		},
		{
		    header: gettext('Format'),
		    width: 100,
		    dataIndex: 'format'
		},
		{
		    header: gettext('Size'),
		    width: 100,
		    renderer: PVE.Utils.format_size,
		    dataIndex: 'size'
		}
	    ],
	    listeners: {
		show: reload
	    }
	});

	me.callParent();
	loadISOTree();
    }
});
