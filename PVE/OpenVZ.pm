package PVE::OpenVZ;

use strict;
use LockFile::Simple;
use File::stat qw();
use File::Basename qw(dirname);
use File::Path qw(remove_tree rmtree mkpath);
use POSIX qw (LONG_MAX);
use IO::Dir;
use IO::File;
use PVE::Tools qw(run_command extract_param $IPV6RE $IPV4RE);
use PVE::ProcFSTools;
use PVE::Cluster qw(cfs_register_file cfs_read_file);
use PVE::SafeSyslog;
use PVE::INotify;
use PVE::JSONSchema;
use Digest::SHA;
use Encode;
use Data::UUID;
use PVE::Mounts;

use constant SCRIPT_EXT => qw (start stop mount umount premount postumount);

my $cpuinfo = PVE::ProcFSTools::read_cpuinfo();
my $nodename = PVE::INotify::nodename();
my $global_vzconf = read_global_vz_config();
my $res_unlimited = LONG_MAX;

sub config_list {
    my $vmlist = PVE::Cluster::get_vmlist();
    my $res = {};
    return $res if !$vmlist || !$vmlist->{ids};
    my $ids = $vmlist->{ids};

    foreach my $vmid (keys %$ids) {
	next if !$vmid; # skip VE0
	my $d = $ids->{$vmid};
	next if !$d->{node} || $d->{node} ne $nodename;
	next if !$d->{type} || $d->{type} ne 'openvz';
	$res->{$vmid}->{type} = 'openvz';
    }
    return $res;
}

sub cfs_config_path {
    my ($vmid, $node) = @_;

    $node = $nodename if !$node;
    return "nodes/$node/openvz/$vmid.conf";
}

sub config_file {
    my ($vmid, $node) = @_;

    my $cfspath = cfs_config_path($vmid, $node);
    return "/etc/pve/$cfspath";
}

sub load_config {
    my ($vmid) = @_;

    my $cfspath = cfs_config_path($vmid);

    my $conf = PVE::Cluster::cfs_read_file($cfspath);
    die "container $vmid does not exists\n" if !defined($conf);

    return $conf;
}

sub check_mounted {
    my ($conf, $vmid) = @_;

    my $root = get_rootdir($conf, $vmid);
    return (-d "$root/etc" || -d "$root/proc");
}

# warning: this is slow
sub check_running {
    my ($vmid) = @_;

    if (my $fh = new IO::File ("/proc/vz/vestat", "r")) {
	while (defined (my $line = <$fh>)) {
	    if ($line =~ m/^\s*(\d+)\s+/) {
		if ($vmid == $1) {
		    close($fh);
		    return 1;
		}
	    }
	}
	close($fh);
    }
    return undef;
}

sub get_privatedir {
    my ($conf, $vmid) = @_;

    my $private = $global_vzconf->{privatedir};
    if ($conf->{ve_private} && $conf->{ve_private}->{value}) {
	$private = $conf->{ve_private}->{value};
    }
    $private =~ s/\$VEID/$vmid/;

    return $private;
}

sub get_rootdir {
    my ($conf, $vmid) = @_;

    my $root = $global_vzconf->{rootdir};
    if ($conf && $conf->{ve_root} && $conf->{ve_root}->{value}) {
	$root = $conf->{ve_root}->{value};
    }
    $root =~ s/\$VEID/$vmid/;

    return $root;
}

sub get_disk_quota {
    my ($conf) = @_;

    my $disk_quota = $global_vzconf->{disk_quota};
    if ($conf->{disk_quota} && defined($conf->{disk_quota}->{value})) {
	$disk_quota = $conf->{disk_quota}->{value};
    }

    return $disk_quota;
}

sub deleteContainerFiles {
    my ($conf, $vmid) = @_;

    eval {
        my $rootdir = get_rootdir($conf, $vmid);

        die "invalid root dir\n" if !$rootdir || !-d $rootdir;

        my $cmd = ['chattr', '-ia', '-R', $rootdir];

        # Ignore any errors for this command
        eval {
            run_command($cmd, output => '/dev/null 2&>1', errfunc => sub {}, outfunc => sub {});
        };

        remove_tree($rootdir, {keep_root => 1, error => \my $errors} );
        die "unable to remove container files\n" if @$errors;
    };
    if (my $err = $@) {
        die $err;
    }

}

sub read_user_beancounters {
    my $ubc = {};

    if (my $fh = IO::File->new ("/proc/bc/resources", "r")) {
	my $vmid;
	while (defined (my $line = <$fh>)) {
	    if ($line =~ m|\s*((\d+):\s*)?([a-z]+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)$|) {
		$vmid = $2 if defined($2);
		next if !defined($vmid);
		my ($name, $held, $maxheld, $bar, $lim, $failcnt) = (lc($3), $4, $5, $6, $7, $8);
		next if $name eq 'dummy';
		$ubc->{$vmid}->{failcntsum} += $failcnt;
		$ubc->{$vmid}->{$name} = {
		    held => $held,
		    maxheld => $maxheld,
		    bar => $bar,
		    lim => $lim,
		    failcnt => $failcnt,
		};
	    }
	}
	close($fh);
    }

    return $ubc;
}

sub read_container_network_usage {
    my ($vmid) = @_;

    my $recv = 0;
    my $trmt = 0;
    my $recvpkts = 0;
    my $trmtpkts = 0;

    my $netparser = sub {
		my $line = shift;
		if ($line =~ m/^\s*(.*):\s*(\d+)\s+(\d+)\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+(\d+)\s+(\d+)\s+/) {
		    my $interface = $1;
		    my $received = $2;
		    my $receivedpkts = $3;
		    my $transmitted = $4;
		    my $transmittedpkts = $5;
		    return if $1 eq 'lo';
		    return if $1 !~ m/^eth[\d]+|veth[\d]+|venet[\d]+$/i;
		    $recv += $received;
		    $trmt += $transmitted;
		    $recvpkts += $receivedpkts;
		    $trmtpkts += $transmittedpkts;
		}
    };

    # fixme: can we get that info directly (with vzctl exec)?
    my $cmd = ['/usr/bin/timeout', '3', '/usr/sbin/vzctl', 'exec', $vmid, '/bin/cat', '/proc/net/dev'];
    eval { run_command($cmd, outfunc => $netparser); };
    my $err = $@;
    syslog('err', $err) if $err;

    return ($recv, $trmt, $recvpkts, $trmtpkts);
};

sub read_container_ioacct_stat {
    my ($vmid) = @_;

    my $read = 0;
    my $write = 0;

    my $filename = "/proc/bc/$vmid/ioacct";
    if (my $fh = IO::File->new ($filename, "r")) {

    	while (defined (my $line = <$fh>)) {
    	    if ($line =~ m/^\s+read\s+(\d+)$/) {
    		  $read += $1;
    	    } elsif ($line =~ m/^\s+dirty\s+(\d+)$/) { # write is not correct. Don't know if dirty is better ;(
    		  $write += $1;
    	    }
    	}
    }

    return ($read, $write);
};

