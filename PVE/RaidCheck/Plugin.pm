package PVE::RaidCheck::Plugin;

use strict;
use warnings;

use PVE::Tools;

sub new {
    my $self = shift;

    return bless {
        status => {
            cachestatus => 0,
            batterystatus => 0,
            arraystatus => 0,
            controllerstatus => 0
        },
        health => 0
    }, $self;
}

sub check {
    die "implement in subclass";
}

sub setStatusOfProperty {
    my $self = shift;
    my $property = shift;
    my $status = shift;

    if ($status > $self->{status}{$property})  {
        $self->{status}->{$property} = $status;
    }
}

sub setControllerStatus {
    my $self = shift;
    my $status = shift;
    $self->setStatusOfProperty('controllerstatus', $status);
}

sub setArrayStatus {
    my $self = shift;
    my $status = shift;
    $self->setStatusOfProperty('arraystatus', $status);
}

sub setCacheStatus {
    my $self = shift;
    my $status = shift;
    $self->setStatusOfProperty('cachestatus', $status);
}

sub setBatteryStatus {
    my $self = shift;
    my $status = shift;
    $self->setStatusOfProperty('batterystatus', $status);
}

1;