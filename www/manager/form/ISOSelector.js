Ext.define('PVE.form.ISOSelector', {
    extend: 'PVE.form.ComboGrid',
    alias: ['widget.pveISOSelector'],

    reload: function() {
	var me = this;

	var url = '/api2/json/nodes/' + me.nodename + '/qemu/' + me.vmid + '/cddrives';

	me.store.setProxy({
	    type: 'pve',
	    url: url
	});

	me.store.load();
    },

    initComponent: function() {
	var me = this;
	
	var store = Ext.create('Ext.data.Store', {
	    model: 'pve-iso-content'
	});

	Ext.apply(me, {
	    store: store,
	    stateful: false,
	    allowBlank: false,
	    valueField: 'name',
	    displayField: 'name',
            listConfig: {
		columns: [
		    {
			header: gettext('Name'),
			dataIndex: 'name',
			hideable: false,
			width: 60,
		    },
		    {
			header: gettext('File'),
			flex: 1,
			dataIndex: 'file',
		    },
		    {
			header: gettext('Size'),
			width: 60, 
			dataIndex: 'size', 
			renderer: PVE.Utils.format_size 
		    }
		]
	    }
	});

        me.callParent();

	me.reload();
	}
}, function() {

    Ext.define('pve-iso-content', {
	extend: 'Ext.data.Model',
	fields: [ 
	    'media', 'interface', 'file', 'size',
	    {	
		name: 'name', 
	    }
	],
	idProperty: 'name'
    });

});
