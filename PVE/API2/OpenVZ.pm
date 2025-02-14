package PVE::API2::OpenVZ;

use strict;
use warnings;
use File::Basename;
use File::Path;
use POSIX qw (LONG_MAX);

use PVE::SafeSyslog;
use PVE::Tools qw(extract_param run_command);
use PVE::Exception qw(raise raise_param_exc);
use PVE::INotify;
use PVE::Cluster qw(cfs_lock_file cfs_read_file cfs_write_file);
use PVE::AccessControl;
use PVE::Storage;
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::OpenVZ;
use PVE::OpenVZMigrate;
use PVE::JSONSchema qw(get_standard_option);
use PVE::API2::Firewall::VM;
use PVE::API2::Database::VM;

use base qw(PVE::RESTHandler);

use Data::Dumper; # fixme: remove

my $pve_base_ovz_config = <<__EOD;
ONBOOT="no"

OOMGUARPAGES="0:unlimited"
VMGUARPAGES="0:unlimited"
KMEMSIZE="116M:128M"
DCACHESIZE="58M:64M"
LOCKEDPAGES="128M"

VM_OVERCOMMIT="1.5"
VE_LAYOUT="ploop"

# Disk quota parameters (in form of softlimit:hardlimit)
DISKSPACE="unlimited:unlimited"


# CPU fair scheduler parameter
CPUUNITS="1000"
CPUS="1"
__EOD

my $get_container_storage = sub {
    my ($stcfg, $vmid, $veconf) = @_;

    my $path = PVE::OpenVZ::get_privatedir($veconf, $vmid);
    my ($vtype, $volid) = PVE::Storage::path_to_volume_id($stcfg, $path);
    my ($sid, $volname) = PVE::Storage::parse_volume_id($volid, 1) if $volid;
    return wantarray ? ($sid, $volname, $path) : $sid;
};

my $check_ct_modify_config_perm = sub {
    my ($rpcenv, $authuser, $vmid, $pool, $key_list) = @_;
    
    return 1 if $authuser ne 'root@pam';

    foreach my $opt (@$key_list) {

	if ($opt eq 'cpus' || $opt eq 'cpuunits' || $opt eq 'cpulimit') {
	    $rpcenv->check_vm_perm($authuser, $vmid, $pool, ['VM.Config.CPU']);
	} elsif ($opt eq 'disk' || $opt eq 'quotatime' || $opt eq 'quotaugidlimit') {
	    $rpcenv->check_vm_perm($authuser, $vmid, $pool, ['VM.Config.Disk']);
	} elsif ($opt eq 'memory' || $opt eq 'swap') {
	    $rpcenv->check_vm_perm($authuser, $vmid, $pool, ['VM.Config.Memory']);
	} elsif ($opt eq 'netif' || $opt eq 'ip_address' || $opt eq 'nameserver' || 
		 $opt eq 'searchdomain' || $opt eq 'hostname') {
	    $rpcenv->check_vm_perm($authuser, $vmid, $pool, ['VM.Config.Network']);
	} else {
	    $rpcenv->check_vm_perm($authuser, $vmid, $pool, ['VM.Config.Options']);
	}
    }

    return 1;
};

__PACKAGE__->register_method({
    name => 'vmlist', 
    path => '', 
    method => 'GET',
    description => "OpenVZ container index (per node).",
    permissions => {
	description => "Only list VMs where you have VM.Audit permissons on /vms/<vmid>.",
	user => 'all',
    },
    proxyto => 'node',
    protected => 1, # openvz proc files are only readable by root
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => {},
	},
	links => [ { rel => 'child', href => "{vmid}" } ],
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();
	my $authuser = $rpcenv->get_user();

	my $vmstatus = PVE::OpenVZ::vmstatus();

	my $res = [];
	foreach my $vmid (keys %$vmstatus) {
	    next if !$rpcenv->check($authuser, "/vms/$vmid", [ 'VM.Audit' ], 1);

	    my $data = $vmstatus->{$vmid};
	    $data->{vmid} = $vmid;
	    push @$res, $data;
	}

	return $res;
  
    }});

