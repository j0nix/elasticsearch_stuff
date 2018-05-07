#! /usr/bin/perl
# :: Script for evaluate & delete indexes/indices in a ES cluster
# :: After delete operation script can initiate an optimize and or reroute of indexes.
# :: Expects indexes by date, like => INDEX-2015.01.01
# :: Require a json formated configfile
use strict;
use warnings;
use Sys::Syslog;
use Getopt::Std;
use LWP::UserAgent;
use HTTP::Request::Common;
use v5.10;
#use IO::Socket::SSL;
use DateTime;
use JSON;
use Try::Tiny;
use Switch;

## Set defaults
#default location of configfile
my $configfile = "/etc/index_curator.json";
# default host
my $api_node = "localhost";
#default user credentials 
my $logincredentials = undef;
my $username = '';
my $password = '';
#default protocol
my $protocol = "http";

#optimize, 0 = false, 1 = true 
my $do_optimize = 0;
#default optimize variables
my $optimize_o = "gt";
my $optimize_d = 30;

#reroute, 0 = false, 1 = true 
my $do_reroute = 0;
#default reroute variables
my $reroute_o = undef;
my $reroute_d = undef;
my $reroute_a = undef;
my $reroute_b = undef;
my $replicas = undef;

# Can be set to 1 if you just want to test your config 
my $configtest = 0;

#default ignore_index values
my @ignore = ("kibana","marvel",".kibana",".marvel",".monitoring",".watcher"); 


sub init() {

	my %opts;
	#open for syslog
	openlog("INDEX_CURATOR", "nofatal,pid", "local0");
	syslog('info', "Initilize script $0");

	#fetch flags
	getopts("hztsc:n:x:", \%opts);

	if ($opts{h}) {
        	help();
	}
	if ($opts{z}) {
        	explainShit();
	}

	if ($opts{t}) {
		$configtest = 1;
	}

	if ($opts{s}) {
        	$protocol = "https";
	}

	if ($opts{c}) {
        	$configfile = $opts{c};
	}

	if ($opts{x}) {
        	$logincredentials = $opts{x};
	}

	if ($opts{n}) {
        	$api_node = $opts{n};
	}
}

sub help() {

  print "
  Usage: $0 [-h][-z][-t][s][-n hostname_or_ipaddress][-c path_to_configfile][-x username:password]

        -c      Configuration file, default: /etc/index_curator.json
        -h      This help info
	-z	Print extended help about configfile
	-n	Node/host to execute API calls to, default: localhost
	-t	Configtest, just tests our config & review feddback output, don't execute API calls to cluster.
	-s	use ssl/tls, aka https
	-x	path to file with login credentials, in file defined as => user:password
	
         $0 -xc killerConf.json\n\n


  >> Config file example <<

  {
    \"index_lifetime\": {
      \"debug\":7,
      \"logstash\":30
    },    
    \"ignore_index\": [
      \".kibana\",
      \".marvel\"
    ]
    \"optimize_condition\": {
	\"operator\":\"gt\",
	\"days\":0
    }
    \"reroute_condition\": {
	\"operator\":\"eq\",
	\"days\":5,
	\"attr\":\"box_type\",
	\"attr_value\":\"hot\"
        \"replicas\":\"1\"
    }
	
  }


  NOTE: Required conf => index_lifetime

  CONFIG DEFAULTS set in script:

    - ignore_index: 		" . join(",",@ignore) . "
    - optimize_conditions: 	$optimize_o $optimize_d
    - reroute_condition:	*no default*, but if conditions is set we default to 1 replica.


  \n\n";
  exit;
}