sub read_diskusages {
    my $result = {};

    my $diskparser = sub {
        my $line = shift;
        if ($line =~ m/^\s+(\d+)\s+(\d+)\s+(\d+)$/) {
            $result->{$1}->{disk} = $2 * 1024;
            $result->{$1}->{maxdisk} = $3 * 1024;
        }
    };

    my $cmd = ['vzlist', '-a', '-H', '-o', 'ctid,diskspace,diskspace.h'];

    eval {
        run_command($cmd, outfunc => $diskparser);
    };
    my $err = $@;
    syslog('err', $err) if $err;

    return $result;
};

my $last_proc_vestat = {};

sub vmstatus {
    my ($opt_vmid) = @_;

    my $list = $opt_vmid ? { $opt_vmid => { type => 'openvz' }} : config_list();

    my $cpucount = $cpuinfo->{cpus} || 1;

    foreach my $vmid (keys %$list) {
    	next if $opt_vmid && ($vmid ne $opt_vmid);

    	my $d = $list->{$vmid};
    	$d->{status} = 'stopped';

    	my $cfspath = cfs_config_path($vmid);
    	if (my $conf = PVE::Cluster::cfs_read_file($cfspath)) {
    	    $d->{name} = $conf->{hostname}->{value} || "CT$vmid";
    	    $d->{name} =~ s/[\s]//g;

    	    $d->{cpus} = $conf->{cpus}->{value} || 1;
    	    $d->{cpus} = $cpucount if $d->{cpus} > $cpucount;

    	    $d->{disk} = 0;
    	    $d->{maxdisk} = int($conf->{diskspace}->{bar} * 1024);

    	    $d->{mem} = 0;
    	    $d->{swap} = 0;

    	    ($d->{maxmem}, $d->{maxswap}) = ovz_config_extract_mem_swap($conf);

    	    $d->{nproc} = 0;
    	    $d->{failcnt} = 0;

    	    $d->{uptime} = 0;
    	    $d->{cpu} = 0;
            $d->{cpulimit} = $conf->{cpulimit}->{value} || 0;

    	    $d->{netout} = 0;
    	    $d->{netin} = 0;

    	    $d->{pktsout} = 0;
    	    $d->{pktsin} = 0;

    	    $d->{diskread} = 0;
    	    $d->{diskwrite} = 0;

    	    if (my $ip = $conf->{ip_address}->{value}) {
    		  $ip =~ s/,;/ /g;
    		  $d->{ip} = (split(/\s+/, $ip))[0];
    	    } else {
    		  $d->{ip} = '-';
    	    }

    	    $d->{status} = 'mounted' if check_mounted($conf, $vmid);

    	} else {
    	    delete $list->{$vmid};
    	}
    }

    my $maxpages = ($res_unlimited / 4096);
    my $ubchash = read_user_beancounters();
    foreach my $vmid (keys %$ubchash) {
        my $d = $list->{$vmid};
        my $ubc = $ubchash->{$vmid};
        if ($d && defined($d->{status}) && $ubc) {
            $d->{failcnt} = $ubc->{failcntsum};
            $d->{mem} = $ubc->{physpages}->{held} * 4096;
            if ($ubc->{swappages}->{held} < $maxpages) {
	           $d->{swap} = $ubc->{swappages}->{held} * 4096
            }
            $d->{nproc} = $ubc->{numproc}->{held};
	   }
    }

    my $diskusageshash = read_diskusages();

    foreach my $vmid (keys %$diskusageshash) {
        my $d = $list->{$vmid};
        my $diskusage = $diskusageshash->{$vmid};
        $d->{disk} = $diskusage->{disk};
        $d->{maxdisk} = $diskusage->{maxdisk};
    }

    # Note: OpenVZ does not use POSIX::_SC_CLK_TCK
    my $hz = 1000;

    # see http://wiki.openvz.org/Vestat
    if (my $fh = new IO::File ("/proc/vz/vestat", "r")) {
    	while (defined (my $line = <$fh>)) {
    	    if ($line =~ m/^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+/) {
        		my $vmid = $1;
        		my $user = $2;
        		my $nice = $3;
        		my $system = $4;
        		my $ut = $5;
        		my $sum = $8*$cpucount; # uptime in jiffies * cpus = available jiffies
        		my $used = $9; # used time in jiffies

        		my $uptime = int ($ut / $hz);

        		my $d = $list->{$vmid};
        		next if !($d && defined($d->{status}));

        		$d->{status} = 'running';
        		$d->{uptime} = $uptime;

        		if (!defined ($last_proc_vestat->{$vmid}) ||
        		    ($last_proc_vestat->{$vmid}->{sum} > $sum)) {
        		    $last_proc_vestat->{$vmid} = { used => 0, sum => 0, cpu => 0 };
        		}

        		my $diff = $sum - $last_proc_vestat->{$vmid}->{sum};

        		if ($diff > 1000) { # don't update too often
        		    my $useddiff = $used - $last_proc_vestat->{$vmid}->{used};
                    my $cpu;
                    if ($d->{cpulimit} && $d->{cpulimit} > 0) {
    		          $cpu = (($useddiff/$diff) * $cpucount) / $d->{cpus} / ($d->{cpulimit} / $d->{cpus} / 100);
                    } else {
                      $cpu = (($useddiff/$diff) * $cpucount) / $d->{cpus};
                    }
        		    $last_proc_vestat->{$vmid}->{sum} = $sum;
        		    $last_proc_vestat->{$vmid}->{used} = $used;
        		    $last_proc_vestat->{$vmid}->{cpu} = $d->{cpu} = $cpu;
        		} else {
        		    $d->{cpu} = $last_proc_vestat->{$vmid}->{cpu};
        		}
    	    }
    	}
    	close($fh);
    }

    foreach my $vmid (keys %$list) {
    	my $d = $list->{$vmid};
    	next if !$d || !$d->{status} || $d->{status} ne 'running';
    	($d->{netin}, $d->{netout}, $d->{pktsin}, $d->{pktsout}) = read_container_network_usage($vmid);
    	($d->{diskread}, $d->{diskwrite}) = read_container_ioacct_stat($vmid);
    }

    return $list;
}

