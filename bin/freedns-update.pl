#!/usr/bin/perl

use warnings;
use strict;

use Getopt::Long;
use Config::General;
use POSIX qw(strftime);
#use Data::Dumper;
$|=1;

my $config_file = '/etc/freedns-update/freedns-update.conf';
my $log_file    = '/var/log/freedns-update/freedns-update.log';
my $pid_file	= '/var/run/freedns-update/freedns-update.pid';
my $file_cache	= '/var/tmp/freedns-update.cfg';

my $no_update_limit = 5*60;
my $update_period   = 60;

my $help=undef;
my $daemon=undef;

GetOptions (
	'h|help' 	=> \$help,
	'd|daemon' 	=> \$daemon
);

if (defined $help){
	print get_usage();
	exit 0;
}

for my $dir ('/var/log/freedns-update/','/var/run/freedns-update/'){
	`mdir $dir` unless -d $dir;
	`chmod 777 $dir`;
}

if(defined $daemon){
	open_log();
	write_pid_file();
	#reopen log on HUP
	$SIG{HUP}=\&open_log;
	#remove pid on exit
	$SIG{TERM}=sub{
		unlink $pid_file;
		exit;
	};
	while(1){
		freeDnsUpdate();
		print_log("sleep $update_period seconds");
		sleep $update_period;
	}
	print_log("ERROR: process stopped!");
	exit 1;
}else{
	freeDnsUpdate();
	exit 0;
}

sub freeDnsUpdate{
	my $config = Config::General->new($config_file);
	my %config = $config->getall;

	#read <freedns> blocks from config file
	my $freedns_entries	= $config{freedns};
	if(ref($freedns_entries)ne 'ARRAY'){
		$freedns_entries= [$freedns_entries];
	}
	if(@$freedns_entries==0){
		print_log("ERROR: Please configure at least one <freedns> block at '$config_file'!");
		return;
	}

	#read <ipcheck> blocks from config file
	my $ipcheck_urls	= $config{ipcheck};
	if(ref($ipcheck_urls)ne 'ARRAY'){
		$ipcheck_urls   = [$ipcheck_urls];
	}
	if(@$ipcheck_urls==0){
		print_log("ERROR: Please configure at least one <ipcheck> block at '$config_file'!");
		return;
	}

	#get entries by URL
	my $entries={};
	for my $entry (@$freedns_entries){
		unless (defined $entry->{url}){
			print_log("Please specify at least one 'url' at <freedns> at '$config_file' with your freedns hash key!");
			next;
		}
		if($entry->{url}=~/FREEDNS_UPDATE_HASH$/){
			print_log("skip updating '$entry->{url}'");
			print_log("Please replace FREEDNS_UPDATE_HASH at url in '$config_file' with your freedns hash key!");
			next;
		}
		$entries->{$entry->{url}}=$entry;
	}

	#stop if no valid entry was found
	my @entry_urls=keys %$entries;
	if (@entry_urls==0){
		print_log("ERROR: found no valid entries at '$config_file'.");
		return;
	}

	$entries=read_cache($entries);
	#iterate over all freedns urls
	my $update=undef;
	for my $url (@entry_urls){
		my $entry=$entries->{$url};

		#get seconds since last update
		$entry->{time}=0 unless (defined $entry->{time});
		my $last_update=time()-$entry->{time};
		print_log($last_update." seconds since last update");

		my $gateway_message='';
		$gateway_message=' using gateway '.$entry->{gateway} if(defined $entry->{gateway});

		#ignore new requests within $no_update_limit seconds after last update
		unless($last_update > $no_update_limit){
			print_log("skip updating '$url'".$gateway_message);
			next;
		}

		#go through all ip checkers until one returns an IP
		for my $checker (@$ipcheck_urls){
			my $message="check ip '".$checker->{url}."'".$gateway_message;
			print_log($message);

			my $result=http_get($checker->{url}, $entry->{gateway});
			chomp $result;

			my $pattern=$checker->{pattern};
			if ($result=~/$pattern/){
				my $ip=$1;
				if($ip=~/([\d\.\:]{3,})/){
					$entry->{new_ip}=$1;
					print_log("found ip '".$entry->{new_ip}."'");
					last;
				}else{
					print_log("found invalid ip '$ip'");
				}
			}
		}
		#trigger update, if ip could not be detected
		unless(defined $entry->{new_ip}){
			print_log("could not determine current ip, trigger update");
			$entry->{new_ip}='different';
		}
		unless(defined $entry->{old_ip}){
			$entry->{old_ip}='';
		}

		#trigger DNS update and mark cache to be saved, if ip has changed.
		if($entry->{new_ip} ne $entry->{old_ip}){
			print_log("update freedns entry '".$url."' with ip '".$entry->{new_ip}."'");
			$entry->{time}=time;
			http_get($entry->{url}, $entry->{gateway});
			$update=1;
		}else{
			print_log("no update, ip '".$entry->{new_ip}."' has not changed.");
		}
	
	}
	write_cache($entries) if(defined $update);
}