# create_vm is also used by vzrestore
__PACKAGE__->register_method({
    name => 'create_vm', 
    path => '', 
    method => 'POST',
    description => "Create or restore a container.",
    permissions => {
	user => 'all', # check inside
 	description => "You need 'VM.Allocate' permissions on /vms/{vmid} or on the VM pool /pool/{pool}. " .
	    "For restore, it is enough if the user has 'VM.Backup' permission and the VM already exists. " .
	    "You also need 'Datastore.AllocateSpace' permissions on the storage.",
    },
    protected => 1,
    proxyto => 'node',
    parameters => {
    	additionalProperties => 0,
	properties => PVE::OpenVZ::json_config_properties({
	    node => get_standard_option('pve-node'),
	    vmid => get_standard_option('pve-vmid'),
	    ostemplate => {
		description => "The OS template or backup file.",
		type => 'string', 
		maxLength => 255,
	    },
	    password => { 
		optional => 1, 
		type => 'string',
		description => "Sets root password inside container.",
	    },
	    storage => get_standard_option('pve-storage-id', {
		description => "Target storage.",
		default => 'local',
		optional => 1,
	    }),
	    force => {
		optional => 1, 
		type => 'boolean',
		description => "Allow to overwrite existing container.",
	    },
	    restore => {
		optional => 1, 
		type => 'boolean',
		description => "Mark this as restore task.",
	    },
	    pool => { 
		optional => 1,
		type => 'string', format => 'pve-poolid',
		description => "Add the VM to the specified pool.",
	    }
	}),
    },
    returns => { 
	type => 'string',
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();

	my $authuser = $rpcenv->get_user();

	my $node = extract_param($param, 'node');

	my $vmid = extract_param($param, 'vmid');

	my $password = extract_param($param, 'password');

	my $storage = extract_param($param, 'storage') || 'local';

	my $pool = extract_param($param, 'pool');
	
	my $storage_cfg = cfs_read_file("storage.cfg");

	my $scfg = PVE::Storage::storage_check_node($storage_cfg, $storage, $node);

	raise_param_exc({ storage => "storage '$storage' does not support openvz root directories"})
	    if !$scfg->{content}->{rootdir};

	my $private = PVE::Storage::get_private_dir($storage_cfg, $storage, $vmid);

	my $basecfg_fn = PVE::OpenVZ::config_file($vmid);

	if (defined($pool)) {
	    $rpcenv->check_pool_exist($pool);
	    $rpcenv->check_perm_modify($authuser, "/pool/$pool");
	} 

	$rpcenv->check($authuser, "/storage/$storage", ['Datastore.AllocateSpace']);

	if ($rpcenv->check($authuser, "/vms/$vmid", ['VM.Allocate'], 1)) {
	    # OK
	} elsif ($pool && $rpcenv->check($authuser, "/pool/$pool", ['VM.Allocate'], 1)) {
	    # OK
	} elsif ($param->{restore} && $param->{force} && (-f $basecfg_fn) &&
		 $rpcenv->check($authuser, "/vms/$vmid", ['VM.Backup'], 1)) {
	    # OK: user has VM.Backup permissions, and want to restore an existing VM
	} else {
	    raise_perm_exc();
	}

	&$check_ct_modify_config_perm($rpcenv, $authuser, $vmid, $pool, [ keys %$param]);

	PVE::Storage::activate_storage($storage_cfg, $storage);

	my $conf = PVE::OpenVZ::parse_ovz_config("/tmp/openvz/$vmid.conf", $pve_base_ovz_config);

	my $ostemplate = extract_param($param, 'ostemplate');

	my $archive;

	if ($ostemplate eq '-') {
	    die "pipe requires cli environment\n" 
		if $rpcenv->{type} ne 'cli'; 
	    die "pipe can only be used with restore tasks\n" 
		if !$param->{restore};
	    $archive = '-';
	} else {
	    $rpcenv->check_volume_access($authuser, $storage_cfg, $vmid, $ostemplate);
	    $archive = PVE::Storage::abs_filesystem_path($storage_cfg, $ostemplate);
	}

	if (!defined($param->{searchdomain}) && 
	    !defined($param->{nameserver})) {
	
	    my $resolv = PVE::INotify::read_file('resolvconf');

	    $param->{searchdomain} = $resolv->{search} if $resolv->{search};

	    my @ns = ();
	    push @ns, $resolv->{dns1} if  $resolv->{dns1};
	    push @ns, $resolv->{dns2} if  $resolv->{dns2};
	    push @ns, $resolv->{dns3} if  $resolv->{dns3};

	    $param->{nameserver} = join(' ', @ns) if scalar(@ns);
	}

	# try to append domain to hostmane
	if ($param->{hostname} && $param->{hostname} !~ m/\./ &&
	    $param->{searchdomain}) {

	    $param->{hostname} .= ".$param->{searchdomain}";
	}

	my $check_vmid_usage = sub {
	    if ($param->{force}) {
		die "cant overwrite mounted container\n" 
		    if PVE::OpenVZ::check_mounted($conf, $vmid);
	    } else {
		die "CT $vmid already exists\n" if -f $basecfg_fn;
	    }
	};

	my $code = sub {

	    &$check_vmid_usage(); # final check after locking

	    PVE::OpenVZ::update_ovz_config($vmid, $conf, $param);

	    my $rawconf = PVE::OpenVZ::generate_raw_config($pve_base_ovz_config, $conf);

	    PVE::Cluster::check_cfs_quorum();

	    if ($param->{restore}) {
            PVE::OpenVZ::restoreContainerBackup($vmid, $archive, $private, $param->{force});

    		# is this really needed?
    		my $cmd = ['vzctl', '--skiplock', '--quiet', 'set', $vmid, 
    			   '--applyconfig_map', 'name', '--save'];
    		run_command($cmd);

    		# reload config
    		$conf = PVE::OpenVZ::load_config($vmid);

	    } else {
    		PVE::Tools::file_set_contents($basecfg_fn, $rawconf);
    		my $cmd = ['vzctl', '--skiplock', 'create', $vmid,
    			   '--ostemplate', $archive, '--private', $private];
    		run_command($cmd);
    		
    		PVE::OpenVZ::set_rootpasswd($vmid, $password) 
    		    if defined($password);
	    }

	    PVE::AccessControl::add_vm_to_pool($vmid, $pool) if $pool;
	};

	my $realcmd = sub { PVE::OpenVZ::lock_container($vmid, 1, $code); };

	&$check_vmid_usage(); # first check before locking

	return $rpcenv->fork_worker($param->{restore} ? 'vzrestore' : 'vzcreate', 
				    $vmid, $authuser, $realcmd);
    }});

my $vm_config_perm_list = [
	    'VM.Config.Disk', 
	    'VM.Config.CPU', 
	    'VM.Config.Memory', 
	    'VM.Config.Network', 
	    'VM.Config.Options',
    ];

