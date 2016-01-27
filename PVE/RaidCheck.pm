package PVE::RaidCheck;

use strict;
use warnings;

use PVE::RaidCheck::Plugin;

use PVE::RaidCheck::Plugins::hpacucli;
use PVE::RaidCheck::Plugins::mdadm;

my $RAID_PLUGINS = {
    'hpacucli' => 'PVE::RaidCheck::Plugins::hpacucli',
    'mdadm' => 'PVE::RaidCheck::Plugins::mdadm'
};

sub new {
    my $self = shift;

    return bless {
        summary => {
            status => {
                cachestatus => 0,
                batterystatus => 0,
                arraystatus => 0,
                controllerstatus => 0
            },
            health => 0
        },
        plugins => {}
    }, $self;
}

sub checkRaids {
    my $self = shift;

    for my $key (keys $RAID_PLUGINS) {
        my $plugin = $RAID_PLUGINS->{$key}->new();

        my $result;

        next if !$plugin->canRun();

        eval {
            $result = $plugin->check();
        };
        if ($@) {
            print "Could not check RAID - $@";
            next;
        }

        my $pluginname = $plugin->getPluginName();
        $self->{plugins}->{$pluginname} = $result->{status};
        if ($result->{health} > $self->{summary}->{health}) {
            $self->{summary}->{health} = $result->{health};
        }

        for my $status (keys $self->{summary}->{status}) {
            if ($result->{status}->{$status} > $self->{summary}->{status}->{$status}) {
                $self->{summary}->{status}->{$status} = $result->{status}->{$status};
            }
        }
    }
}

1;