my $confdesc = {
    onboot => {
	optional => 1,
	type => 'boolean',
	description => "Specifies whether a VM will be started during system bootup.",
	default => 0,
    },
    cpus => {
	optional => 1,
	type => 'integer',
	description => "The number of CPUs for this container.",
	minimum => 1,
	default => 1,
    },
    cpuunits => {
	optional => 1,
	type => 'integer',
	description => "CPU weight for a VM. Argument is used in the kernel fair scheduler. The larger the number is, the more CPU time this VM gets. Number is relative to weights of all the other running VMs.\n\nNOTE: You can disable fair-scheduler configuration by setting this to 0.",
	minimum => 0,
	maximum => 500000,
	default => 1000,
    },
    cpulimit => {
	optional => 1,
	type => 'integer',
	description => "Absolute cpu maximum limit for a container (percent)",
	minimum => 0,
	default => 100,
    },
    memory => {
	optional => 1,
	type => 'integer',
	description => "Amount of RAM for the VM in MB.",
	minimum => 16,
	default => 512,
    },
    swap => {
	optional => 1,
	type => 'integer',
	description => "Amount of SWAP for the VM in MB.",
	minimum => 0,
	default => 512,
    },
    disk => {
	optional => 1,
	type => 'number',
	description => "Amount of disk space for the VM in GB. A zero indicates no limits.",
	minimum => 0,
	default => 2,
    },
    quotatime => {
	optional => 1,
	type => 'integer',
	description => "Set quota grace period (seconds).",
	minimum => 0,
    },
    quotaugidlimit => {
	optional => 1,
	type => 'integer',
	description => "Set maximum number of user/group IDs in a container for which disk quota inside the container will be accounted. If this value is set to 0, user and group quotas inside the container will not.",
	minimum => 0,
    },
    hostname => {
	optional => 1,
	description => "Set a host name for the container.",
	type => 'string', format => 'pve-openvz-hostname',
	maxLength => 255,
    },
    description => {
	optional => 1,
	type => 'string',
	description => "Container description. Only used on the configuration web interface.",
    },
    searchdomain => {
	optional => 1,
	type => 'string', format => 'pve-openvz-hostname',
	description => "Sets DNS search domains for a container. Create will automatically use the setting from the host if you neither set searchdomain or nameserver.",
    },
    nameserver => {
	optional => 1,
	type => 'string', format => 'pve-openvz-nameserver',
	description => "Sets DNS server IP address for a container. Create will automatically use the setting from the host if you neither set searchdomain or nameserver.",
    },
    ip_address => {
	optional => 1,
	type => 'string',
	description => "Specifies the address the container will be assigned.",
    },
    netif => {
	optional => 1,
	type => 'string', format => 'pve-openvz-netif',
	description => "Specifies network interfaces for the container.",
    },
    devices => {
	optional => 1,
	type => 'string',
	description => "Specifies devices for the container",
    },
    devnodes => {
	optional => 1,
	type => 'string',
	description => "Specifies devnodes for the container.",
    },
    capability => {
	optional => 1,
	type => 'string',
    description => "Specifies capabilitys for the container.",
    },
    features => {
        optional => 1,
        type => 'string',
        description => "Specifies features for the container.",
    },
    iolimit => {
    	optional => 1,
    	type => 'integer',
    	description => 'IO Limit of the container in MegaBytes'
    },
    iopslimit => {
    	optional => 1,
    	type => 'integer',
    	description => 'IOPS Limit of the container'
    },
    vm_overcommit => {
        optional => 1,
        minimum => 1,
        type => 'number',
        description => 'Set VM overcommitment value to float. If set, it is used to calculate privmmpages parameter in case it is not set explicitly. Default value is 0, meaning unlimited privvmpages.'
    },
};

# add JSON properties for create and set function
sub json_config_properties {
    my $prop = shift;

    foreach my $opt (keys %$confdesc) {
	$prop->{$opt} = $confdesc->{$opt};
    }

    return $prop;
}

# read global vz.conf
sub read_global_vz_config {

    my $res = {
	rootdir => '/var/lib/vz/root/$VEID', # note '$VEID' is a place holder
	privatedir => '/var/lib/vz/private/$VEID', # note '$VEID' is a place holder
	dumpdir => '/var/lib/vz/dump',
	lockdir => '/var/lib/vz/lock',
	disk_quota => 1,
    };

    my $filename = "/etc/vz/vz.conf";

    return $res if ! -f $filename;

    my $data = PVE::Tools::file_get_contents($filename);

    if ($data =~ m/^\s*VE_PRIVATE=(.*)$/m) {
	my $dir = $1;
	$dir =~ s/^\"(.*)\"/$1/;
	if ($dir !~ m/\$VEID/) {
	    warn "VE_PRIVATE does not contain '\$VEID' ('$dir')\n";
	} else {
	    $res->{privatedir} = $dir;
	}
    }
    if ($data =~ m/^\s*VE_ROOT=(.*)$/m) {
	my $dir = $1;
	$dir =~ s/^\"(.*)\"/$1/;
	if ($dir !~ m/\$VEID/) {
	    warn "VE_ROOT does not contain '\$VEID' ('$dir')\n";
	} else {
	    $res->{rootdir} = $dir;
	}
    }
    if ($data =~ m/^\s*DUMPDIR=(.*)$/m) {
	my $dir = $1;
	$dir =~ s/^\"(.*)\"/$1/;
	$dir =~ s|/\$VEID$||;
	$res->{dumpdir} = $dir;
    }
    if ($data =~ m/^\s*LOCKDIR=(.*)$/m) {
	my $dir = $1;
	$dir =~ s/^\"(.*)\"/$1/;
	$res->{lockdir} = $dir;
    }
    if ($data =~ m/^\s*DISK_QUOTA=(no|false|off|0)$/m) {
	$res->{disk_quota} = 0;
    }

    return $res;
};

sub parse_netif {
    my ($data, $vmid) = @_;

    my $res = {};
    return $res if !$data;

    my $host_ifnames = {};

    my $find_next_hostif_name = sub {
	for (my $i = 0; $i < 100; $i++) {
	    my $name = "veth${vmid}.$i";
	    if (!$host_ifnames->{$name}) {
		$host_ifnames->{$name} = 1;
		return $name;
	    }
	}

	die "unable to find free host_ifname"; # should not happen
    };

    foreach my $iface (split (/;/, $data)) {
	my $d = {};
	foreach my $pv (split (/,/, $iface)) {
	    if ($pv =~ m/^(ifname|mac|bridge|host_ifname|host_mac|mac_filter)=(.+)$/) {
		if ($1 eq 'host_ifname') {
		    $d->{$1} = $2;
		    $host_ifnames->{$2} = $1;
		} elsif ($1 eq 'mac_filter') {
		    $d->{$1} = parse_boolean('mac_filter', $2);
		} else {
		    $d->{$1} = $2;
		}
	    }
	}
	if ($d->{ifname}) {
	    $d->{mac} = PVE::Tools::random_ether_addr() if !$d->{mac};
	    $d->{host_mac} = PVE::Tools::random_ether_addr() if !$d->{host_mac};
	    $d->{raw} = print_netif($d);
	    $res->{$d->{ifname}} = $d;
	} else {
	    return undef;
	}
    }

    foreach my $iface (keys %$res) {
	my $d = $res->{$iface};
	if ($vmid && !$d->{host_ifname}) {
	    $d->{host_ifname} = &$find_next_hostif_name($iface);
	}
    }

    return $res;
}

sub print_netif {
    my $net = shift;

    my $res = "ifname=$net->{ifname}";
    $res .= ",mac=$net->{mac}" if $net->{mac};
    $res .= ",host_ifname=$net->{host_ifname}" if $net->{host_ifname};
    $res .= ",host_mac=$net->{host_mac}" if $net->{host_mac};
    $res .= ",bridge=$net->{bridge}" if $net->{bridge};

    if (defined($net->{mac_filter}) && !$net->{mac_filter}) {
	$res .= ",mac_filter=off"; # 'on' is the default
    }

    return $res;
}