__PACKAGE__->register_method({
    name => 'update_vm', 
    path => '{vmid}/config', 
    method => 'PUT',
    protected => 1,
    proxyto => 'node',
    description => "Set virtual machine options.",
    permissions => {
	check => ['perm', '/vms/{vmid}', $vm_config_perm_list, any => 1],
    },
    parameters => {
    	additionalProperties => 0,
	properties => PVE::OpenVZ::json_config_properties(
	    {
		node => get_standard_option('pve-node'),
		vmid => get_standard_option('pve-vmid'),
		digest => {
		    type => 'string',
		    description => 'Prevent changes if current configuration file has different SHA1 digest. This can be used to prevent concurrent modifications.',
		    maxLength => 40,
		    optional => 1,		    
		},
	    password => {
		    type => 'string',
		    description => 'Sets root password inside container.',
		    optional => 1,
	    },
	    tuntap => {
		    type => 'boolean',
		    description => 'Enables or disables the TUN/TAP Device inside container.',
		    optional => 1,
	    },
	    fuse => {
		    type => 'boolean',
		    description => 'Enables or disables the FUSE Device inside container.',
		    optional => 1,
		},
        ppp => {
            type => 'boolean',
            description => 'Enables or disables the PPP feature of a container.',
            optional => 1,
        }
	    }),
    },
    returns => { type => 'null'},
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();

	my $authuser = $rpcenv->get_user();

	my $node = extract_param($param, 'node');

	my $vmid = extract_param($param, 'vmid');

	my $digest = extract_param($param, 'digest');

	die "no options specified\n" if !scalar(keys %$param);

	&$check_ct_modify_config_perm($rpcenv, $authuser, $vmid, undef, [keys %$param]);

	my $code = sub {

	    my $conf = PVE::OpenVZ::load_config($vmid);
	    die "checksum missmatch (file change by other user?)\n" 
		if $digest && $digest ne $conf->{digest};
			
		PVE::OpenVZ::set_rootpasswd($vmid, $param->{password}) if($param->{password});

        my $devnodes = [];
        my $capabilities = [];
        my $devices = [];
        my $features = [];
        
		if (defined($param->{tuntap})) {
			if ($param->{tuntap}) {
                push(@$devnodes, 'net/tun:rw');
				push(@$capabilities, 'net_admin:on');
			} else {
				push(@$devnodes, 'net/tun:none');
				push(@$capabilities, 'net_admin:off');
			}
		}
        if (defined($param->{fuse})) {
            if ($param->{fuse}) {
				push(@$devnodes, 'fuse:rw');
            } else {
				push(@$devnodes, 'fuse:none');
            }
        }
        if (defined($param->{ppp})) {
            die "CT $vmid needs to be stopped\n" if PVE::OpenVZ::check_running($vmid);

            if ($param->{ppp}) {
                push (@$features, 'ppp:on');
                push (@$devices, 'c:108:0:rw');
            } else {
                push (@$features, 'ppp:off');
                push (@$devices, 'c:108:0:none');
            }
        }

        push(@$devnodes, split(' ', $param->{devnodes})) if(defined($param->{devnodes}));
        push(@$capabilities, split(' ', $param->{capability})) if(defined($param->{capability}));
        push(@$devices, split(' ', $param->{devices})) if(defined($param->{devices}));
        push(@$features, split(' ', $param->{features})) if(defined($param->{features}));

        $param->{devnodes} = join(' ', @$devnodes) if(@$devnodes);
        $param->{capability} = join(' ', @$capabilities) if(@$capabilities);
        $param->{devices} = join(' ', @$devices) if(@$devices);
        $param->{features} = join(' ', @$features) if(@$features);

	    my $changes = PVE::OpenVZ::update_ovz_config($vmid, $conf, $param);

	    return if scalar (@$changes) <= 0;

	    my $cmd = ['vzctl', '--skiplock', 'set', $vmid, @$changes, '--save'];

	    PVE::Cluster::log_msg('info', $authuser, "update CT $vmid: " . join(' ', @$changes));
 
	    run_command($cmd);
	};

	PVE::OpenVZ::lock_container($vmid, undef, $code);

	return undef;
    }});

__PACKAGE__->register_method ({
    subclass => "PVE::API2::Firewall::CT",  
    path => '{vmid}/firewall',
});

__PACKAGE__->register_method ({
    subclass => "PVE::API2::Database::CT",  
    path => '{vmid}/database',
});

__PACKAGE__->register_method({
    name => 'vmdiridx',
    path => '{vmid}', 
    method => 'GET',
    proxyto => 'node',
    description => "Directory index",
    permissions => {
	user => 'all',
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    vmid => get_standard_option('pve-vmid'),
	},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => {
		subdir => { type => 'string' },
	    },
	},
	links => [ { rel => 'child', href => "{subdir}" } ],
    },
    code => sub {
	my ($param) = @_;

	# test if VM exists
	my $conf = PVE::OpenVZ::load_config($param->{vmid});

	my $res = [
	    { subdir => 'config' },
	    { subdir => 'status' },
	    { subdir => 'vncproxy' },
	    { subdir => 'spiceproxy' },
	    { subdir => 'migrate' },
	    { subdir => 'rrd' },
	    { subdir => 'rrddata' },
	    { subdir => 'firewall' },
		{ subdir => 'reinstall' },
		{ subdir => 'database' },
        { subdir => 'snapshot' },
        { subdir => 'compact'}
	    ];
	
	return $res;
    }});

__PACKAGE__->register_method({
    name => 'rrd', 
    path => '{vmid}/rrd', 
    method => 'GET',
    protected => 1, # fixme: can we avoid that?
    permissions => {
	check => ['perm', '/vms/{vmid}', [ 'VM.Audit' ]],
    },
    description => "Read VM RRD statistics (returns PNG)",
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    vmid => get_standard_option('pve-vmid'),
	    timeframe => {
		description => "Specify the time frame you are interested in.",
		type => 'string',
		enum => [ 'hour', 'day', 'week', 'month', 'year' ],
	    },
	    ds => {
		description => "The list of datasources you want to display.",
 		type => 'string', format => 'pve-configid-list',
	    },
	    cf => {
		description => "The RRD consolidation function",
 		type => 'string',
		enum => [ 'AVERAGE', 'MAX' ],
		optional => 1,
	    },
	},
    },
    returns => {
	type => "object",
	properties => {
	    filename => { type => 'string' },
	},
    },
    code => sub {
	my ($param) = @_;

	return PVE::Cluster::create_rrd_graph(
	    "pve2-vm/$param->{vmid}", $param->{timeframe}, 
	    $param->{ds}, $param->{cf});
					      
    }});

__PACKAGE__->register_method({
    name => 'rrddata', 
    path => '{vmid}/rrddata', 
    method => 'GET',
    protected => 1, # fixme: can we avoid that?
    permissions => {
	check => ['perm', '/vms/{vmid}', [ 'VM.Audit' ]],
    },
    description => "Read VM RRD statistics",
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    vmid => get_standard_option('pve-vmid'),
	    timeframe => {
		description => "Specify the time frame you are interested in.",
		type => 'string',
		enum => [ 'hour', 'day', 'week', 'month', 'year' ],
	    },
	    cf => {
		description => "The RRD consolidation function",
 		type => 'string',
		enum => [ 'AVERAGE', 'MAX' ],
		optional => 1,
	    },
	},
    },
    returns => {
	type => "array",
	items => {
	    type => "object",
	    properties => {},
	},
    },
    code => sub {
	my ($param) = @_;

	return PVE::Cluster::create_rrd_data(
	    "pve2-vm/$param->{vmid}", $param->{timeframe}, $param->{cf});
    }});

