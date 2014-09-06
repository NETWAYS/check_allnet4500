#!/usr/bin/perl -w
# $Id: 736afff95e253efdecd75ad35137c114421595f5 $

$PROGNAME = basename($0);
$VERSION = '1.0';

{
	package TresholdFactory;
	
	use strict;
	use Carp qw(croak);

	our %fn;
    our $re_float       = '^[+-]?\d*\.?\d+$';
    our $re_infinity    = '^~$';
    our $re_range       = '^@(.*)';
	
	sub new {
		my $class = shift;
		
		bless({}, $class);
	}
	
	sub get_validator {
		my $self   = shift;
	    my $range  = shift;
	    
	    	if($_ = $fn{$range}) {
	    		return $_;
	    	}
	    	
	        my ($start, $end) = split(/:/, $range);
	        my ($ll, $ul);
	        my $mode = 'd';
	        
	        if ($start =~ m/$re_float/ && !defined $end) {
	        	$ll = 0;
	        	$ul = $start;
	        } elsif ($start =~ m/$re_float/ && (!$end || $end =~ m/$re_infinity/)) {
	        	$ll = $start;
	        	$ul = "+Inf";
	        } elsif ((!$start || $start =~ m/$re_infinity/) && $end =~ m/$re_float/) {
	        	$ll = "-Inf";
	        	$ul = $end;
	        } elsif ($start =~ m/$re_float/ && $end =~ m/$re_float/) {
	        	$ll = $start;
	        	$ul = $end;
	        } elsif ($start =~ m/$re_range/ && ($start = $1) && $start =~ m/$re_float/  && $end =~ m/$re_float/) {
	        	$mode = 'r';
                $ll = $start;
                $ul = $end;
            }

	        if(!defined $ll || !defined $ul || $ll > $ul) {
	        	croak "Unexpected format.";
	        }
	        
	        if($mode eq 'd') {
	            $fn{$range} = $_ = sub {
	            	my($v, $if, $default) = @_;
	            	if ($v < $ll || $v > $ul) {
	            		return $if;
	            	}
	            	return $default;
	            };
	            return $_;
	        } else {
                $fn{$range} = $_ = sub {
                    my($v, $if, $default) = @_;
                    if ($v >= $ll && $v <= $ul) {
                        return $if;
                    }
                    return $default;
                };
                return $_;	        	
	        }     
	}
	
	1;
}

{
    package AuthAgent;
    
    use strict;
    require LWP::UserAgent;
    
    our @ISA = qw(LWP::UserAgent);

    sub new {
    	my($class, %cnf) = @_;
    	
    	my $user       = delete($cnf{user});
    	my $password   = delete($cnf{password});
    	
    	my $self           = $class->SUPER::new(%cnf);
    	$self->{user}      = $user;
    	$self->{password}  = $password;
    	
    	bless($self, $class);
    }

    sub get_basic_credentials {
        my($self, $realm, $uri) = @_;
        return ($self->{user}, $self->{password});
    }
    
    1;
}

use strict;
use Carp qw(croak);
use File::Basename;
use Getopt::Long;
require XML::Simple;
use Pod::Usage;

use subs qw(help);

use vars qw (
    $PROGNAME
    $VERSION
    
    %states
    %state_names
    %function_map
    
    $opt_protocol
    $opt_host
    $opt_port
    $opt_user
    $opt_password
    $opt_path
    $opt_agent
    $opt_timeout
    $opt_legend
    $opt_warning
    $opt_critical
    
    $opt_help
    $opt_man
    $opt_verbose
    $opt_version
    
    $re_float
    $re_infinity
    $re_range

    $url
    $ua
    $res
    $xs
    $ref
    $tf
    @sensors
    $status
    %sensors
);

%states = (
    OK      => 0,
    WARNING => 1,
    CRITICAL=> 2,
    UNKNOWN => 3
);

%state_names = (
    0 => 'OK',
    1 => 'WARNING',
    2 => 'CRITICAL',
    3 => 'UNKNOWN'
);

# NOT COMPLETE!
%function_map = (
    1 => {
        type    => "Temperature",
        unit    => "C"
    },
    2 => {
        type    => "Humidity",
        unit    => "%"
    }
);


$opt_protocol   = 'http';
$opt_port       = 80;
$opt_path       = '/xml/sensordata.xml';
$opt_agent      = sprintf('%s/%s with LWP/%s', $PROGNAME, $VERSION, $LWP::VERSION);
$opt_timeout    = 10;
$opt_legend     = 'Sensors';

$status         = $states{OK};


Getopt::Long::Configure('bundling');
GetOptions(
    'h|help'    => \$opt_help,
    'man'       => \$opt_man,
    'H=s'       => \$opt_host,
    'p=i'       => \$opt_port,
    'path=s'    => \$opt_path,
    'U=s'       => \$opt_user,
    'P=s'       => \$opt_password,
    'a=s'       => \$opt_agent,
    't=i'       => \$opt_timeout,
    'l=s'       => \$opt_legend,
    'w=s'       => \$opt_warning,
    'c=s'       => \$opt_critical,
    'V|version' => \$opt_version
) || help(1, 'Please check your options!');

help( 1) if $opt_help;
help(99) if $opt_man;
help(-1) if $opt_version;
help( 1, 'Host not specified! Please check your options.') unless ($opt_host);

$url = sprintf('%s://%s:%u/%s', $opt_protocol, $opt_host, $opt_port, $opt_path);