sub explainShit() {
print '

:: CONFIG FILE EXPLAINATION

       IN SHORT: Curator script maintains number of days defined indexes should be searchible in that ElasticSearch cluster. You can also define indexes that should be excluded
       from theese rules. If Index is not defined it will be deleted when script runs. You can also define optimization (force merge) rule of indexes. 
       If you want and "Hot Warm Arcitecture you can also define a reroute rule when indexes should be moved to another node/nodes + nr of replicas fore these. 



       REQUIRED to set => index-lifetime

               {
                       "index_lifetime" : { "indexname_without_date_prefix":nr_of_days_to_keep_index }
               }
               
	       Ex)
               {
               	"index_lifetime" : { "debug":30 }
               }

 
       - Optional is to set an ignore_index array whith index names to ignore any evaluation. Like .marvel and kibana index.
         This is a regexp match => /^$index_name.*/. So... as long as it matches the beginning of the string the condition is true. 

                       "ignore_index": [
                               "kibana",
                               ".kibana",
                               ".marvel"
                       ]
	
	- Optional is also to define optimize_condition. You set logical operator and day number (days are index date diff with todays date).
	  you can use any of these operators: eq, ne, gt, ge, lt or le

                       "optimize_condition": {
				"operator":"ge",
				"days":1
                       }

	- Optional is also to define a reroute_condition. You set logical operator (eq, ne, gt, ge, lt or le) , day number (days are index date diff with todays date), define 
	  wich node attribute that we should use & what value for that node attribute we should reroute to. Also you can define nr of replicas for rerouted indexes. As default 
	  we set rerouted indexes to one replica.

                       "reroute_condition": {
                       	"operator":"eq",
                       	"days":5,
                       	"attr":"box_type", #NOTE: this attribute is defined as "node.box_type = j0nix" in elasticsearch.yml
                       	"attr_value":"j0nix",
			"replicas":0
                       }

	- Example of config with all options:
               {
                       "index_lifetime": {
                       	  "debug":14,
                       	  "j0nix":90,
			  "Pr0n":1825
                       },    
                       "ignore_index": [
                       	  ".kibana",
                       	  ".kibana-int",
                       	  ".marvel"
                       ],
                       "optimize_condition": {
			  "operator":"ge",
			  "days":1
                       },
                       "reroute_condition": {
                       	  "operator":"eq",
                       	  "days":5,
                       	  "attr":"box_type",
                       	  "attr_value":"j0nix",
			  "replicas":0
                       }
               }


j0nix 2016
';
exit;
}

sub get_login {

    my $filename = shift;
    open FILE, $filename or die "Could not read from $filename, ABORTING.";
    chomp(my $record = <FILE>);
    close FILE;
    return $record;
}


#START
init();

$api_node = "$protocol://$api_node:9200";

# Do we have a configfile
if (! -f $configfile) {
        print "\n\n\t '$configfile' not found...\n\n";
        syslog('err', "'$configfile' not found...");
        help();
}

#read configfile
my $json;
{
  local $/; #Enable 'slurp' mode
  open my $fh, "<", $configfile;
  $json = <$fh>;
  $json =~ s/^#.*//mg;
  close $fh;
}

#decode configfile
my $config;
try {
        $config = decode_json($json);
} catch {
        warn "\n\t !! DUDE, what have you done!? We got an error when parsing json config file. \n\nERRMSG: $_ \n\n";
        syslog('err', "ERROR, $0 got error when parsing json config file " . $configfile . ". Please correct error ASAP! :: $_ !");
        exit 1;
};

#verify that we have some config data
unless (defined $config->{'index_lifetime'}) {
        print "index_lifetime is not defined in configfile $configfile ... Aborting\n";
        syslog('err', "ERROR, index_lifetime is not defined in configfile $configfile ... Aborting");
        exit 1;
}

#if set in config, set new ignore_index values
unless (!defined $config->{'ignore_index'}) {
        @ignore = @{ $config->{'ignore_index'} };
}

#if set in config, set new optimization conditions
if(defined $config->{'optimize_condition'}->{"operator"} && defined $config->{'optimize_condition'}->{"days"}) {
        $optimize_o = $config->{'optimize_condition'}->{"operator"};
	$optimize_d = $config->{'optimize_condition'}->{"days"};
        $do_optimize = 1;	
}
#if set in config, set new optimization conditions
if(defined $config->{'reroute_condition'}->{"operator"} && defined $config->{'reroute_condition'}->{"days"} && defined $config->{'reroute_condition'}->{"attr"} && defined $config->{'reroute_condition'}->{"attr_value"}) {
        $reroute_o = $config->{'reroute_condition'}->{"operator"};
	$reroute_d = $config->{'reroute_condition'}->{"days"};
        $reroute_a = $config->{'reroute_condition'}->{"attr"};
	$reroute_b = $config->{'reroute_condition'}->{"attr_value"};
        $do_reroute = 1;	
}

if(defined $config->{'reroute_condition'}->{"replicas"}) {

	$replicas = $config->{'reroute_condition'}->{"replicas"};
}
else {
	$replicas = 1;
}

#### Here we go!
# First print/syslog info about conditions set for script

my $printcond = "configfile: $configfile - ignore_index: " . join(',', @ignore );

if ($do_optimize) {
	$printcond = $printcond . " - optimize indexes based on condition: $optimize_o $optimize_d days";
}
if ($do_reroute) {
	$printcond = $printcond . " - reroute indexes based on condition $reroute_o $reroute_d days, require $reroute_a: $reroute_b";
}