__PACKAGE__->register_method({
    name => 'vm_config', 
    path => '{vmid}/config', 
    method => 'GET',
    proxyto => 'node',
    description => "Get container configuration.",
    permissions => {
	check => ['perm', '/vms/{vmid}', [ 'VM.Audit' ]],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    vmid => get_standard_option('pve-vmid'),
	},
    },
    returns => { 
	type => "object",
	properties => {
	    digest => {
		type => 'string',
		description => 'SHA1 digest of configuration file. This can be used to prevent concurrent modifications.',
	    }
	},
    },
    code => sub {
	my ($param) = @_;

	my $veconf = PVE::OpenVZ::load_config($param->{vmid});

	# we only return selected/converted values
	my $conf = { digest => $veconf->{digest} };

	if ($veconf->{ostemplate} && $veconf->{ostemplate}->{value}) {
	    $conf->{ostemplate} = $veconf->{ostemplate}->{value};
	}
    if ($veconf->{ve_layout} && $veconf->{ve_layout}->{value}) {
        $conf->{ve_layout} = $veconf->{ve_layout}->{value};
    }

	my $stcfg = cfs_read_file("storage.cfg");

	my ($sid, undef, $path) = &$get_container_storage($stcfg, $param->{vmid}, $veconf);
	$conf->{storage} = $sid || $path;

	my $properties = PVE::OpenVZ::json_config_properties();

	foreach my $k (keys %$properties) {
	    next if $k eq 'memory';
	    next if $k eq 'swap';
	    next if $k eq 'disk';

	    next if !$veconf->{$k};
	    next if !defined($veconf->{$k}->{value});

	    if ($k eq 'description') {
		$conf->{$k} = PVE::Tools::decode_text($veconf->{$k}->{value});
	    } else {
		$conf->{$k} = $veconf->{$k}->{value};
	    }
	}

	($conf->{memory}, $conf->{swap}) = PVE::OpenVZ::ovz_config_extract_mem_swap($veconf, 1024*1024);

	my $diskspace = $veconf->{diskspace}->{bar} || LONG_MAX;
	if ($diskspace == LONG_MAX) {
	    $conf->{disk} = 0;
	} else {
	    $conf->{disk} = $diskspace/(1024*1024);
	}
	return $conf;
    }});

__PACKAGE__->register_method({
    name => 'destroy_vm', 
    path => '{vmid}', 
    method => 'DELETE',
    protected => 1,
    proxyto => 'node',
    description => "Destroy the container (also delete all uses files).",
    permissions => {
	check => [ 'perm', '/vms/{vmid}', ['VM.Allocate']],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    vmid => get_standard_option('pve-vmid'),
	},
    },
    returns => { 
	type => 'string',
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();

	my $authuser = $rpcenv->get_user();

	my $vmid = $param->{vmid};

	# test if VM exists
	my $conf = PVE::OpenVZ::load_config($param->{vmid});

	my $realcmd = sub {
	    my $cmd = ['vzctl', 'destroy', $vmid ];

	    run_command($cmd);

	    PVE::Database::remove_vmdb_conf($vmid);

	    PVE::AccessControl::remove_vm_from_pool($vmid);
	};

	return $rpcenv->fork_worker('vzdestroy', $vmid, $authuser, $realcmd);
    }});
	
__PACKAGE__->register_method({
    name => 'reinstall_vm', 
    path => '{vmid}/reinstall', 
    method => 'POST',
    protected => 1,
    proxyto => 'node',
    description => "Reinstalls the container (also delete all uses files).",
    permissions => {
	check => [ 'perm', '/vms/{vmid}', ['VM.Allocate']],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    vmid => get_standard_option('pve-vmid'),
	    ostemplate => {
			description => "The OS template",
			type => 'string', 
			maxLength => 255,
	    },
		password => {
			type => 'string',
			description => 'Sets root password inside container.',
			minLength => 5,
		},
	},
    },
    returns => { 
	type => 'string',
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();

	my $authuser = $rpcenv->get_user();

	my $node = extract_param($param, 'node');
	
	my $vmid = extract_param($param, 'vmid');
	
	my $ostemplate = extract_param($param, 'ostemplate');
	
	my $password = extract_param($param, 'password');
	
	my $storage_cfg = cfs_read_file("storage.cfg");

	# test if VM exists
	my $conf = PVE::OpenVZ::load_config($vmid);
	my $privatedir = PVE::OpenVZ::get_privatedir($conf, $vmid);
	
	my $archive;
	
	if ($ostemplate eq '-') {
	    die "pipe can only be used with restore tasks\n" 
	} else {
	    $rpcenv->check_volume_access($authuser, $storage_cfg, $vmid, $ostemplate);
	    $archive = PVE::Storage::abs_filesystem_path($storage_cfg, $ostemplate);
	}
	
	die "CT $vmid running! Please stop it first\n" if PVE::OpenVZ::check_running($vmid);
	
	my $check_vmid_usage = sub {
		die "cant overwrite mounted container\n" 
		    if PVE::OpenVZ::check_mounted($conf, $vmid);
	};

	my $code = sub {
		&$check_vmid_usage(); # final check after locking
		
		PVE::Cluster::check_cfs_quorum();
		
		PVE::OpenVZ::reinstallContainer($vmid, $archive);
		
		# is this really needed?
		my $cmd = ['vzctl', '--skiplock', '--quiet', 'set', $vmid, 
			   '--applyconfig_map', 'name', '--save'];
		run_command($cmd);
		
		# and setting root password
		PVE::OpenVZ::set_rootpasswd($vmid, $password) 
		    if defined($password);

	};
	
	my $realcmd = sub { PVE::OpenVZ::lock_container($vmid, 1, $code); };
	
	&$check_vmid_usage(); # first check before locking

	return $rpcenv->fork_worker('vzreinstall', $vmid, $authuser, $realcmd);
    }});

my $sslcert;