PVE::JSONSchema::register_format('pve-openvz-netif', \&verify_netif);
sub verify_netif {
    my ($value, $noerr) = @_;

    return $value if parse_netif($value);

    return undef if $noerr;

    die "unable to parse --netif value";
}

PVE::JSONSchema::register_format('pve-openvz-hostname', \&verify_hostname);
sub verify_hostname {
    my ($value, $noerr) = @_;

    return $value if $value =~ /^[a-zA-Z0-9\-\.]+$/;

    return undef if $noerr;

    die "unable to parse --hostname value";
}

PVE::JSONSchema::register_format('pve-openvz-nameserver', \&verify_nameserver);
sub verify_nameserver {
    my ($value, $noerr) = @_;

    return $value if $value =~ /^($IPV4RE|$IPV6RE)\s{0,1}($IPV4RE|$IPV6RE){0,1}$/;

    return undef if $noerr;

    die "unable to parse --nameserver value";
}

sub parse_res_num_ignore {
    my ($key, $text) = @_;

    if ($text =~ m/^(\d+|unlimited)(:.*)?$/) {
	return { bar => $1 eq 'unlimited' ? $res_unlimited : $1 };
    }

    return undef;
}

sub parse_res_num_num {
    my ($key, $text) = @_;

    if ($text =~ m/^(\d+|unlimited)(:(\d+|unlimited))?$/) {
	my $res = { bar => $1 eq 'unlimited' ? $res_unlimited : $1 };
	if (defined($3)) {
	    $res->{lim} = $3 eq 'unlimited' ? $res_unlimited : $3;
	} else {
	    $res->{lim} = $res->{bar};
	}
	return $res;
    }

    return undef;
}

sub parse_res_bar_limit {
    my ($text, $base) = @_;

    return $res_unlimited if $text eq 'unlimited';

    if ($text =~ m/^(\d+)([TGMKP])?$/i) {
	my $val = $1;
	my $mult = $2 ? lc($2) : '';
	if ($mult eq 'k') {
	    $val = $val * 1024;
	} elsif ($mult eq 'm') {
	    $val = $val * 1024 * 1024;
	} elsif ($mult eq 'g') {
	    $val = $val * 1024 * 1024 * 1024;
	} elsif ($mult eq 't') {
	    $val = $val * 1024 * 1024 * 1024 * 1024;
	} elsif ($mult eq 'p') {
	    $val = $val * 4096;
	} else {
	    return $val;
	}
	return int($val/$base);
    }

    return undef;
}

sub parse_res_bytes_bytes {
    my ($key, $text) = @_;

    my @a = split(/:/, $text);
    $a[1] = $a[0] if !defined($a[1]);

    my $bar = parse_res_bar_limit($a[0], 1);
    my $lim = parse_res_bar_limit($a[1], 1);

    if (defined($bar) && defined($lim)) {
	return { bar => $bar, lim => $lim };
    }

    return undef;
}

sub parse_res_block_block {
    my ($key, $text) = @_;

    my @a = split(/:/, $text);
    $a[1] = $a[0] if !defined($a[1]);

    my $bar = parse_res_bar_limit($a[0], 1024);
    my $lim = parse_res_bar_limit($a[1], 1024);

    if (defined($bar) && defined($lim)) {
	return { bar => $bar, lim => $lim };
    }

    return undef;
}

sub parse_res_pages_pages {
    my ($key, $text) = @_;

    my @a = split(/:/, $text);
    $a[1] = $a[0] if !defined($a[1]);

    my $bar = parse_res_bar_limit($a[0], 4096);
    my $lim = parse_res_bar_limit($a[1], 4096);

    if (defined($bar) && defined($lim)) {
	return { bar => $bar, lim => $lim };
    }

    return undef;
}

sub parse_res_pages_unlimited {
    my ($key, $text) = @_;

    my @a = split(/:/, $text);

    my $bar = parse_res_bar_limit($a[0], 4096);

    if (defined($bar)) {
	return { bar => $bar, lim => $res_unlimited };
    }

    return undef;
}

sub parse_res_pages_ignore {
    my ($key, $text) = @_;

    my @a = split(/:/, $text);

    my $bar = parse_res_bar_limit($a[0], 4096);

    if (defined($bar)) {
	return { bar => $bar };
    }

    return undef;
}

sub parse_res_ignore_pages {
    my ($key, $text) = @_;

    my @a = split(/:/, $text);
    $a[1] = $a[0] if !defined($a[1]);

    my $lim = parse_res_bar_limit($a[1] , 4096);

    if (defined($lim)) {
	return { bar => 0, lim => $lim };
    }

    return undef;
}

sub parse_boolean {
    my ($key, $text) = @_;

    return { value => 1 } if $text =~ m/^(yes|true|on|1)$/i;
    return { value => 0 } if $text =~ m/^(no|false|off|0)$/i;

    return undef;
};

sub parse_integer {
    my ($key, $text) = @_;

    if ($text =~ m/^(\d+)$/) {
	return { value => int($1) };
    }

    return undef;
};

# use this for dns-name/ipv4/ipv6 (or lists of them)
sub parse_simple_string {
    my ($key, $text) = @_;

    if ($text =~ m/^([a-zA-Z0-9\-\,\;\:\.\s]*)$/) {
        return { value => $1 };
    }

    return undef;
}

my $ovz_ressources = {
    numproc => \&parse_res_num_ignore,
    numtcpsock => \&parse_res_num_ignore,
    numothersock => \&parse_res_num_ignore,
    numfile => \&parse_res_num_ignore,
    numflock => \&parse_res_num_num,
    numpty => \&parse_res_num_ignore,
    numsiginfo => \&parse_res_num_ignore,
    numiptent => \&parse_res_num_ignore,

    vmguarpages => \&parse_res_pages_unlimited,
    oomguarpages => \&parse_res_pages_unlimited,
    lockedpages => \&parse_res_pages_ignore,
    privvmpages => \&parse_res_pages_pages,
    shmpages => \&parse_res_pages_ignore,
    physpages => \&parse_res_pages_pages,
    swappages => \&parse_res_ignore_pages,
    vm_overcommit => 'float',

    kmemsize => \&parse_res_bytes_bytes,
    tcpsndbuf => \&parse_res_bytes_bytes,
    tcprcvbuf => \&parse_res_bytes_bytes,
    othersockbuf => \&parse_res_bytes_bytes,
    dgramrcvbuf => \&parse_res_bytes_bytes,
    dcachesize => \&parse_res_bytes_bytes,

    disk_quota => \&parse_boolean,
    diskspace => \&parse_res_block_block,
    diskinodes => \&parse_res_num_num,
    quotatime => \&parse_integer,
    quotaugidlimit => \&parse_integer,
    iolimit => \&parse_integer,
    iopslimit => \&parse_integer,

    cpuunits => \&parse_integer,
    cpulimit => \&parse_integer,
    cpus => \&parse_integer,
    cpumask => 'string',
    meminfo => 'string',
    iptables => 'string',

    ip_address => 'string',
    netif => 'string',
    hostname => \&parse_simple_string,
    nameserver => \&parse_simple_string,
    searchdomain => \&parse_simple_string,

    name => 'string',
    description => 'string',
    onboot => \&parse_boolean,
    initlog => \&parse_boolean,
    bootorder => \&parse_integer,
    ostemplate => 'string',
    ve_root => 'string',
    ve_private => 'string',
    disabled => \&parse_boolean,
    origin_sample => 'string',
    noatime => \&parse_boolean,
    capability => 'string',
    devnodes => 'string',
    devices => 'string',
    pci => 'string',
    features => 'string',
    ioprio => \&parse_integer,
    ve_layout => 'string'

};

