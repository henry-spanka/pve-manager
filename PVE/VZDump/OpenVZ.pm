package PVE::VZDump::OpenVZ;

use strict;
use warnings;
use File::Path;
use File::Basename;
use PVE::INotify;
use PVE::VZDump;
use PVE::OpenVZ;
use PVE::Tools;

use base qw (PVE::VZDump::Plugin);

sub new {
    my ($class, $vzdump) = @_;
    
    PVE::VZDump::check_bin ('vzctl');

    my $self = bless PVE::OpenVZ::read_global_vz_config ();

    $self->{vzdump} = $vzdump;

    $self->{vmlist} = PVE::OpenVZ::config_list();

    return $self;
};

sub type {
    return 'openvz';
}

sub vm_status {
    my ($self, $vmid) = @_;

    my $status_text = '';
    $self->cmd (['vzctl', 'status', $vmid], outfunc => sub {$status_text .= shift; });
    chomp $status_text;

    my $running = $status_text =~ m/running/ ? 1 : 0;
   
    return wantarray ? ($running, $running ? 'running' : 'stopped') : $running; 
}

sub prepare {
    my ($self, $task, $vmid, $mode) = @_;

    my $dir = $self->{vmlist}->{$vmid}->{dir};

    my $conf = PVE::OpenVZ::load_config($vmid);

    die "Only ploop containers are supported" if $conf->{ve_layout}->{value} ne 'ploop';

	$task->{privatedir} = PVE::OpenVZ::get_privatedir($conf, $vmid);
    $task->{rootdir} = PVE::OpenVZ::get_rootdir($conf, $vmid);
    $task->{snapuuid} = PVE::OpenVZ::generateUUID();
}

sub lock_vm {
    my ($self, $vmid) = @_;

    my $filename = "$self->{lockdir}/${vmid}.lck";

    my $lockmgr = PVE::OpenVZ::create_lock_manager();

    $self->{lock} = $lockmgr->lock($filename) || die "can't lock VM ${vmid}\n";
}

sub unlock_vm {
    my ($self, $vmid) = @_;

    $self->{lock}->release();
}

# we use --skiplock for vzctl because we have already locked the VM
# by calling lock_vm()

sub stop_vm {
    my ($self, $task, $vmid) = @_;

    $self->cmd (['vzctl', '--skiplock', 'stop', $vmid]);
}

sub start_vm {
    my ($self, $task, $vmid) = @_;

    $self->cmd (['vzctl', '--skiplock', 'start', $vmid]);
}

sub suspend_vm {
    my ($self, $task, $vmid) = @_;

    $task->{cleanup}->{snapshot} = 1;
    $self->cmd( ['vzctl', '--skiplock', 'snapshot', $vmid, '--id', $task->{snapuuid}, '--name', 'vzdump', '--skip-config']);
}

sub snapshot {
    my ($self, $task, $vmid) = @_;

    $task->{cleanup}->{snapshot} = 1;
    $self->cmd( ['vzctl', '--skiplock', 'snapshot', $vmid, '--id', $task->{snapuuid}, '--name', 'vzdump', '--skip-config', '--skip-suspend']);
}

sub resume_vm {
    my ($self, $task, $vmid) = @_;

    # Don't need that
}

sub assemble {
    my ($self, $task, $vmid) = @_;

    my $dir = $task->{privatedir};
    my $conffile = PVE::OpenVZ::config_file($vmid);
    my $cfgdir = dirname ($conffile);

    mkpath "${dir}/vzdump/";

    $task->{cleanup}->{vzdump} = 1;

    $self->cmd (['cp', $conffile, "${dir}/vzdump/vps.conf"]);
    
    foreach my $s (PVE::OpenVZ::SCRIPT_EXT) {
        my $fn = "${cfgdir}/${vmid}.${s}";
        $self->cmd (['cp', $fn, "${dir}/vzdump/vps.${s}"]) if -f $fn;
    }

    if ($task->{mode} eq 'snapshot' || $task->{mode} eq 'suspend') {
        PVE::Tools::file_set_contents("${dir}/vzdump/snapshot.uuid", $task->{snapuuid}); # Used for restore process
    }
}

sub archive {
    my ($self, $task, $vmid, $filename, $comp) = @_;

    die "Invalid privatedir" if !$task->{privatedir};

    my $opts = $self->{vzdump}->{opts};
    my $bwl = $opts->{bwlimit}*1024; # bandwidth limit for cstream

    my $taropts = '--totals --sparse --numeric-owner --one-file-system';

    if ($task->{mode} eq 'snapshot' || $task->{mode} eq 'suspend') {
        my $ploopinfo = PVE::OpenVZ::getPloopInfo($vmid, $task->{privatedir}, $task->{rootdir});
        $taropts = "${taropts} --exclude=$ploopinfo->{top_delta}";
    }

    my $cmd = "tar cvpf - -C $task->{privatedir} ${taropts} ./"; 

    $cmd .= "|cstream -t ${bwl}" if $opts->{bwlimit};
    $cmd .= "|$comp" if $comp;

    sleep(1); # Just sleep to be sure IO has been flushed

    if ($opts->{stdout}) {
    $self->cmd ($cmd, output => ">&=" . fileno($opts->{stdout}));
    } else {
    $self->cmd ("${cmd} >${filename}");
    }
}

sub cleanup {
    my ($self, $task, $vmid) = @_;

    sleep(1); # Just sleep to be sure IO has been flushed

    if ($task->{cleanup}->{vzdump}) {
        my $dir = "$task->{privatedir}/vzdump";
        eval {
            rmtree $dir if -d $dir;
        };
        $self->logerr ($@) if $@;
    }

    if ($task->{cleanup}->{snapshot}) {
        eval {
            $self->cmd (['vzctl', '--skiplock', 'snapshot-delete', $vmid, '--id', $task->{snapuuid}]);
        };
        $self->logerr ($@) if $@;
    }
}

1;