syslog('info',$printcond);
print $printcond if $configtest;

# Get indices/index info from cluster
my $ua = LWP::UserAgent->new(ssl_opts => { verify_hostname => 0 } );
my $req = HTTP::Request->new(GET => "$api_node/_cluster/state");

if (defined $logincredentials) {
	my $login = &get_login($logincredentials);
	($username, $password) = split /:/, $login;	
	$req->authorization_basic($username, $password);
}
my $res = $ua->request($req);
if(! $res->is_success) {
        syslog('err', "ERROR, query for elasticsearch data!");
        print "\n\tERROR getting elasticsearch data!\n";
        exit(1);
}

# start parsing data from ES api call
my $data = JSON->new->utf8->decode($res->content);

#format a date string  for compare
my @date_parts = localtime(time);
my $today = DateTime->new(year => $date_parts[5]+1900, month => $date_parts[4]+1, day => $date_parts[3], time_zone => 'Europe/Stockholm');

# a little variable to make shure I dont repeat myself
my $last = "j0nixRulez";
# array to add any indexes set for optimize
my @optimize = ();
# array to add any indexes set for reroute
my @reroute = ();
# array for reporting deleted indexes
my @deleted =();

# variable for feedback on script result
my $feedback ="\n\tSCRIPT REPORT; ";

# loop trough index/indices information 
#foreach my $index (sort keys %{ $data->{'indices'} }) {
my $ignore_me;
foreach my $index (sort keys %{ $data->{'routing_table'}->{'indices'} }) {

	$ignore_me = 0;
        # Is this a valid index?
        foreach my $m (@ignore) {
        	if ($index =~ qr/^$m.*/) {
			$ignore_me = 1;
                        syslog('info', "$index matches $m from ignore list");
			print "\n\t$index matches $m from ignore list" if $configtest;
		}
        }

	next if $ignore_me == 1;

        if($index =~ m/^(\S+)-([0-9]{4})\.([0-9]{2})\.([0-9]{2})/) {

                # Set variables catching variables from above match
                my $index_name = $1;
                my $ts = DateTime->new(year => $2, month => $3, day => $4, time_zone => 'Europe/Stockholm');
                my $days = $ts->delta_days($today)->{'days'};

                # If index is not defined in configuration file
                if(! defined $config->{'index_lifetime'}->{$index_name}) {

                        print "\n\t$index is not defined i configurationfile $configfile or in the ignore list. $index will be DELETED...\n";
                        syslog('info', "Unknown index $index, Not defined i configurationfile $configfile. $index will be DELETED...");
                        $req = HTTP::Request->new(DELETE => "$api_node/$index");
			$req->authorization_basic($username, $password);
			$ua->request($req) unless $configtest;
                        print "\n\t> > Deleted index $index";
                        syslog('info', "Deleted index $index");
                        push @deleted, $index;
                        next;

                }

                # When we loop trough index we write configrules for index
                if ($last ne $index_name) {
                       $last = $index_name;
			print "\n\tConfiguration defines that we keep $index_name for " . $config->{'index_lifetime'}->{$index_name} . " days";
			syslog('info', "Configuration defines that we keep $index_name for " . $config->{'index_lifetime'}->{$index_name} . " days, evaluation for delete of indexes is done on date reference in index name");
		}

                # Delete that index? Well only if diff with todays date with date reference in index name is greater days defined in configuration file..
                if($config->{'index_lifetime'}->{$index_name} < $days) {

                        $req = HTTP::Request->new(DELETE => "$api_node/$index");
			$req->authorization_basic($username, $password);
			$res = $ua->request($req) unless $configtest;

			if(! $res->is_success) {
				print "\n".$res->content;
			}
			
                        print "\n\tDeleted index $index ($days)";
                        syslog('info', "Deleted index $index ($days)");
                        push @deleted, $index;

                } else {
                        print "\n\tKeeping index $index"; # ...otherwise we keep it... for a while longer
                        syslog('info', "Keeping index $index ($days)");
			# check if we want to optimize...
			if($do_optimize) {
				switch($optimize_o){
                        		case "eq" { if( $days == $optimize_d ) { push @optimize, $index; } }	# equals ..
                        		case "ge" { if( $days >= $optimize_d ) { push @optimize, $index; } }	# greater or equals ..
                        		case "le" { if( $days <= $optimize_d ) { push @optimize, $index; } }	# less or equals ..
                        		case "ne" { if( $days != $optimize_d ) { push @optimize, $index; } }	# not equals ..
                        		case "lt" { if( $days < $optimize_d ) { push @optimize, $index; } }	# less than ..
                        		case "gt" { if( $days > $optimize_d ) { push @optimize, $index; } }	# greater than ..
                        		# default
                        		else {
         					print "\n\tError in switch case, could not match your defined '$optimize_d' with any of the operators eq, ne, gt, ge, lt or le, ignore optimization of index\n";
         					syslog('info', "Error in switch case, could not match your defined '$optimize_d' with any of the operators eq, ne, gt, ge, lt or le, ignore optimization of index");
                        		}
				}
			}

			if($do_reroute) {
				switch($reroute_o){
                        		case "eq" { if( $days == $reroute_d ) { push @reroute, $index; } }	# equals ..
                        		case "ge" { if( $days >= $reroute_d ) { push @reroute, $index; } }	# greater or equals ..
                        		case "le" { if( $days <= $reroute_d ) { push @reroute, $index; } }	# less or equals ..
                        		case "ne" { if( $days != $reroute_d ) { push @reroute, $index; } }	# not equals ..
                        		case "lt" { if( $days < $reroute_d ) { push @reroute, $index; } }	# less than ..
                        		case "gt" { if( $days > $reroute_d ) { push @reroute, $index; } }	# greater than ..
                        		# default
                        		else {
         					print "\n\tError in switch case, could not match your defined '$reroute_d' with any of the operators eq, ne, gt, ge, lt or le, ignore reroute of index\n";
         					syslog('info', "Error in switch case, could not match your defined '$reroute_d' with any of the operators eq, ne, gt, ge, lt or le, ignore reroute of index");
                        		}
				}
			}
                }
		
        } else {
		# Check if we can igore without any action
		# Since i did'nt find any good way to make a regexp 
		# match in an array i loop trough array to match
                my $match = 0;
                foreach my $m (@ignore) {
                        $match = 1 if $index =~ qr/^$m.*/;
                }
                if($match) {
                        print "\n\t$index is defined to ignore\n";
                        syslog('info', "$index is defined in ignore_index ( @ $configfile )");
                        $match = 0;
                } else {
                        print "\n\tALERT - Unexpected index format $index (No action on this index)";
                        syslog('info', "NOTICE - Unexpected index format ($index), need to update ignore_index config?");
		}
        }

}