sub parse_ovz_config {
    my ($filename, $raw) = @_;

    return undef if !defined($raw);

    my $data = {
	digest => Digest::SHA::sha1_hex($raw),
    };

    $filename =~ m|/openvz/(\d+)\.conf$|
	|| die "got strange filename '$filename'";

    my $vmid = $1;

    while ($raw && $raw =~ s/^(.*?)(\n|$)//) {
	my $line = $1;

	next if $line =~ m/^\#/;
	next if $line =~ m/^\s*$/;

	if ($line =~ m/^\s*([A-Z][A-Z0-9_]*)\s*=\s*\"(.*)\"\s*$/i) {
	    my $name = lc($1);
	    my $text = $2;

	    my $parser = $ovz_ressources->{$name};
	    if (!$parser || !ref($parser)) {
		$data->{$name}->{value} = $text;
		next;
	    } else {
		if (my $res = &$parser($name, $text)) {
		    $data->{$name} = $res;
		    next;
		}
	    }
	}
	die "unable to parse config line: $line\n";
    }

    return $data;
}

cfs_register_file('/openvz/', \&parse_ovz_config);

sub format_res_value {
    my ($key, $value) = @_;

    return 'unlimited' if $value == $res_unlimited;

    return 0 if $value == 0;

    if ($key =~ m/pages$/) {
        my $bytes = $value * 4096;
	my $mb = int ($bytes / (1024 * 1024));
	return "${mb}M" if $mb * 1024 * 1024 == $bytes;
    } elsif ($key =~ m/space$/) {
        my $bytes = $value * 1024;
	my $gb = int ($bytes / (1024 * 1024 * 1024));
	return "${gb}G" if $gb * 1024 * 1024 * 1024 == $bytes;
	my $mb = int ($bytes / (1024 * 1024));
	return "${mb}M" if $mb * 1024 * 1024 == $bytes;
    } elsif ($key =~ m/size$/) {
        my $bytes = $value;
	my $mb = int ($bytes / (1024 * 1024));
	return "${mb}M" if $mb * 1024 * 1024 == $bytes;
    }

    return $value;
}

sub format_res_bar_lim {
    my ($key, $data) = @_;

    if (defined($data->{lim}) && ($data->{lim} ne $data->{bar})) {
	return format_res_value($key, $data->{bar}) . ":" . format_res_value($key, $data->{lim});
    } else {
	return format_res_value($key, $data->{bar});
    }
}

sub create_config_line {
    my ($key, $data) = @_;

    my $text;

    if (defined($data->{value})) {
    	if ($confdesc->{$key} && $confdesc->{$key}->{type} eq 'boolean') {
    	    my $txt = $data->{value} ? 'yes' : 'no';
    	    $text .= uc($key) . "=\"$txt\"\n";
    	} else {
            my $value = $data->{value};
            die "detected invalid newline inside property '$key'\n" if $value =~ m/\n/;
            $text .= uc($key) . "=\"$value\"\n";
    	}
    } elsif (defined($data->{bar})) {
    	my $tmp = format_res_bar_lim($key, $data);
    	$text .=  uc($key) . "=\"$tmp\"\n";
    }
}

sub ovz_config_extract_mem_swap {
    my ($veconf, $unit) = @_;

    $unit = 1 if !$unit;

    my ($mem, $swap) = (int((512*1024*1024 + $unit - 1)/$unit), 0);

    my $maxpages = ($res_unlimited / 4096);

    if ($veconf->{swappages}) {
	if ($veconf->{physpages} && $veconf->{physpages}->{lim} &&
	    ($veconf->{physpages}->{lim} < $maxpages)) {
	    $mem = int(($veconf->{physpages}->{lim} * 4096 + $unit - 1) / $unit);
	}
	if ($veconf->{swappages}->{lim} && ($veconf->{swappages}->{lim} < $maxpages)) {
	    $swap = int (($veconf->{swappages}->{lim} * 4096 + $unit - 1) / $unit);
	}
    } else {
	if ($veconf->{vmguarpages} && $veconf->{vmguarpages}->{bar} &&
	    ($veconf->{vmguarpages}->{bar} < $maxpages)) {
	    $mem = int(($veconf->{vmguarpages}->{bar} * 4096 + $unit - 1) / $unit);
	}
    }

    return ($mem, $swap);
}