__PACKAGE__->register_method ({
    name => 'vncproxy', 
    path => '{vmid}/vncproxy', 
    method => 'POST',
    protected => 1,
    permissions => {
	check => ['perm', '/vms/{vmid}', [ 'VM.Console' ]],
    },
    description => "Creates a TCP VNC proxy connections.",
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    vmid => get_standard_option('pve-vmid'),
	    websocket => {
		optional => 1,
		type => 'boolean',
		description => "use websocket instead of standard VNC.",
	    },
	},
    },
    returns => { 
    	additionalProperties => 0,
	properties => {
	    user => { type => 'string' },
	    ticket => { type => 'string' },
	    cert => { type => 'string' },
	    port => { type => 'integer' },
	    upid => { type => 'string' },
	},
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();

	my $authuser = $rpcenv->get_user();

	my $vmid = $param->{vmid};
	my $node = $param->{node};

	my $authpath = "/vms/$vmid";

	my $ticket = PVE::AccessControl::assemble_vnc_ticket($authuser, $authpath);

	$sslcert = PVE::Tools::file_get_contents("/etc/pve/pve-root-ca.pem", 8192)
	    if !$sslcert;

	my $port = PVE::Tools::next_vnc_port();

	my $remip;
	
	if ($node ne PVE::INotify::nodename()) {
	    $remip = PVE::Cluster::remote_node_ip($node);
	}

	# NOTE: vncterm VNC traffic is already TLS encrypted,
	# so we select the fastest chipher here (or 'none'?)
	my $remcmd = $remip ? 
	    ['/usr/bin/ssh', '-t', $remip] : [];

	my $shcmd = [ '/usr/bin/dtach', '-A', 
		      "/var/run/dtach/vzctlconsole$vmid", 
		      '-r', 'winch', '-z', 
		      '/usr/sbin/vzctl', 'console', $vmid ];

	my $realcmd = sub {
	    my $upid = shift;

	    syslog ('info', "starting openvz vnc proxy $upid\n");

	    my $timeout = 10; 

	    my $cmd = ['/usr/bin/vncterm', '-rfbport', $port,
		       '-timeout', $timeout, '-authpath', $authpath, 
		       '-perm', 'VM.Console'];

	    if ($param->{websocket}) {
		$ENV{PVE_VNC_TICKET} = $ticket; # pass ticket to vncterm 
		push @$cmd, '-notls', '-listen', 'localhost';
	    }

	    push @$cmd, '-c', @$remcmd, @$shcmd;

	    run_command($cmd);

	    return;
	};

	my $upid = $rpcenv->fork_worker('vncproxy', $vmid, $authuser, $realcmd);

	PVE::Tools::wait_for_vnc_port($port);

	return {
	    user => $authuser,
	    ticket => $ticket,
	    port => $port, 
	    upid => $upid, 
	    cert => $sslcert, 
	};
    }});

__PACKAGE__->register_method({
    name => 'vncwebsocket',
    path => '{vmid}/vncwebsocket',
    method => 'GET',
    permissions => { 
	description => "You also need to pass a valid ticket (vncticket).",
	check => ['perm', '/vms/{vmid}', [ 'VM.Console' ]],
    },
    description => "Opens a weksocket for VNC traffic.",
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    vmid => get_standard_option('pve-vmid'),
	    vncticket => {
		description => "Ticket from previous call to vncproxy.",
		type => 'string',
		maxLength => 512,
	    },
	    port => {
		description => "Port number returned by previous vncproxy call.",
		type => 'integer',
		minimum => 5900,
		maximum => 5999,
	    },
	},
    },
    returns => {
	type => "object",
	properties => {
	    port => { type => 'string' },
	},
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();

	my $authuser = $rpcenv->get_user();

	my $authpath = "/vms/$param->{vmid}";

	PVE::AccessControl::verify_vnc_ticket($param->{vncticket}, $authuser, $authpath);

	my $port = $param->{port};
	
	return { port => $port };
    }});

__PACKAGE__->register_method ({
    name => 'spiceproxy', 
    path => '{vmid}/spiceproxy', 
    method => 'POST',
    protected => 1,
    proxyto => 'node',
    permissions => {
	check => ['perm', '/vms/{vmid}', [ 'VM.Console' ]],
    },
    description => "Returns a SPICE configuration to connect to the CT.",
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    vmid => get_standard_option('pve-vmid'),
	    proxy => get_standard_option('spice-proxy', { optional => 1 }),
	},
    },
    returns => get_standard_option('remote-viewer-config'),
    code => sub {
	my ($param) = @_;

	my $vmid = $param->{vmid};
	my $node = $param->{node};
	my $proxy = $param->{proxy};

	my $authpath = "/vms/$vmid";
	my $permissions = 'VM.Console';

	my $shcmd = ['/usr/bin/dtach', '-A', 
		     "/var/run/dtach/vzctlconsole$vmid", 
		     '-r', 'winch', '-z', 
		     '/usr/sbin/vzctl', 'console', $vmid];

	my $title = "CT $vmid";

	return PVE::API2Tools::run_spiceterm($authpath, $permissions, $vmid, $node, $proxy, $title, $shcmd);
    }});

__PACKAGE__->register_method({
    name => 'vmcmdidx',
    path => '{vmid}/status', 
    method => 'GET',
    proxyto => 'node',
    description => "Directory index",
    permissions => {
	user => 'all',
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    vmid => get_standard_option('pve-vmid'),
	},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => {
		subdir => { type => 'string' },
	    },
	},
	links => [ { rel => 'child', href => "{subdir}" } ],
    },
    code => sub {
	my ($param) = @_;

	# test if VM exists
	my $conf = PVE::OpenVZ::load_config($param->{vmid});

	my $res = [
	    { subdir => 'current' },
	    { subdir => 'ubc' },
	    { subdir => 'start' },
	    { subdir => 'stop' },
	    ];
	
	return $res;
    }});

my $vm_is_ha_managed = sub {
    my ($vmid) = @_;

    my $cc = PVE::Cluster::cfs_read_file('cluster.conf');
    if (PVE::Cluster::cluster_conf_lookup_pvevm($cc, 0, $vmid, 1)) {
	return 1;
    } 
    return 0;
};