$feedback .= "\n\n\tDeleted indexes => " . join(';', @deleted) if scalar(@deleted) > 0;

# Identify if any indexes should be optimized by counting if we have anything in our optimize array
if (scalar @optimize > 0 && $do_optimize) {

	# Preventing large http requests we split requests with maximum of 3 index references per optimize request
        my @split_request = ();
        my @request = ();

        foreach my $i (@optimize) {
                push @request, $i;
                if (scalar @request > 2) {
                        push @split_request, join(",",@request);
                        splice(@request);
                }
        }

        if (scalar @request > 0) {
                push @split_request, join(",",@request);
        }

        foreach my $optimize (@split_request) {
                print "\n\tOPTIMIZE \"$optimize\"\n";
                syslog('info', "OPTIMIZE \"$optimize\"");
                $req = HTTP::Request->new(POST => "$api_node/$optimize/_forcemerge?max_num_segments=1");
		$req->authorization_basic($username, $password);
                $ua->request($req) unless $configtest;
        }

	$feedback .= "\n\n\tOptimized Indexes=> " . join(',', @optimize) if scalar(@optimize) > 0;
}


if (scalar @reroute > 0 && $do_reroute) {

        foreach my $r (@reroute) {
                print "REROUTE: $r routing.allocation.require.$reroute_a : $reroute_b\n";
                syslog('info', "REROUTE: $r routing.allocation.require.$reroute_a : $reroute_b");
		my $uri = "$api_node/$r/_settings";
		my $json = '{"index" : { "routing.allocation.require.'.$reroute_a.'" : "'.$reroute_b.'", "number_of_replicas" : '.$replicas.' } }';
		my $req = HTTP::Request->new( 'PUT', $uri );
		$req->header( 'Content-Type' => 'application/json' );
		$req->content( $json );
		$req->authorization_basic($username, $password);
                $ua->request($req) unless $configtest;
        }
	$feedback .= "\n\n\tRerouted Indexes=> " . join(',', @reroute) if scalar(@reroute) > 0;
}
# Feedback on result
print $feedback . "\n\n";
syslog('info', $feedback );
exit 0;
