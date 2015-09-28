Ext.define('PVE.window.DuoSecurityWindow', {
    extend: 'Ext.window.Window',

    // private
    onDuoAuth: function () {
        var me = this;

        var form = me.getComponent(0).getForm();

        if (form.isValid()) {
            me.el.mask(gettext('Authenticating...'), 'x-mask-loading');

            form.submit({
                params: {
                    username: me.username,
                    password: me.password,
                    realm: me.realm
                },
                failure: function (f, resp) {
                    me.el.unmask();

                    Ext.MessageBox.alert(gettext('Error'),
                        gettext("Login failed. Please try again"),
                        function () {
                            me.close();
                            Ext.create('PVE.window.LoginWindow').show();
                        });
                },
                success: function (f, resp) {
                    me.el.unmask();

                    var handler = me.handler || Ext.emptyFn;
                    handler.call(me, resp.result.data);
                    me.close();
                }
            });
        }
    },

    initComponent: function () {
        var me = this;

        var duoAuthenticationMethods = [];

        Object.keys(me.duoresponse.devices).forEach(function(key, index) {
            display_name = this[key]['display_name'];
            device_id = this[key]['device'];
            Object.keys(this[key].capabilities).forEach(function(key, index) {
                if(this[key] != 'mobile_otp') {
                    duoAuthenticationMethods.push({
                        boxLabel: display_name + ' via ' + this[key],
                        name: 'duoauthmethod',
                        inputValue: device_id + '_' + this[key]
                    });
                }
            }, this[key].capabilities);
        }, me.duoresponse.devices);

        duoAuthenticationMethods.push({
            boxLabel: 'Passcode',
            name: 'duoauthmethod',
            inputValue: 'passcode'
        });


        var duo_passcode_field = Ext.createWidget('textfield', { 
            fieldLabel: gettext('Passcode'), 
            name: 'duo_passcode',
            allowBlank: false,
            hidden: true
        });

        Ext.apply(me, {
            width: 700,
            modal: true,
            border: false,
            draggable: true,
            closable: false,
            resizable: false,
            layout: 'auto',
            title: gettext('Proxmox VE Two-Factor Authentication'),

            items: [{
                xtype: 'form',
                frame: true,
                url: '/api2/extjs/access/ticket',

                fieldDefaults: {
                    labelAlign: 'right'
                },

                defaults: {
                    anchor: '-5',
                    allowBlank: false
                },

                items: [
                    {
                        id: 'duoAuthenticationMethod',
                        xtype: 'radiogroup',
                        fieldLabel: 'Duo Authentication Method',
                        listeners: {
                            change: function(f, value) {
                                if (value.duoauthmethod == 'passcode') {
                                    duo_passcode_field.setVisible(true);
                                    duo_passcode_field.setDisabled(false);
                                } else {
                                    duo_passcode_field.setVisible(false);
                                    duo_passcode_field.setDisabled(true);
                                }
                            }
                        },
                        columns: 1,
                        vertical: true,
                        items: duoAuthenticationMethods
                    },
                    duo_passcode_field
                ],
                buttons: [
                    {
                        text: gettext('Authenticate'),
                        handler: function () {
                            me.onDuoAuth();
                        }
                    }
                ]
            }]
        });

        me.callParent();
    }
});