__PACKAGE__->register_method({
    name => 'vm_status', 
    path => '{vmid}/status/current',
    method => 'GET',
    proxyto => 'node',
    protected => 1, # openvz /proc entries are only readable by root
    description => "Get virtual machine status.",
    permissions => {
	check => ['perm', '/vms/{vmid}', [ 'VM.Audit' ]],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    vmid => get_standard_option('pve-vmid'),
	},
    },
    returns => { type => 'object' },
    code => sub {
	my ($param) = @_;

	# test if VM exists
	my $conf = PVE::OpenVZ::load_config($param->{vmid});

	my $vmstatus =  PVE::OpenVZ::vmstatus($param->{vmid});
	my $status = $vmstatus->{$param->{vmid}};

	$status->{ha} = &$vm_is_ha_managed($param->{vmid});

	return $status;
    }});

__PACKAGE__->register_method({
    name => 'vm_user_beancounters', 
    path => '{vmid}/status/ubc',
    method => 'GET',
    proxyto => 'node',
    protected => 1, # openvz /proc entries are only readable by root
    description => "Get container user_beancounters.",
    permissions => {
	check => ['perm', '/vms/{vmid}', [ 'VM.Audit' ]],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    vmid => get_standard_option('pve-vmid'),
	},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => {
		id => { type => 'string' },
		held => { type => 'number' },
		maxheld => { type => 'number' },
		bar => { type => 'number' },
		lim => { type => 'number' },
		failcnt => { type => 'number' },
	    },
	},
    },
    code => sub {
	my ($param) = @_;

	# test if VM exists
	my $conf = PVE::OpenVZ::load_config($param->{vmid});

	my $ubchash = PVE::OpenVZ::read_user_beancounters();
	my $ubc = $ubchash->{$param->{vmid}} || {};
	delete $ubc->{failcntsum};

	return PVE::RESTHandler::hash_to_array($ubc, 'id');
    }});

__PACKAGE__->register_method({
    name => 'vm_start', 
    path => '{vmid}/status/start',
    method => 'POST',
    protected => 1,
    proxyto => 'node',
    description => "Start the container.",
    permissions => {
	check => ['perm', '/vms/{vmid}', [ 'VM.PowerMgmt' ]],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    vmid => get_standard_option('pve-vmid'),
	},
    },
    returns => { 
	type => 'string',
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();

	my $authuser = $rpcenv->get_user();

	my $node = extract_param($param, 'node');

	my $vmid = extract_param($param, 'vmid');

	die "CT $vmid already running\n" if PVE::OpenVZ::check_running($vmid);

	if (&$vm_is_ha_managed($vmid) && $rpcenv->{type} ne 'ha') {

	    my $hacmd = sub {
		my $upid = shift;

		my $service = "pvevm:$vmid";

		my $cmd = ['clusvcadm', '-e', $service, '-m', $node];

		print "Executing HA start for CT $vmid\n";

		PVE::Tools::run_command($cmd);

		return;
	    };

	    return $rpcenv->fork_worker('hastart', $vmid, $authuser, $hacmd);

	} else {

	    my $realcmd = sub {
		my $upid = shift;

		syslog('info', "starting CT $vmid: $upid\n");

		my $veconf = PVE::OpenVZ::load_config($vmid);
		my $stcfg = cfs_read_file("storage.cfg");
		if (my $sid = &$get_container_storage($stcfg, $vmid, $veconf)) {
		    PVE::Storage::activate_storage($stcfg, $sid);
		}

		my $vzconf = PVE::OpenVZ::read_global_vz_config();
		
		# make sure mount point is there (see bug #276)
		my $root = PVE::OpenVZ::get_rootdir($veconf, $vmid);
		mkpath $root || die "unable to create root dir '$root'";

		my $cmd = ['vzctl', 'start', $vmid];
	    
		run_command($cmd);

		return;
	    };

	    return $rpcenv->fork_worker('vzstart', $vmid, $authuser, $realcmd);
	}
    }});

__PACKAGE__->register_method({
    name => 'vm_stop', 
    path => '{vmid}/status/stop',
    method => 'POST',
    protected => 1,
    proxyto => 'node',
    description => "Stop the container.",
    permissions => {
	check => ['perm', '/vms/{vmid}', [ 'VM.PowerMgmt' ]],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    vmid => get_standard_option('pve-vmid'),
	},
    },
    returns => { 
	type => 'string',
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();

	my $authuser = $rpcenv->get_user();

	my $node = extract_param($param, 'node');

	my $vmid = extract_param($param, 'vmid');

	die "CT $vmid not running\n" if !PVE::OpenVZ::check_running($vmid);

	if (&$vm_is_ha_managed($vmid) && $rpcenv->{type} ne 'ha') {

	    my $hacmd = sub {
		my $upid = shift;

		my $service = "pvevm:$vmid";

		my $cmd = ['clusvcadm', '-d', $service];

		print "Executing HA stop for CT $vmid\n";

		PVE::Tools::run_command($cmd);

		return;
	    };

	    return $rpcenv->fork_worker('hastop', $vmid, $authuser, $hacmd);

	} else {

	    my $realcmd = sub {
		my $upid = shift;

		syslog('info', "stoping CT $vmid: $upid\n");

		my $cmd = ['vzctl', 'stop', $vmid, '--fast'];
		run_command($cmd);
	    
		return;
	    };

	    return $rpcenv->fork_worker('vzstop', $vmid, $authuser, $realcmd);
	}
    }});

__PACKAGE__->register_method({
    name => 'vm_mount', 
    path => '{vmid}/status/mount',
    method => 'POST',
    protected => 1,
    proxyto => 'node',
    description => "Mounts container private area.",
    permissions => {
	check => ['perm', '/vms/{vmid}', [ 'VM.PowerMgmt' ]],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    vmid => get_standard_option('pve-vmid'),
	},
    },
    returns => { 
	type => 'string',
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();

	my $authuser = $rpcenv->get_user();

	my $node = extract_param($param, 'node');

	my $vmid = extract_param($param, 'vmid');

	die "CT $vmid is running\n" if PVE::OpenVZ::check_running($vmid);

	my $realcmd = sub {
	    my $upid = shift;

	    syslog('info', "mount CT $vmid: $upid\n");

	    my $cmd = ['vzctl', 'mount', $vmid];
	    
	    run_command($cmd);

	    return;
	};

	return $rpcenv->fork_worker('vzmount', $vmid, $authuser, $realcmd);
    }});

