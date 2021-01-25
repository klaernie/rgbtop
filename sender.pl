#!/usr/bin/perl
use strict;
use warnings;
use Data::Dumper;
use IO::Socket::INET;
use List::Util qw( reduce );
use Time::HiRes qw( sleep );
use JSON;


sub debug (&){
	return unless -t 1;
	&{shift()}();
}

sub nsort {
	return sort { $a <=> $b } @_;
}

sub read_cpu_values {
	# example of /proc/stat output:
	# cpu  11671369 2624854 4240042 522615023 749463 0 106322 0 0
	# cpu0 912271 196760 448981 43498432 48916 0 15071 0 0 0
	# cpu1 983382 211573 349883 43570338 46426 0 12139 0 0 0
	# cpu2 1024727 177972 356184 43431210 118625 0 25571 0 0 0
	# cpu3 1027334 169075 343289 43567906 63214 0 6955 0 0 0
	# cpu4 1040398 160075 333548 43576621 50715 0 6428 0 0 0
	# cpu5 983378 169756 330873 43626989 47862 0 10733 0 0 0
	# cpu6 1157806 311016 354362 43271571 60819 0 6230 0 0 0
	# cpu7 1007316 248704 350763 43497916 60090 0 6141 0 0 0
	# cpu8 919467 222392 346331 43608589 62273 0 6816 0 0 0
	# cpu9 894456 251040 345109 43624762 63594 0 3390 0 0 0
	# cpu10 855022 253740 337669 43678194 62969 0 3502 0 0 0
	# cpu11 865807 252745 343045 43662490 63954 0 3341 0 0 0
	# intr 815203445 15 0 0 0 2 0 0 0 1 1 0 0 0 0 0 0 0 0 0 0 2601
	# ...
	
	# cpu line is:
	# ID user nice system idle iowait softirq steal guest guest_nice
	my %cpu_stats;
	open( my $fh, "<", "/proc/stat" ) or die "failed to open /proc/stat: $!";
	while( my $line = readline $fh ){
		next unless $line =~ m/
			^
			cpu(\d+)
			\s+
			(?<user>\d+)
			\s+
			(?<nice>\d+)
			\s+
			(?<system>\d+)
			\s+
			(?<idle>\d+)
			\s+
			(?<irq>\d+)
			\s+
			(?<softirq>\d+)
			\s+
			(?<steal>\d+)
			\s+
			(?<guest>\d+)
			\s+
			(?<guest_nice>\d+)
			/x;

		my $cpu = $1;

		foreach(keys %+){
			$cpu_stats{$cpu}{total} += $+{$_};
			next if $_ eq "guest";
			next if $_ eq "guest_nice";
			next if $_ eq "steal";
			next if $_ eq "irq";
			next if $_ eq "softirq";
			$cpu_stats{$cpu}{stat}{$_} = $+{$_};
		}
	}
	return %cpu_stats;
}

sub nonzero_sub {
	my $a = shift;
	my $b = shift;
	my $t = $a - $b;
	return 0 if $t < 0;
	return $t;
}

sub compute_current (\%\%){
	my %old = %{ shift() };
	my %new = %{ shift() };

	my %biggest_hog;
	foreach my $cpu (nsort keys %new){
		my $total = nonzero_sub( $new{$cpu}{total}, $old{$cpu}{total});
		my %values;
		foreach my $field ( keys %{$new{$cpu}{stat}} ){
			$values{$field} = nonzero_sub( $new{$cpu}{stat}{$field}, $old{$cpu}{stat}{$field});
		}

		$biggest_hog{$cpu} = reduce { $values{$a} > $values{$b} ? $a : $b } keys %values;

		foreach my $field ( keys %values ){
			$values{$field} = int ($values{$field} / $total * 100);
		}

		debug {
			print "$cpu: $biggest_hog{$cpu}\n";
			print "\t$_ => $values{$_}" foreach sort keys %values;
			print "\n";
		};
	}

	return %biggest_hog;
}

my %state2color = (
	idle   => [255,0,255],
	nice   => [0,0,255],
	system => [255,0,0],
	user   => [0,255,0],
);
sub colormap_cores (\%){
	my %coredata = %{ shift() };

	return
		map { $_ => $state2color{$coredata{$_}} }
		grep {defined $state2color{$coredata{$_}}}
		keys %coredata;
}

open( my $fh, "-|", "lscpu -p" ) or die "failed to run lscpu -p: $!";
my @lscpu_header;
my %socket_of;
my %led_of_socket_of;
my %led_counter;
while( $_ = readline $fh ){
	if( m/^# / && m/Socket/ && m/CPU/ ){
		if( m/^# (.*)$/ ){
			@lscpu_header = split /,/, $1;
		}
	}
	next if m/^#/;
	next unless @lscpu_header;

	my %details;
	@details{ @lscpu_header } = split /,/, $_;

	$socket_of{ $details{CPU} } = $details{Socket}; # +1: in mqtt it's cpu1 and cpu2, not cpu0 and cpu1
	$led_of_socket_of{$details{Socket}}{ $details{CPU} } = $led_counter{ $details{Socket} }++;
}
close $fh;

debug {
	print "Core->CPU:\n";
	print "$_ => socket $socket_of{$_}\n" foreach nsort keys %socket_of;
};

my %led_of;
my $led_counter = 0;
foreach my $socket ( nsort keys %led_of_socket_of ){
	if( $socket > 0  && $led_counter < 12 ){
		# match this to the physical layout
		$led_counter = 12;
	}
	foreach my $cpu (nsort keys %{$led_of_socket_of{$socket}}){
		$led_of{ $cpu } = $led_counter++;
	}
}

debug {
	print "Core->LED\n";
	print "$_ => $led_of{$_}\n" foreach nsort keys %led_of;
};
	
debug {
	sleep 5;
};

my $clearscreen = qx{ clear };

my $sock = new IO::Socket::INET(
	PeerAddr => 'rgbcontroller_prototype.ak-online.be',
	PeerPort => 21324,
	Proto => 'udp',
	Timeout => 1
) or die('Error opening socket.');

my %state_old = read_cpu_values();
while(1){
	sleep .2;
	debug { print $clearscreen };

	my %state_new = read_cpu_values();
	
	my %hogs = compute_current( %state_old, %state_new );

	debug {
		print "resulting state:\n";
		print( "$_ => $hogs{$_}\n") foreach nsort keys %hogs;
	};

	debug { print "colors choosen:\n" };
	my %colors = colormap_cores %hogs;

	debug {
		print( "$_ => ".(join ",", @{ $colors{$_} })."\n") foreach nsort keys %colors;
	};


	my @sendqueue = ( "\x01", "\xFF" );
	foreach my $cpu (nsort keys %colors){
		my $led = $led_of{$cpu};

		my @items = (
			chr($led),
			map { chr $_ } @{ $colors{ $cpu } }
		);

		debug {
			print "planning to set led $led to ".(join ",", @{ $colors{$cpu} })."[ ".join(" ", map{ sprintf "%02X", ord($_) } @items)." ]\n";
		};
		
		push @sendqueue, @items ;
	}

	debug{
		print "sending to socket: ".join(" ", map{ sprintf "%02X", ord($_) } @sendqueue)."\n";
	};
	print $sock join '', @sendqueue;

	%state_old = %state_new;
}



