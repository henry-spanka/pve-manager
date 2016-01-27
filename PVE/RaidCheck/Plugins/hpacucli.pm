package PVE::RaidCheck::Plugins::hpacucli;

use strict;
use warnings;

use PVE::RaidCheck::Plugin;

use base('PVE::RaidCheck::Plugin');

my $binary = '/usr/sbin/hpacucli';
my $pluginname = 'hpacucli';

sub getPluginName {
    return $pluginname;
}

sub check {
    my $self = shift;
    
    $self->scanControllers();

    $self->parse();

    return {
        status => $self->{status},
        health => $self->{health}
    };
}

sub canRun {
    my $self = shift;

    if (!-X $binary) {
        return 0;
    }

    eval {
        system("${binary} controller all show status >/dev/null"); # Check if any controllers exist
    };

    return $? ? 0 : 1;
}

sub parse {
    my $self = shift;

    for my $controller (keys $self->{controllers}) {
        my $ctrl = $self->{controllers}->{$controller};

        # Check Controller and Cache/Battery
        if (defined($ctrl->{controllerstatus})) {
            if ($ctrl->{controllerstatus} eq 'OK') {
                $self->setControllerStatus(1);
            } else {
                $self->setControllerStatus(3);
            }
        }
        if (defined($ctrl->{cachestatus})) {
            if ($ctrl->{cachestatus} eq 'OK') {
                $self->setCacheStatus(1);
            } else {
                $self->setCacheStatus(3);
            }
        }
        if (defined($ctrl->{batterystatus})) {
            if ($ctrl->{batterystatus} eq 'OK') {
                $self->setBatteryStatus(1);
            } else {
                $self->setBatteryStatus(3);
            }
        }

        # Check normal Arrays
        for my $array (keys $ctrl->{arrays}) {
            if ($ctrl->{arrays}->{$array}->{status} eq 'OK') {
                $self->setArrayStatus(1);
            } else {
                $self->setArrayStatus(3);
            }

            # Check non-normal arrays
            for my $ld (keys $ctrl->{arrays}->{$array}->{lds}) {
                if ($ctrl->{arrays}->{$array}->{lds}->{$ld}->{status} eq 'OK') {
                    $self->setArrayStatus(1);
                } else {
                    $self->setArrayStatus(3);
                }
            }
        }
    }

    for my $status (values $self->{status}) {
        if ($status > $self->{health}) {
            $self->{health} = $status;
        }
    }
}

sub scanControllers {
    my $self = shift;

    my $res;
    my $currentslot;

    my $parserfunction = sub {
        my $line = shift;

        if ($line =~ /^(\S.+) in Slot (.+)/) {
            my ($slot, $name) = ($2, $1);
            $slot =~ s/ \(RAID Mode\)//;
            $slot =~ s/ \(Embedded\)//;
            $currentslot = $slot;

            my $arrays = $self->scanArraysOfSlot($slot);
            $res->{$slot}->{name} = $name;
            $res->{$slot}->{arrays} = $arrays;
            return;
        }
        if ($line =~ /\s+Controller\sStatus:\s(\S+)$/) {
            $res->{$currentslot}->{controllerstatus} = $1;
            return;
        }
        if ($line =~ /\s+Cache\sStatus:\s(\S+)$/) {
            $res->{$currentslot}->{cachestatus} = $1;
            return;
        }
        if ($line =~ /\s+Battery\/Capacitor\sStatus:\s(\S+)/) {
            $res->{$currentslot}->{batterystatus} = $1;
        }

    };

    PVE::Tools::run_command(
        [$binary, 'controller', 'all', 'show', 'status'],
        outfunc => $parserfunction
    );

    $self->{controllers} = $res;
}

sub scanArraysOfSlot {
    my $self = shift;
    my $slot = shift;

    my $res = $self->{controllers}->{$slot};
    my $currentarray;

    my $parserfunction = sub {
        my $line = shift;

        if ($line =~ /^\s+array (\S+)(?:\s*\((\S+)\))?$/) {
            my ($array, $status) = ($1, $2);
            $currentarray = $array;
            $res->{$array}->{status} = $status || 'OK';
            return;
        }

        if ($line =~ /^\s+logicaldrive (\d+) \([\d.]+ .B, [^,]+, ([^\)]+)\)$/) {
            my ($drive, $status) = ($1, $2);
            $res->{$currentarray}->{lds}->{$drive}->{status} = $status;
        }
    };

    PVE::Tools::run_command(
        [$binary, 'controller', "slot=${slot}", 'logicaldrive', 'all', 'show'],
        outfunc => $parserfunction
    );

    return $res;

}

1;