__PACKAGE__->register_method({
    name => 'vm_umount', 
    path => '{vmid}/status/umount',
    method => 'POST',
    protected => 1,
    proxyto => 'node',
    description => "Unmounts container private area.",
    permissions => {
	check => ['perm', '/vms/{vmid}', [ 'VM.PowerMgmt' ]],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    vmid => get_standard_option('pve-vmid'),
	},
    },
    returns => { 
	type => 'string',
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();

	my $authuser = $rpcenv->get_user();

	my $node = extract_param($param, 'node');

	my $vmid = extract_param($param, 'vmid');

	die "CT $vmid is running\n" if PVE::OpenVZ::check_running($vmid);

	my $realcmd = sub {
	    my $upid = shift;

	    syslog('info', "umount CT $vmid: $upid\n");

	    my $cmd = ['vzctl', 'umount', $vmid];
	    
	    run_command($cmd);

	    return;
	};

	return $rpcenv->fork_worker('vzumount', $vmid, $authuser, $realcmd);
    }});

__PACKAGE__->register_method({
    name => 'vm_shutdown', 
    path => '{vmid}/status/shutdown',
    method => 'POST',
    protected => 1,
    proxyto => 'node',
    description => "Shutdown the container.",
    permissions => {
	check => ['perm', '/vms/{vmid}', [ 'VM.PowerMgmt' ]],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    vmid => get_standard_option('pve-vmid'),
	    timeout => {
		description => "Wait maximal timeout seconds.",
		type => 'integer',
		minimum => 0,
		optional => 1,
		default => 60,
	    },
	    forceStop => {
		description => "Make sure the Container stops.",
		type => 'boolean',
		optional => 1,
		default => 0,
	    }
	},
    },
    returns => { 
	type => 'string',
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();

	my $authuser = $rpcenv->get_user();

	my $node = extract_param($param, 'node');

	my $vmid = extract_param($param, 'vmid');

	my $timeout = extract_param($param, 'timeout');

	die "CT $vmid not running\n" if !PVE::OpenVZ::check_running($vmid);

	my $realcmd = sub {
	    my $upid = shift;

	    syslog('info', "shutdown CT $vmid: $upid\n");

	    my $cmd = ['vzctl', 'stop', $vmid];

	    $timeout = 60 if !defined($timeout);

	    eval { run_command($cmd, timeout => $timeout); };
	    my $err = $@;
	    return if !$err;

	    die $err if !$param->{forceStop};

	    warn "shutdown failed - forcing stop now\n";

	    push @$cmd, '--fast';
	    run_command($cmd);
	    
	    return;
	};

	my $upid = $rpcenv->fork_worker('vzshutdown', $vmid, $authuser, $realcmd);

	return $upid;
    }});

__PACKAGE__->register_method({
    name => 'vm_suspend',
    path => '{vmid}/status/suspend',
    method => 'POST',
    protected => 1,
    proxyto => 'node',
    description => "Suspend the container.",
    permissions => {
        check => ['perm', '/vms/{vmid}', [ 'VM.PowerMgmt' ]],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
        },
    },
    returns => {
        type => 'string',
    },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();

        my $authuser = $rpcenv->get_user();

        my $node = extract_param($param, 'node');

        my $vmid = extract_param($param, 'vmid');

        die "CT $vmid not running\n" if !PVE::OpenVZ::check_running($vmid);

        my $realcmd = sub {
            my $upid = shift;

            syslog('info', "suspend CT $vmid: $upid\n");

            PVE::OpenVZ::vm_suspend($vmid);

            return;
        };

        my $upid = $rpcenv->fork_worker('vzsuspend', $vmid, $authuser, $realcmd);

        return $upid;
    }});

__PACKAGE__->register_method({
    name => 'vm_resume',
    path => '{vmid}/status/resume',
    method => 'POST',
    protected => 1,
    proxyto => 'node',
    description => "Resume the container.",
    permissions => {
        check => ['perm', '/vms/{vmid}', [ 'VM.PowerMgmt' ]],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
        },
    },
    returns => {
        type => 'string',
    },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();

        my $authuser = $rpcenv->get_user();

        my $node = extract_param($param, 'node');

        my $vmid = extract_param($param, 'vmid');

        die "CT $vmid already running\n" if PVE::OpenVZ::check_running($vmid);

        my $realcmd = sub {
            my $upid = shift;

            syslog('info', "resume CT $vmid: $upid\n");

            PVE::OpenVZ::vm_resume($vmid);

            return;
        };

        my $upid = $rpcenv->fork_worker('vzresume', $vmid, $authuser, $realcmd);

        return $upid;
    }});

__PACKAGE__->register_method({
    name => 'migrate_vm', 
    path => '{vmid}/migrate',
    method => 'POST',
    protected => 1,
    proxyto => 'node',
    description => "Migrate the container to another node. Creates a new migration task.",
    permissions => {
	check => ['perm', '/vms/{vmid}', [ 'VM.Migrate' ]],
    },
    parameters => {
    	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    vmid => get_standard_option('pve-vmid'),
	    target => get_standard_option('pve-node', { description => "Target node." }),
	    online => {
		type => 'boolean',
		description => "Use online/live migration.",
		optional => 1,
	    },
	},
    },
    returns => { 
	type => 'string',
	description => "the task ID.",
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();

	my $authuser = $rpcenv->get_user();

	my $target = extract_param($param, 'target');

	my $localnode = PVE::INotify::nodename();
	raise_param_exc({ target => "target is local node."}) if $target eq $localnode;

	PVE::Cluster::check_cfs_quorum();

	PVE::Cluster::check_node_exists($target);

	my $targetip = PVE::Cluster::remote_node_ip($target);

	my $vmid = extract_param($param, 'vmid');

	# test if VM exists
	PVE::OpenVZ::load_config($vmid);

	# try to detect errors early
	if (PVE::OpenVZ::check_running($vmid)) {
	    die "cant migrate running container without --online\n" 
		if !$param->{online};
	}

	if (&$vm_is_ha_managed($vmid) && $rpcenv->{type} ne 'ha') {

	    my $hacmd = sub {
		my $upid = shift;

		my $service = "pvevm:$vmid";

		my $cmd = ['clusvcadm', '-M', $service, '-m', $target];

		print "Executing HA migrate for CT $vmid to node $target\n";

		PVE::Tools::run_command($cmd);

		return;
	    };

	    return $rpcenv->fork_worker('hamigrate', $vmid, $authuser, $hacmd);

	} else {

	    my $realcmd = sub {
		my $upid = shift;

		PVE::OpenVZMigrate->migrate($target, $targetip, $vmid, $param);

		return;
	    };

	    return $rpcenv->fork_worker('vzmigrate', $vmid, $authuser, $realcmd);
	}
    }});

