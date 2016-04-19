package PVE::TemperatureCheck::Plugin;

use strict;
use warnings;

use PVE::Tools;

sub new {
    my $self = shift;

    return bless { }, $self;
}

sub check {
    die "implement in subclass";
}

1;
