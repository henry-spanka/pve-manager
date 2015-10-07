Ext.define('PVE.openvz.SnapshotTree', {
    extend: 'Ext.tree.Panel',
    alias: ['widget.pveOpenVZSnapshotTree'],

    load_delay: 3000,

    old_digest: '',

    sorterFn: function (rec1, rec2) {
        var v1 = rec1.data.date;
        var v2 = rec2.data.date;

        v1 = v1.replace(/[\s:-]/g, '');
        v2 = v2.replace(/[\s:-]/g, '');

        return (v1 > v2 ? 1 : (v1 < v2 ? -1 : 0));
    },

    reload: function (repeat) {
        var me = this;

        PVE.Utils.API2Request({
            url: '/nodes/' + me.nodename + '/openvz/' + me.vmid + '/snapshot',
            method: 'GET',
            failure: function (response, opts) {
                PVE.Utils.setErrorMask(me, response.htmlStatus);
                me.load_task.delay(me.load_delay);
            },
            success: function (response, opts) {
                PVE.Utils.setErrorMask(me, false);
                var digest = '';
                var idhash = {};
                var root = {name: '__root', expanded: true, children: []};
                Ext.Array.each(response.result.data, function (item) {
                    item.leaf = true;
                    item.children = [];
                    item.iconCls = 'x-tree-node-snapshot';
                    digest = digest + item.uuid + item.current;
                    idhash[item.uuid] = item;
                });

                if(digest !== me.old_digest) {
                    me.old_digest = digest;

                    Ext.Array.each(response.result.data, function (item) {
                        if (item.parent && idhash[item.parent]) {
                            var parent_item = idhash[item.parent];
                            parent_item.children.push(item);
                            parent_item.leaf = false;
                            parent_item.expanded = true;
                        } else {
                            root.children.push(item);
                        }
                    });
                    me.setRootNode(root);
                }

                me.load_task.delay(me.load_delay);
            }
        });

    },

    initComponent: function () {
        var me = this;

        me.nodename = me.pveSelNode.data.node;
        if (!me.nodename) {
            throw "no node name specified";
        }

        me.vmid = me.pveSelNode.data.vmid;
        if (!me.vmid) {
            throw "no CT ID specified";
        }

        me.load_task = new Ext.util.DelayedTask(me.reload, me);

        var sm = Ext.create('Ext.selection.RowModel', {});

        var valid_snapshot = function (record) {
            return record && record.data && record.data.uuid;
        };

        var switchBtn = new PVE.button.Button({
            text: gettext('Switch'),
            disabled: true,
            selModel: sm,
            enableFn: valid_snapshot,
            confirmMsg: function (rec) {
                var msg = Ext.String.format(gettext('Are you sure you want to switch to snapshot {0}'),
                    "'" + rec.data.name + "' (" + rec.data.uuid + ")");
                return msg;
            },
            handler: function (btn, event) {
                var rec = sm.getSelection()[0];
                if (!rec) {
                    return;
                }
                var snapuuid = rec.data.uuid;

                PVE.Utils.API2Request({
                    url: '/nodes/' + me.nodename + '/openvz/' + me.vmid + '/snapshot/' + snapuuid + '/switch',
                    method: 'POST',
                    waitMsgTarget: me,
                    callback: function () {
                        me.reload();
                    },
                    failure: function (response, opts) {
                        Ext.Msg.alert(gettext('Error'), response.htmlStatus);
                    },
                    success: function (response, options) {
                        var upid = response.result.data;
                        var win = Ext.create('PVE.window.TaskProgress', {upid: upid});
                        win.show();
                    }
                });
            }
        });

        var removeBtn = new PVE.button.Button({
            text: gettext('Remove'),
            disabled: true,
            selModel: sm,
            confirmMsg: function (rec) {
                var msg = Ext.String.format(gettext('Are you sure you want to remove snapshot {0}'),
                    "'" + rec.data.name + "' (" + rec.data.uuid + ")");
                return msg;
            },
            enableFn: valid_snapshot,
            handler: function (btn, event) {
                var rec = sm.getSelection()[0];
                if (!rec) {
                    return;
                }
                var snapuuid = rec.data.uuid;

                PVE.Utils.API2Request({
                    url: '/nodes/' + me.nodename + '/openvz/' + me.vmid + '/snapshot/' + snapuuid,
                    method: 'DELETE',
                    waitMsgTarget: me,
                    callback: function () {
                        me.reload();
                    },
                    failure: function (response, opts) {
                        Ext.Msg.alert(gettext('Error'), response.htmlStatus);
                    },
                    success: function (response, options) {
                        var upid = response.result.data;
                        var win = Ext.create('PVE.window.TaskProgress', {upid: upid});
                        win.show();
                    }
                });
            }
        });

        var snapshotBtn = Ext.create('Ext.Button', {
            id: 'snapshotBtn',
            text: gettext('Take Snapshot'),
            disabled: false,
            handler: function () {
                var win = Ext.create('PVE.openvz.SnapshotWindow', {
                    nodename: me.nodename,
                    vmid: me.vmid
                });
                win.show();
            }
        });

        Ext.apply(me, {
            layout: 'fit',
            rootVisible: false,
            animate: false,
            sortableColumns: false,
            selModel: sm,
            tbar: [snapshotBtn, switchBtn, removeBtn],
            fields: [
                'name', 'current', 'date', 'uuid',
            ],
            columns: [
                {
                    xtype: 'treecolumn',
                    text: gettext('Name'),
                    dataIndex: 'name',
                    width: 200
                },
                {
                    text: gettext('Current'),
                    align: 'center',
                    resizable: false,
                    dataIndex: 'current',
                    width: 50,
                    renderer: function (value, metaData, record) {
                        return PVE.Utils.format_boolean(value);
                    }
                },
                {
                    text: gettext('Date'),
                    dataIndex: 'date',
                    resizable: false,
                    width: 210,
                },
                {
                    text: gettext('UUID'),
                    dataIndex: 'uuid',
                    flex: 1,
                }
            ],
            columnLines: true, // will work in 4.1?
            listeners: {
                show: me.reload,
                hide: me.load_task.cancel,
                destroy: me.load_task.cancel,
                // disable collapse
                beforeitemcollapse: function () {
                    return false;
                },
            }
        });

        me.callParent();

        me.store.sorters.add(new Ext.util.Sorter({
            sorterFn: me.sorterFn
        }));
    }
});