$ua = AuthAgent->new(
    agent   => $opt_agent,
    timeout => $opt_timeout,
    user    => $opt_user,
    password=> $opt_password
);

$res = $ua->get($url);
if (!$res->is_success) {
	croak $res->status_line;
}

$xs = XML::Simple->new();

$ref = $xs->XMLin($res->content);

$tf = TresholdFactory->new();

while ( my ($key, $struct) = each(%{$ref}) ) {
	if ($key !~ m/sensor/) {
		next;
	}
	
	my $v          =   $struct->{value_float};
	my $warn       =   $opt_warning || $struct->{limit_low};
	my $crit       =   $opt_critical || $struct->{limit_high};
	my $status_    =   $tf->get_validator($crit)->($v, 2, 0)
	                   || $tf->get_validator($warn)->($v, 1, 0)
	                   || $states{OK};
	                   
	$status        =   $status_ if $status_ > $status;
	
	push(@sensors, {
		name      =>  $struct->{name},
		raw       =>  $v,
		warn      =>  $warn,
		crit      =>  $crit,
		min       =>  $struct->{minimum},
		max       =>  $struct->{maximum},
		status    =>  $status_,
		type      =>  $function_map{$struct->{function}}{type} || 'Unsopperted (Plugin)',
		uom       =>  $function_map{$struct->{function}}{unit} || ''
	});
}

foreach (@sensors) {
	if (!$sensors{$_->{status}}) {
		$sensors{$_->{status}} = ();
	}
	push(@{$sensors{$_->{status}}}, $_);
}

printf("%s %s - %i sensors checked: %s|%s\n%s", $opt_legend, $state_names{$status}, scalar(@sensors),
    (sub {
    	my $out;
    	
    	foreach(sort(keys(%sensors))) {
    		$out .= ', ' if $out;
    		$out .= sprintf('%i %s', scalar(@{$sensors{$_}}), $state_names{$_});
    		if ($_ ne $states{OK}) {
    			$out .= sprintf(' (%s)', join(', ', map(sprintf('%s=%s%s', $_->{name}, $_->{raw}, $_->{uom}), @{$sensors{$_}})));
    		}
    	}
    	
    	return $out;
    })->(),
    join(' ', map(sprintf("'%s'=%s%s;%s;%s;%s;%s", $_->{name}, $_->{raw}, $_->{uom}, $_->{warn}, $_->{crit}, $_->{min}, $_->{max}), @sensors)),
    join("\n", map(sprintf('%s %s: %s%s', $state_names{$_->{status}}, $_->{name}, $_->{raw}, $_->{uom}), @sensors))
);
exit $status;

sub help {
    my ($level, $msg) = @_;
    $level = 0 unless ($level);
    if ($level == -1) {
        print "$PROGNAME - Version: $VERSION\n";
        exit $states{'UNKNOWN'};
    }
    pod2usage({
        -message => $msg,
        -verbose => $level
    });
    exit $states{'UNKNOWN'};
}

1;

__END__

=pod

=head1 COPYRIGHT

 
This software is Copyright (c)  2011 NETWAYS GmbH, Eric Lippmann
                                <support@netways.de>

(Except where explicitly superseded by other copyright notices)

=head1 LICENSE

This work is made available to you under the terms of Version 2 of
the GNU General Public License. A copy of that license should have
been provided with this software, but in any event can be snarfed
from http://www.fsf.org.

This work is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
02110-1301 or visit their web page on the internet at
http://www.fsf.org.


CONTRIBUTION SUBMISSION POLICY:

(The following paragraph is not intended to limit the rights granted
to you to modify and distribute this software under the terms of
the GNU General Public License and is only of importance to you if
you choose to contribute your changes and enhancements to the
community by submitting them to NETWAYS GmbH.)

By intentionally submitting any modifications, corrections or
derivatives to this work, or any other work intended for use with
this Software, to NETWAYS GmbH, you confirm that
you are the copyright holder for those contributions and you grant
NETWAYS GmbH a nonexclusive, worldwide, irrevocable,
royalty-free, perpetual, license to use, copy, create derivative
works based on those contributions, and sublicense and distribute
those contributions and any derivatives thereof.

Nagios and the Nagios logo are registered trademarks of Ethan Galstad.

=head1 NAME

check_allnet4500 - Icinga/Nagios plugin to query ALLNET ALL4500 sensors via HTTP/XML

=head1 SYNOPSIS

check_allnet4500.pl -h|--help

check_allnet4500.pl --man

check_allnet4500.pl -V|--version

check_allnet4500.pl -H hostname|hostaddress [-p port] [--path path]
                    [-a agent] [-t timeout]
                    [-U user] [-P password]
                    [-l legend]
                    [-w warning] [-c critical]

=head1 OPTIONS

=over 8

=item   B<-H>

Hostname or hostaddress

=item   B<-p>

Port, defaults to B<80>

=item   B<--path>

Path, defaults to B<"/xml/sensordata.xml">

=item   B<-a>

User agent

=item   B<-t>

Timeout, defaults to B<10>

=item   B<-U>

Username for basic or digest auth

=item   B<-P>

Password for basic or digest auth

=item   B<-l>

Legend a.k.a plugin/service name, defaults to B<"Sensors">

=item   B<-w>

Warning treshold, defaults to the configured one

=item   B<-c>

Critical treshold, defaults to the configured one

=back

=cut