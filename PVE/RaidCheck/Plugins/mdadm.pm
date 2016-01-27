package PVE::RaidCheck::Plugins::mdadm;

use strict;
use warnings;

use PVE::RaidCheck::Plugin;

use base('PVE::RaidCheck::Plugin');

my $pluginname = 'mdadm';

my $mdstat = '/proc/mdstat';

sub getPluginName {
    return $pluginname;
}

sub check {
    my $self = shift;
    
    $self->scanMDs();

    $self->parse();

    return {
        status => $self->{status},
        health => $self->{health}
    };
}

sub canRun {
    my $self = shift;

    if (!-f $mdstat) {
        return 0;
    }
    return 1;
}

sub parse {
    my $self = shift;

    $self->setControllerStatus(0);
    $self->setCacheStatus(0);
    $self->setBatteryStatus(0);

    for my $key (keys $self->{arrays}) {
        my $array = $self->{arrays}->{$key};

        if ($array->{status} =~ /_/) {
            $self->setArrayStatus(3);
        } else {
            $self->setArrayStatus(1);
        }

        for my $disk (keys $array->{disks}) {
            if ($array->{disks}[$disk]->{flags} =~ /F/) {
                $self->setArrayStatus(3);
            } else {
                $self->setArrayStatus(1);
            }
        }
    }

    for my $status (values $self->{status}) {
        if ($status > $self->{health}) {
            $self->{health} = $status;
        }
    }
}

sub scanMDs {
    my $self = shift;

    my $res = {};
    my $currentarray;

    my $parserfunction = sub {
        my $line = shift;

        return if $line =~ /^Personalities\s:\s/;

        if ($line =~ m{^
            (\S+)\s+:\s+ # mdname
            (\S+)\s+     # active: "inactive", "active"
            (\((?:auto-)?read-only\)\s+)? # readonly
            (.+)         # personality name + disks
        }x) {
            my($dev, $active, $ro, $rest) = ($1, $2, $3, $4);
            my @parts = split /\s/, $rest;
            my $re = qr{^
                (\S+)           # devname
                (?:\[(\d+)\])   # desc_nr
                (?:\((.)\))?    # flags: (W|F|S) - WriteMostly, Faulty, Spare
            $}x;
            my @disks = ();
            my $personality;
            while (my($disk) = pop @parts) {
                last if !$disk;
                if ($disk !~ $re) {
                    $personality = $disk;
                    last;
                }
                my($dev, $number, $flags) = $disk =~ $re;
                push(@disks, {
                    'dev' => $dev,
                    'number' => int($number),
                    'flags' => $flags || '',
                });
            }

            return if @parts;

            # first line resets %md
            $res->{$dev} = {
                personality => $personality,
                readonly => $ro,
                active => $active,
                disks => [ @disks ]
            };

            $currentarray = $dev;
        }

        if ($line =~ m{^
            \s+(\d+)\sblocks\s+ # blocks
            # metadata version
            (super\s(?:
                (?:\d+\.\d+) | # N.M
                (?:external:\S+) |
                (?:non-persistent)
            ))?\s*
            (.+) # mddev->pers->status (raid specific)
        $}x) {
            # linux-2.6.33/drivers/md/dm-raid1.c, device_status_char
            # A => Alive - No failures
            # D => Dead - A write failure occurred leaving mirror out-of-sync
            # S => Sync - A sychronization failure occurred, mirror out-of-sync
            # R => Read - A read failure occurred, mirror data unaffected
            # U => for the rest
            my $status = $3;

            my ($s) = $status =~ /\s+\[([ADSRU_]+)\]/;

            $res->{$currentarray}->{status} = $s | '';

            return;
        }

    };

    PVE::Tools::run_command(
        ['/bin/cat', $mdstat],
        outfunc => $parserfunction
    );

    $self->{arrays} = $res;

}

1;
