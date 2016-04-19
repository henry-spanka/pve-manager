package PVE::TemperatureCheck;

use strict;
use warnings;

use PVE::TemperatureCheck::Plugin;

use PVE::TemperatureCheck::Plugins::hp_health;

my $TEMP_PLUGINS = {
    'hp' => 'PVE::TemperatureCheck::Plugins::hp_health'
};

sub new {
    my $self = shift;

    return bless {
        plugins => {}
    }, $self;
}

sub check {
    my $self = shift;

    for my $key (keys $TEMP_PLUGINS) {
        my $plugin = $TEMP_PLUGINS->{$key}->new();

        my $result;

        next if !$plugin->canRun();

        eval {
            $result = $plugin->check();
        };
        if ($@) {
            print "Could not check Temperature - $@";
            next;
        }

        my $pluginname = $plugin->getPluginName();
        $self->{plugins}->{$pluginname} = $result;
    }
}

1;