sub update_ovz_config {
    my ($vmid, $veconf, $param) = @_;

    my $changes = [];

    # test if barrier or limit changed
    my $push_bl_changes = sub {
	my ($name, $bar, $lim) = @_;
	my $old = format_res_bar_lim($name, $veconf->{$name})
	    if $veconf->{$name} && defined($veconf->{$name}->{bar});
	my $new = format_res_bar_lim($name, { bar => $bar, lim => $lim });
	if (!$old || ($old ne $new)) {
	    $veconf->{$name}->{bar} = $bar;
	    $veconf->{$name}->{lim} = $lim;
	    push @$changes, "--$name", $new;
	}
    };

    my ($mem, $swap) = ovz_config_extract_mem_swap($veconf, 1024*1024);
    my $disk = ($veconf->{diskspace}->{bar} || $res_unlimited) / (1024*1024);
    my $cpuunits = $veconf->{cpuunits}->{value} || 1000;
    my $quotatime = $veconf->{quotatime}->{value} || 0;
    my $quotaugidlimit = $veconf->{quotaugidlimit}->{value} || 0;
    my $cpus = $veconf->{cpus}->{value} || 1;

    if ($param->{memory}) {
	$mem = $param->{memory};
    }

    if (defined ($param->{swap})) {
	$swap = $param->{swap};
    }

    if ($param->{disk}) {
	$disk = $param->{disk};
    }

    if ($param->{cpuunits}) {
	$cpuunits = $param->{cpuunits};
    }

    if (defined($param->{quotatime})) {
	$quotatime = $param->{quotatime};
    }

    if (defined($param->{quotaugidlimit})) {
	$quotaugidlimit = $param->{quotaugidlimit};
    }

    if ($param->{cpus}) {
	$cpus = $param->{cpus};
    }

    # memory related parameter

    &$push_bl_changes('vmguarpages', 0, $res_unlimited);
    &$push_bl_changes('oomguarpages', 0, $res_unlimited);
    #&$push_bl_changes('privvmpages', $res_unlimited, $res_unlimited);

    # lock half of $mem
    my $lockedpages = int($mem*1024/8);
    &$push_bl_changes('lockedpages', $lockedpages, undef);

    my $kmemsize = int($mem/2);
    &$push_bl_changes('kmemsize', int($kmemsize/1.1)*1024*1024, $kmemsize*1024*1024);

    my $dcachesize = int($mem/4);
    &$push_bl_changes('dcachesize', int($dcachesize/1.1)*1024*1024, $dcachesize*1024*1024);

    my $physpages = int($mem*1024/4);
    &$push_bl_changes('physpages', 0, $physpages);

    my $swappages = int($swap*1024/4);
    &$push_bl_changes('swappages', 0, $swappages);

    if(defined($param->{vm_overcommit})) {
        $veconf->{'vm_overcommit'}->{value} = $param->{vm_overcommit};
        push @$changes, '--vm_overcommit', "$param->{vm_overcommit}";
    }


    # disk quota parameters
    if (!$disk) {
	&$push_bl_changes('diskspace', $res_unlimited, $res_unlimited);
	#&$push_bl_changes('diskinodes', $res_unlimited, $res_unlimited);
    } else {
	my $diskspace = int ($disk * 1024 * 1024);
	&$push_bl_changes('diskspace', $diskspace, $diskspace);
	#my $diskinodes = int ($disk * 200000);
	#my $diskinodes_lim = int ($disk * 220000);
	#&$push_bl_changes('diskinodes', $diskinodes, $diskinodes_lim);
    }

    if ($veconf->{'quotatime'}->{value} != $quotatime) {
	$veconf->{'quotatime'}->{value} = $quotatime;
	push @$changes, '--quotatime', "$quotatime";
    }

    if ($veconf->{'quotaugidlimit'}->{value} != $quotaugidlimit) {
	$veconf->{'quotaugidlimit'}->{value} = $quotaugidlimit;
	push @$changes, '--quotaugidlimit', "$quotaugidlimit";
    }

    # cpu settings

    if ($veconf->{'cpuunits'}->{value} != $cpuunits) {
	$veconf->{'cpuunits'}->{value} = $cpuunits;
	push @$changes, '--cpuunits', "$cpuunits";
    }

    if ($veconf->{'cpus'}->{value} != $cpus) {
	$veconf->{'cpus'}->{value} = $cpus;
	push @$changes, '--cpus', "$cpus";
    }

	if ($veconf->{'cpulimit'}->{value} != $param->{cpulimit} && defined($param->{cpulimit})) {
		$veconf->{'cpulimit'}->{value} = $param->{cpulimit};
		push @$changes, '--cpulimit', "$param->{cpulimit}";
    }

    my $cond_set_boolean = sub {
	my ($name) = @_;

	return if !defined($param->{$name});

	my $newvalue = $param->{$name} ? 1 : 0;
	my $oldvalue = $veconf->{$name}->{value};
	if (!defined($oldvalue) || ($oldvalue ne $newvalue)) {
	    $veconf->{$name}->{value} = $newvalue;
	    push @$changes, "--$name", $newvalue ? 'yes' : 'no';
	}
    };

    my $cond_set_value = sub {
	my ($name, $newvalue) = @_;

	$newvalue = defined($newvalue) ? $newvalue : $param->{$name};
	return if !defined($newvalue);

	my $oldvalue = $veconf->{$name}->{value};
	if (!defined($oldvalue) || ($oldvalue ne $newvalue)) {
	    $veconf->{$name}->{value} = $newvalue;
	    push @$changes, "--$name", $newvalue;
	}
    };

    &$cond_set_boolean('onboot');

    &$cond_set_value('hostname');

    &$cond_set_value('searchdomain');

    if ($param->{'description'}) {
	&$cond_set_value('description', PVE::Tools::encode_text($param->{'description'}));
    }

    if (defined($param->{ip_address})) {
	my $iphash = {};
	if (defined($veconf->{'ip_address'}) && $veconf->{'ip_address'}->{value}) {
	    foreach my $ip (split (/\s+/, $veconf->{ip_address}->{value})) {
		$iphash->{$ip} = 1;
	    }
	}
	my $newhash = {};
	foreach my $ip (PVE::Tools::split_list($param->{'ip_address'})) {
	    next if $ip !~ m!^(?:$IPV6RE|$IPV4RE)(?:/\d+)?$!;
	    $newhash->{$ip} = 1;
	    if (!$iphash->{$ip}) {
		push @$changes, '--ipadd', $ip;
		$iphash->{$ip} = 1; # only add once
	    }
	}
	foreach my $ip (keys %$iphash) {
	    if (!$newhash->{$ip}) {
		push @$changes, '--ipdel', $ip;
	    }
	}
	$veconf->{'ip_address'}->{value} = join(' ', keys %$iphash);
    }

    if (defined($param->{devices})) {
		$veconf->{'devices'}->{value} = $param->{devices};
		push @$changes, '--devices', "$param->{devices}";
    }
    if (defined($param->{devnodes})) {
        $veconf->{'devnodes'}->{value} = $param->{devnodes};
        push @$changes, '--devnodes', "$param->{devnodes}";
    }
    if (defined($param->{capability})) {
        $veconf->{'capability'}->{value} = $param->{capability};
        push @$changes, '--capability', "$param->{capability}";
    }
    if (defined($param->{features})) {
        $veconf->{'features'}->{value} = $param->{features};
        push @$changes, '--features', "$param->{features}";
    }

    # IO settings

    if(defined($param->{iolimit})) {
    	$veconf->{'iolimit'}->{value} = $param->{iolimit} * (1024 * 1024);
    	push @$changes, '--iolimit', "$param->{iolimit}M";
    }
    if(defined($param->{iopslimit})) {
    	$veconf->{'iopslimit'}->{value} = $param->{iopslimit};
    	push @$changes, '--iopslimit', "$param->{iopslimit}";
    }


    if (defined($param->{netif})) {
	my $ifaces = {};
	if (defined ($veconf->{netif}) && $veconf->{netif}->{value}) {
	    $ifaces = parse_netif($veconf->{netif}->{value}, $vmid);
	}
	my $newif = parse_netif($param->{netif}, $vmid);

	foreach my $ifname (sort keys %$ifaces) {
	    if (!$newif->{$ifname}) {
		push @$changes, '--netif_del', $ifname;
	    }
	}

	my $newvalue = '';
	foreach my $ifname (sort keys %$newif) {
	    $newvalue .= ';' if $newvalue;

	    $newvalue .= print_netif($newif->{$ifname});

	    my $ifadd = $ifname;
	    $ifadd .= $newif->{$ifname}->{mac} ? ",$newif->{$ifname}->{mac}" : ',';
	    $ifadd .= $newif->{$ifname}->{host_ifname} ? ",$newif->{$ifname}->{host_ifname}" : ',';
	    $ifadd .= $newif->{$ifname}->{host_mac} ? ",$newif->{$ifname}->{host_mac}" : ',';
	    $ifadd .= $newif->{$ifname}->{bridge} ? ",$newif->{$ifname}->{bridge}" : '';

	    # not possible with current vzctl
	    #$ifadd .= $newif->{$ifname}->{mac_filter} ? ",$newif->{$ifname}->{mac_filter}" : '';

	    if (!$ifaces->{$ifname} || ($ifaces->{$ifname}->{raw} ne $newif->{$ifname}->{raw})) {
		push @$changes, '--netif_add', $ifadd;
	    }
	}
	$veconf->{netif}->{value} = $newvalue;
    }

    if (defined($param->{'nameserver'})) {
	# remove duplicates
	my $nshash = {};
	my $newvalue = '';
	foreach my $ns (PVE::Tools::split_list($param->{'nameserver'})) {
	    if (!$nshash->{$ns}) {
		push @$changes, '--nameserver', $ns;
		$nshash->{$ns} = 1;
		$newvalue .= $newvalue ? " $ns" : $ns;
	    }
	}
	$veconf->{'nameserver'}->{value} = $newvalue if $newvalue;
    }

    # foreach my $nv (@$changes) { print "CHANGE: $nv\n"; }

    return $changes;
}