__PACKAGE__->register_method({
    name => 'snapshot_list',
    path => '{vmid}/snapshot',
    method => 'GET',
    protected => 1,
    proxyto => 'node',
    description => "List all snapshots.",
    permissions => {
        check => ['perm', '/vms/{vmid}', [ 'VM.Audit' ]],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
        },
    },
    returns => {
        type => 'array',
        items => {
            type => "object",
            properties => {},
        }
    },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();

        my $authuser = $rpcenv->get_user();

        my $node = extract_param($param, 'node');

        my $vmid = extract_param($param, 'vmid');

        my $res = [];

        my $snapshots = PVE::OpenVZ::getSnapshots($vmid);

        foreach my $uuid (keys %$snapshots) {
            my $d = $snapshots->{$uuid};
            my $item = {
                parent => $d->{parent},
                uuid => $uuid,
                current => $d->{current},
                date => $d->{date},
                name => $d->{name}
            };
            push @$res, $item;
        }

        return $res;
    }
});

__PACKAGE__->register_method({
    name => 'snapshot',
    path => '{vmid}/snapshot',
    method => 'POST',
    protected => 1,
    proxyto => 'node',
    description => "Snapshot a container.",
    permissions => {
        check => ['perm', '/vms/{vmid}', [ 'VM.Snapshot' ]],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
            name => {
                optional => 1,
                type => 'string',
                description => 'A name/description of the snapshot',
                maxLength => 40
            },
            skipsuspend => {
                optional => 1,
                type => 'boolean',
                description => 'If a container is running, and skipsuspend option is not specified, a container is checkpointed and then restored, and CT memory dump becomes the part of snapshot.'
            }
        },
    },
    returns => {
        type => 'string',
        description => "the task ID.",
    },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();

        my $authuser = $rpcenv->get_user();

        my $node = extract_param($param, 'node');

        my $vmid = extract_param($param, 'vmid');

        my $name = extract_param($param, 'name');

        my $realcmd = sub {
            PVE::Cluster::log_msg('info', $authuser, "snapshot CT $vmid: $name");
            PVE::OpenVZ::createSnapshot($vmid, $name, $param->{skipsuspend});
        };

        return $rpcenv->fork_worker('vzsnapshot', $vmid, $authuser, $realcmd);
    }
});

__PACKAGE__->register_method({
    name => 'snapshot_delete',
    path => '{vmid}/snapshot/{uuid}',
    method => 'DELETE',
    protected => 1,
    proxyto => 'node',
    description => "Delete a CT snapshot",
    permissions => {
        check => ['perm', '/vms/{vmid}', [ 'VM.Snapshot' ]],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
            uuid => {
                type => 'string',
                description => 'UUID of the snapshot',
                minLength => 36, # normal length of an UUID
                maxLength => 36
            },
        },
    },
    returns => {
        type => 'string',
        description => "the task ID.",
    },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();

        my $authuser = $rpcenv->get_user();

        my $node = extract_param($param, 'node');

        my $vmid = extract_param($param, 'vmid');

        my $uuid = extract_param($param, 'uuid');

        my $snapshots = PVE::OpenVZ::getSnapshots($vmid);

        die "snapshot not found for CT $vmid: $uuid" if !$snapshots->{$uuid};

        my $realcmd = sub {
            PVE::Cluster::log_msg('info', $authuser, "delete snapshot CT $vmid: $uuid");
            PVE::OpenVZ::deleteSnapshot($vmid, $uuid);
        };

        return $rpcenv->fork_worker('vzdelsnapshot', $vmid, $authuser, $realcmd);
    }
});

__PACKAGE__->register_method({
    name => 'snapshot_switch',
    path => '{vmid}/snapshot/{uuid}/switch',
    method => 'POST',
    protected => 1,
    proxyto => 'node',
    description => "Switches the container to a snapshot identified by uuid, restoring its file system state, configuration (if available) and its running state (if available).",
    permissions => {
        check => ['perm', '/vms/{vmid}', [ 'VM.Snapshot' ]],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
            uuid => {
                type => 'string',
                description => 'UUID of the snapshot',
                minLength => 36, # normal length of an UUID
                maxLength => 36
            },
        },
    },
    returns => {
        type => 'string',
        description => "the task ID.",
    },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();

        my $authuser = $rpcenv->get_user();

        my $node = extract_param($param, 'node');

        my $vmid = extract_param($param, 'vmid');

        my $uuid = extract_param($param, 'uuid');

        my $snapshots = PVE::OpenVZ::getSnapshots($vmid);

        die "snapshot not found for CT $vmid: $uuid" if !$snapshots->{$uuid};

        my $realcmd = sub {
            PVE::Cluster::log_msg('info', $authuser, "switch snapshot CT $vmid: $uuid");
            PVE::OpenVZ::switchSnapshot($vmid, $uuid);
        };

        return $rpcenv->fork_worker('vzsnapshotswitch', $vmid, $authuser, $realcmd);
    }
});

__PACKAGE__->register_method({
    name => 'compact',
    path => '{vmid}/compact',
    method => 'POST',
    protected => 1,
    proxyto => 'node',
    description => "Compact container image. This only makes sense for ploop layout.",
    permissions => {
        check => ['perm', '/vms/{vmid}', [ 'VM.Allocate' ]],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            vmid => get_standard_option('pve-vmid'),
        },
    },
    returns => {
        type => 'string',
        description => "the task ID.",
    },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();

        my $authuser = $rpcenv->get_user();

        my $node = extract_param($param, 'node');

        my $vmid = extract_param($param, 'vmid');

        my $realcmd = sub {
            PVE::Cluster::log_msg('info', $authuser, "compact CT $vmid");
            PVE::OpenVZ::compactContainer($vmid);
        };

        return $rpcenv->fork_worker('vzcompact', $vmid, $authuser, $realcmd);
    }
});

1;
