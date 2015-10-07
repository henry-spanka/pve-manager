Ext.define('PVE.openvz.SnapshotWindow', {
    extend: 'Ext.window.Window',

    resizable: false,

    take_snapshot: function (name, skipsuspend) {
        var me = this;
        var params = {name: name, skipsuspend: skipsuspend};

        PVE.Utils.API2Request({
            params: params,
            url: '/nodes/' + me.nodename + '/openvz/' + me.vmid + "/snapshot",
            waitMsgTarget: me,
            method: 'POST',
            failure: function (response, opts) {
                Ext.Msg.alert(gettext('Error'), response.htmlStatus);
            },
            success: function (response, options) {
                var upid = response.result.data;
                var win = Ext.create('PVE.window.TaskProgress', {upid: upid});
                win.show();
                me.close();
            }
        });
    },

    initComponent: function () {
        var me = this;

        if (!me.nodename) {
            throw "no node name specified";
        }

        if (!me.vmid) {
            throw "no VM ID specified";
        }

        var items = [
            {
                xtype: 'textfield',
                name: 'name',
                fieldLabel: gettext('Name'),
                vtype: 'StorageId',
                allowBlank: true
            },
            {
                xtype: 'pvecheckbox',
                name: 'skipsuspend',
                uncheckedValue: 0,
                defaultValue: 0,
                checked: 0,
                fieldLabel: gettext('Skip Suspend')
            }
        ];

        me.formPanel = Ext.create('Ext.form.Panel', {
            bodyPadding: 10,
            border: false,
            fieldDefaults: {
                labelWidth: 100,
                anchor: '100%'
            },
            items: items
        });

        var form = me.formPanel.getForm();

        me.title = "CT " + me.vmid + ': ' + gettext('Take Snapshot');
        var submitBtn = Ext.create('Ext.Button', {
            text: gettext('Take Snapshot'),
            handler: function () {
                if (form.isValid()) {
                    var values = form.getValues();
                    me.take_snapshot(values.name, values.skipsuspend);
                }
            }
        });

        Ext.apply(me, {
            modal: true,
            width: 450,
            border: false,
            layout: 'fit',
            buttons: [submitBtn],
            items: [me.formPanel]
        });

        me.callParent();
    }
});
