package PVE::TemperatureCheck::Plugins::hp_health;

use strict;
use warnings;

use PVE::TemperatureCheck::Plugin;

use base('PVE::TemperatureCheck::Plugin');

my $binary = '/sbin/hpasmcli';
my $pluginname = 'hpasmcli';

sub getPluginName {
    return $pluginname;
}

sub check {
    my $self = shift;

    $self->readTemperatures();
    $self->readPowerMeters();
    $self->readFans();

    return {
        temperatures => $self->{temperatures},
        powermeters => $self->{powermeters},
        fans => $self->{fans}
    };
}

sub canRun {
    my $self = shift;

    if (!-X $binary) {
        return 0;
    }

    return $? ? 0 : 1;
}

sub readTemperatures {
    my $self = shift;

    my $parserfunction = sub {
        my $line = shift;

        if ($line =~ /^#([0-9]+)\s+([A-Z_#]+\d*)\s+(\d+)C\/\d+F\s+\d+C\/\d+F/) {
            my ($id, $name, $value) = ($1, $2, $3);
            $name =~ tr/#/_/;
            $self->{temperatures}->{"${id}_${name}"} = $value;
        }

    };

    PVE::Tools::run_command(
        [$binary, '-s', 'SHOW TEMP'],
        outfunc => $parserfunction
    );
}

sub readPowerMeters {
    my $self = shift;

    my $currentmeter;

    my $parserfunction = sub {
        my $line = shift;

        if ($line =~ /^Power Meter #(\d+)/) {
            $currentmeter = $1;
        }
        if ($line =~ /^\sPower Reading\s+:\s(\d+)/) {
            $self->{powermeters}->{$currentmeter}->{powerreading} = $1;
        }

    };

    PVE::Tools::run_command(
        [$binary, '-s', 'SHOW POWERMETER'],
        outfunc => $parserfunction
    );
}

sub readFans {
    my $self = shift;

    my $currentmeter;

    my $parserfunction = sub {
        my $line = shift;

        if ($line =~ /^#(\d+)\s+([A-Z_#\/]+)\s+Yes\s+[A-Z]+\s+(\d+)%\s+/) {
            my ($id, $name, $value) = ($1, $2, $3);
            $name =~ tr/#/_/;
            $name =~ tr/\//_/;
            $self->{fans}->{"${id}_${name}"} = $value;
        }

    };

    PVE::Tools::run_command(
        [$binary, '-s', 'SHOW FAN'],
        outfunc => $parserfunction
    );
}

1;