sub generate_raw_config {
    my ($raw, $conf) = @_;

    my $text = '';

    my $found = {};

    while ($raw && $raw =~ s/^(.*?)(\n|$)//) {
	my $line = $1;

	if ($line =~ m/^\#/ || $line =~ m/^\s*$/) {
	    $text .= "$line\n";
	    next;
	}

	if ($line =~ m/^\s*([A-Z][A-Z0-9_]*)\s*=\s*\"(.*)\"\s*$/i) {
	    my $name = lc($1);
	    if ($conf->{$name}) {
		$found->{$name} = 1;
		if (my $line = create_config_line($name, $conf->{$name})) {
		    $text .= $line;
		}
	    }
	}
    }

    foreach my $key (keys %$conf) {
	next if $found->{$key};
	next if $key eq 'digest';
	if (my $line = create_config_line($key, $conf->{$key})) {
	    $text .= $line;
	}
    }

    return $text;
}

sub create_lock_manager {
    my ($max) = @_;

    return LockFile::Simple->make(-format => '%f',
				  -autoclean => 1,
				  -max => defined($max) ? $max : 60,
				  -delay => 1,
				  -stale => 1,
				  -nfs => 0);
}

sub lock_container {
    my ($vmid, $max, $code, @param) = @_;

    my $filename = $global_vzconf->{lockdir} . "/${vmid}.lck";
    my $lock;
    my $res;

    eval {

	my $lockmgr = create_lock_manager($max);

	$lock = $lockmgr->lock($filename) || die "can't lock container $vmid\n";

        $res = &$code(@param);
    };
    my $err = $@;

    $lock->release() if $lock;

    die $err if $err;

    return $res;
}

sub vm_suspend {
    my ($vmid) = @_;

    my $cmd = ['vzctl', 'suspend', $vmid];

    eval { run_command($cmd); };
    if (my $err = $@) {
        syslog("err", "CT $vmid suspend failed - $err");
        die $err;
    }
}

sub vm_resume {
    my ($vmid) = @_;

    my $cmd = ['vzctl', 'resume', $vmid];

    eval { run_command($cmd); };
    if (my $err = $@) {
        syslog("err", "CT $vmid resume failed - $err");
        die $err;
    }
}

sub set_rootpasswd {
    my ($vmid, $opt_rootpasswd) = @_;

    my $cmd = ['vzctl', '--skiplock', 'set', $vmid, '--userpasswd', "root:${opt_rootpasswd}"];
    eval {
        run_command($cmd);
    };
    if (my $err = $@) {
        syslog("err", "CT $vmid change root password failed - $err");
        die $err;
    }
}

sub getSnapshots {
    my $vmid = shift;

    my $cmd = ['vzctl', '--skiplock', 'snapshot-list', $vmid, '-H', '-o', 'parent_uuid,current,uuid,date,name']; # Just to be sure, OpenVZ does change the default order
    my $snapshots = {};

    eval {
        run_command($cmd, outfunc => sub {
            my $line = shift;

            if($line =~ /^[\s\{]{1}(\s{36}|[a-z0-9-]+)[\s\}]{1}\s(\*|\s)\s\{([a-z0-9-]+)\}\s([0-9-]+\s[0-9:]+)\s{0,1}(.*)$/s) {
                my ($parent, $current, $uuid, $date, $name) = ($1, $2, $3, $4, $5);
                $snapshots->{$uuid} = { parent => $parent =~ /^ *$/ ? '' : $parent, current => $current eq '*' ? 1 : 0, date => $date, name => $name };
            } else {
                die "Could not parse line"; # Should normally not happen
            }
        });
    };
    if (my $err = $@) {
        die "Unable to get snapshots: $err";
    }
    return $snapshots;
}

sub generateUUID {
    return Data::UUID->new->create_str();
}

sub createSnapshot {
    my ($vmid, $name, $skipsuspend, $uuid) = @_;

    $uuid = generateUUID() if !$uuid;

    my $cmd = ['vzctl', 'snapshot', $vmid, '--id', $uuid, '--skip-config'];

    push $cmd, '--name', $name if $name;
    push $cmd, '--skip-suspend' if $skipsuspend;

    eval {
        run_command($cmd);
    };
    if (my $err = $@) {
        die "Unable to create snapshot: $err";
    }

    return $uuid;
}

sub deleteSnapshot {
    my ($vmid, $uuid, $skiplock) = @_;

    my $cmd;

    if ($skiplock) {
        $cmd = ['vzctl', '--skiplock', 'snapshot-delete', $vmid, '--id', $uuid];
    } else {
        $cmd = ['vzctl', 'snapshot-delete', $vmid, '--id', $uuid];
    }

    eval {
        run_command($cmd);
    };
    if (my $err = $@) {
        die "Unable to delete snapshot: $err";
    }
}

sub switchSnapshot {
    my ($vmid, $uuid, $skiplock) = @_;

    my $cmd;

    if ($skiplock) {
        $cmd = ['vzctl', '--skiplock', 'snapshot-switch', $vmid, '--id', $uuid];
    } else {
        $cmd = ['vzctl', 'snapshot-switch', $vmid, '--id', $uuid];
    }

    eval {
        run_command($cmd);
    };
    if (my $err = $@) {
        die "Unable to switch snapshot: $err";
    }
}

sub mountContainer {
    my ($vmid, $skiplock) = @_;

    my $cmd;

    if($skiplock) {
        $cmd = ['vzctl', '--skiplock', 'mount', $vmid];
    } else {
        $cmd = ['vzctl', 'mount', $vmid];
    }

    eval {
        run_command($cmd);
    };
    if (my $err = $@) {
        die "Unable to mount container";
    }
}