sub read_cache{
	my $entries=shift;
	open my $FILE, "<$file_cache";
	while(<$FILE>){
		my $line=$_;
		chomp $line;
		my ($time, $url, $ip)=split(/\t/,$line);
		if(defined $url){
			$entries->{$url}->{time} = $time;
			$entries->{$url}->{old_ip} = $ip;
		}
	}
	close $FILE;
	return $entries;
}

sub write_cache{
	my $entries=shift;
	open my $FILE, ">$file_cache";
	for my $url (keys %$entries){
		my $entry=$entries->{$url};
		next unless (defined $entry->{url});
		my $line=join("\t", ($entry->{time}, $entry->{url}, $entry->{new_ip}||$entry->{old_ip}) );
		print $FILE $line."\n";
	}
	close $FILE;
}

sub open_log{
	if(-e $log_file){
		open(STDOUT, ">>".$log_file)  or die "cannot open logfile '$log_file'";
		print_log("reopen log");
	}else{
		open(STDOUT, ">".$log_file)  or die "cannot open logfile '$log_file'";
		print_log("open log");
	}
	open STDERR, '>&STDOUT' or die "Can't dup STDOUT: $!";
}

sub write_pid_file{
	print_log("write pid file '$pid_file'");
	open (PIDFILE,">".$pid_file) or die "cannot write pid file '$pid_file'";
	print PIDFILE "$$";
	close(PIDFILE);	
}

sub http_get{
	my $url		= shift;
	my $gateway	= shift;

	my $cmd='wget -qO-';
	$cmd.=' --bind-address '.$gateway if (defined $gateway);
	$cmd.=' --tries 1 ';
	$cmd.=' --timeout 5 ';
	$cmd.=' '.$url;
	$cmd.=' 2>&1';
	print_log("execute  '".$cmd."'");

	my $result=`$cmd`;
	print_log($result);
	print_log($?) if($?);
	return $result;
}

sub print_log{
	my $message=shift;
	print strftime('%Y-%m-%d %H:%M:%S',localtime(time))."\t".$message."\n";
}

sub get_usage{
return qq{
SYNOPSIS
        $0 --daemon --help

OPTIONS
        --daemon  write output to '$log_file'
        --help    this help

DESCRIPTION
	updates one or more freedns accounts.

	Configuration is read from '$config_file'
	The configuration file consists of at least one <freedns> block and at least one <ipcheck> block.

	<freedns> blocks consist of an 'url' and an optional 'gateway'.
	put the update URL from the freedns website to the 'url' parameter
	You can use multiple entries with different gateways to access your system by multiple internet access points.

	A <ipcheck> block consists of an 'url' and a 'pattern'. They are used to get current ip from an given external url.
	The 'pattern' contains a regular expression to extract the ip from the response message that we get from calling the url.
	You can define multiple <ipcheck> points to try to contact the next ip-check URL, if the previous one does not answer.

	Output is written to '$log_file' if you use the --daemon mode.

EXAMPLE:
    Use one ip checker and update 2 freedns accounts using 2 different gateways.
	Replace FREE_DNS_HASH1 and FREE_DNS_HASH2 by your freedns hashkeys.
	If you use one gateway only, remove the second ipcheck entry.
	If you use additional ip-check-URLs, clone and modify the ipcheck entry.
	Configure '$config_file'

<ipcheck>
	url 	http://checkip.dyndns.com/
	pattern Current IP Address:([0-9\.]+)
</ipcheck>

<freedns>
	url     https://freedns.afraid.org/dynamic/update.php?FREE_DNS_HASH1
	gateway 192.168.1.1
</freedns>

<freedns>
	url     https://freedns.afraid.org/dynamic/update.php?FREE_DNS_HASH1
	gateway 192.168.2.1
</freedns>
};

}

#END OF FILE