sub umountContainer {
    my ($vmid, $skiplock) = @_;

    my $cmd;

    if($skiplock) {
        $cmd = ['vzctl', '--skiplock', 'umount', $vmid];
    } else {
        $cmd = ['vzctl', 'umount', $vmid];
    }

    eval {
        run_command($cmd);
    };
    if (my $err = $@) {
        die "Unable to umount container";
    }
}

sub reinstallContainer {
    my ($vmid, $archive) = @_;

    eval {
        my $conf = load_config($vmid);
        my $root = get_rootdir($conf, $vmid);

        die "invalid root dir\n" if !$root || !-d $root;
        die "invalid archive\n" if !$archive;

        mountContainer($vmid, 1);

        print "Deleting container files\n";
        deleteContainerFiles($conf, $vmid);

        my $cmd = ['tar', 'xpfz', $archive, '-C', $root];

        print "Unpacking template\n";
        run_command($cmd);

        umountContainer($vmid, 1);

        my $basename = File::Basename::basename($archive);

        $cmd = ['vzctl', '--skiplock', 'set', $vmid, '--ostemplate', $basename, '--save'];
        run_command($cmd);
    };
    if (my $err = $@) {
        eval {
            umountContainer($vmid, 1);
        };
        die $err;
    }
}

sub compactContainer {
    my ($vmid, $skiplock) = @_;

    my $cmd;

    if($skiplock) {
        $cmd = ['vzctl', '--skiplock', 'compact', $vmid];
    } else {
        $cmd = ['vzctl', 'compact', $vmid];
    }

    eval {
        run_command($cmd);
    };
    if (my $err = $@) {
        die $err;
    }
}

sub restoreContainerBackup {
    my ($vmid, $archive, $private, $force) = @_;

    my $vzconf = PVE::OpenVZ::read_global_vz_config();
    my $conffile = PVE::OpenVZ::config_file($vmid);
    my $cfgdir = dirname($conffile);

    my $root = $vzconf->{rootdir};
    $root =~ s/\$VEID/${vmid}/;

    print "you choose to force overwriting VPS config file, private and root directories.\n" if $force;

    die "unable to create CT ${vmid} - container already exists\n"
    if !$force && -f $conffile;

    die "unable to create CT ${vmid} - directory '${private}' already exists\n"
    if !$force && -d $private;

    die "unable to create CT ${vmid} - directory '${root}' already exists\n"
    if !$force && -d $root;

    my $conf;

    eval {
        if ($force && -f $conffile) {
            my $conf = PVE::OpenVZ::load_config($vmid);

            my $oldprivate = PVE::OpenVZ::get_privatedir($conf, $vmid);
            rmtree $oldprivate if -d $oldprivate;

            my $oldroot = $conf->{ve_root} ? $conf->{ve_root}->{value} : $root;
            rmtree $oldroot if -d $oldroot;
        }

        sleep(1); # Just sleep to be sure IO has been flushed

        mkpath $private || die "unable to create private dir '$private'";
        mkpath $root || die "unable to create root dir '$root'";

        my $cmd = ['tar', 'xpvf', $archive, '--totals', '--sparse', '-C', $private];

        if ($archive eq '-') {
            print "extracting archive from STDIN\n";
            run_command($cmd, input => "<&STDIN");
        } else {
            print "extracting archive '$archive'\n";
            run_command($cmd);
        }

        my $backup_cfg;
        my $isploop;

        if (-f "${private}/vzdump/vps.conf") {
            $backup_cfg = "${private}/vzdump/vps.conf"; # Config path for ploop
            $isploop = 1;
        } elsif (-f "${private}/etc/vzdump/vps.conf") {
            $backup_cfg = "${private}/etc/vzdump/vps.conf"; # Config path for simfs
            $isploop = 0;
        } else {
            die "VPS Config file does not exists";
        }

        print "restore configuration to '$conffile'\n";

        my $conf = PVE::Tools::file_get_contents($backup_cfg);

        $conf =~ s/VE_ROOT=.*/VE_ROOT=\"$root\"/;
        $conf =~ s/VE_PRIVATE=.*/VE_PRIVATE=\"$private\"/;
        $conf =~ s/host_ifname=veth[0-9]+\./host_ifname=veth${vmid}\./g;

        PVE::Tools::file_set_contents($conffile, $conf);

        foreach my $s (PVE::OpenVZ::SCRIPT_EXT) {
            my $tfn = "${cfgdir}/${vmid}.$s";
            my $sfn = "${private}/vzdump/vps.${s}";
            if (-f $sfn) {
                my $sc = PVE::Tools::file_get_contents($sfn);
                PVE::Tools::file_set_contents($tfn, $sc);
            }
        }

        if ($isploop) {
            print "Detected Ploop container - Trying to detect valid snapshot that needs to be restored\n";
            my $snapshotcfg = "${private}/vzdump/snapshot.uuid";

            if (-f $snapshotcfg) {
                my $snapshotuuid = PVE::Tools::file_get_contents($snapshotcfg);

                if ($snapshotuuid) {
                    my $validuuid = getValidUUID($snapshotuuid);
                    switchSnapshot($vmid, $validuuid, 1);
                    deleteSnapshot($vmid, $validuuid, 1);
                }
            }
        } else {
            print "Detected obsolete simfs container - Converting to ploop now\n";
            run_command(['vzconvert', '--skiplock=1', $vmid]);
        }

        rmtree "${private}/vzdump";
    };

    my $err = $@;

    if ($err) {
        rmtree $private;
        rmtree $root;
        unlink $conffile;
        foreach my $s (PVE::OpenVZ::SCRIPT_EXT) {
            unlink "${cfgdir}/${vmid}.${s}";
        }
        die $err;
    }

    return $conf;

}

sub getValidUUID {
    my $uuid = shift;

    my $string;

    $uuid =~ /\A(.*)\z/s or die "Invalid UUID"; $string = $1;

    $string =~ /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/ or die "Invalid UUID";

    return $string;
}

sub getPloopInfo {
    my ($vmid, $private, $root) = @_;

    my $mi = PVE::Mounts->read;

    my $devmounts = $mi->at($root);

    die "Could not get ploop info. Propably filesystem not mounted" if scalar @$devmounts ne 1;

    my $ploopblockdevice = @$devmounts[0]->spec;

    my $ploopdevice;

    if ($ploopblockdevice =~ /^\/dev\/(ploop\d+)p\d$/s) {
        $ploopdevice = $1;
    } else {
        die "Invalid ploop device";
    }

    my $top = PVE::Tools::file_get_contents("/sys/block/${ploopdevice}/pstate/top") || 1;
    chomp $top;

    my $top_delta = PVE::Tools::file_get_contents("/sys/block/${ploopdevice}/pdelta/${top}/image") || 1;
    chomp $top_delta;

    $top_delta =~ s/^${private}\///;

    $ploopdevice =~ /\A(.*)\z/s or die "Invalid ploop device"; $ploopdevice = $1;
    $top_delta =~ /\A(.*)\z/s or die "Invalid top delta"; $top_delta = $1;

    return { ploop_device => $ploopdevice, top_delta => $top_delta };
}
