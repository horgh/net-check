#
# Purpose:
# I have a few Raspberry Pi servers that periodically lose their connection for
# one reason or another. To get them to come back is currently a manual
# operation. I want this program to monitor for that happening, and then do
# something. Probably simply reboot the server.
#
# What I do is repeatedly make an HTTP request. I check that there is a response
# I expect. If not, I increment a failure counter. If we hit a certain number of
# failures before a success, then I try to recover connectivity.
#

use strict;
use warnings;

use Getopt::Std qw//;
use IO::Select qw//;
use IO::Socket::INET qw//;
use Sys::Syslog qw//;

my $VERBOSE = 0;
my $USERAGENT = "github.com/horgh/net-check";

$| = 1;

exit(&main ? 0 : 1);

sub main {
	if ($> != 0) {
		&stderr("You must run this program as root.");
		return 0;
	}

	my $args = &get_args;
	if (!$args) {
		return 0;
	}

	$VERBOSE = $args->{verbose};

	my $consecutive_failures = 0;

	while (1) {
		if (&connected($args->{ timeout }, $args->{ host }, $args->{ port },
					$args->{ pattern })) {
			if ($VERBOSE) {
				&stdout("Connected");
			}
			$consecutive_failures = 0;

			sleep $args->{ wait_time };
			next;
		}

		if ($VERBOSE) {
			&stdout("Not connected");
		}

		$consecutive_failures++;

		if ($consecutive_failures >= $args->{ failures }) {
			&stderr("Failure threshold hit!");
			return &perform_recovery;
		}

		sleep $args->{ wait_time };
	}
}

sub stderr {
	my ($msg) = @_;
	print { \*STDERR } "$msg\n";
}

sub stdout {
	my ($msg) = @_;
	print "$msg\n";
}

sub get_args {
	my %args;
	if (!Getopt::Std::getopts('hvt:n:p:a:f:w:', \%args)) {
		&usage;
		return undef;
	}

	if (exists $args{h}) {
		&usage;
		return undef;
	}

	my $verbose = 0;
	if (exists $args{v}) {
		$verbose = 1;
	}

	my $timeout = 60;
	if (exists $args{t}) {
		if (defined $args{t} && length $args{t} > 0 && $args{t} =~ /^[0-9]+$/) {
			$timeout = $args{t};
		} else {
			&stderr("Invalid timeout value.");
			&usage;
			return undef;
		}
	}

	my $host;
	if (!exists $args{n} || !defined $args{n} || length $args{n} == 0) {
		&stderr("You must provide a hostname.");
		&usage;
		return undef;
	}
	$host = $args{n};

	my $port = 80;
	if (exists $args{p}) {
		if (defined $args{p} && length $args{p} > 0 && $args{p} =~ /^[0-9]+$/) {
			$port = $args{p};
		} else {
			&stderr("Invalid port.");
			&usage;
			return undef;
		}
	}

	my $pattern;
	if (!exists $args{a} || !defined $args{a} || length $args{a} == 0) {
		&stderr("You must provide a string to look for.");
		&usage;
		return undef;
	}
	$pattern = $args{a};

	my $failures = 6;
	if (exists $args{f}) {
		if (defined $args{f} && length $args{f} > 0 && $args{f} =~ /^[0-9]+$/) {
			$failures = $args{f};
		} else {
			&stderr("Invalid failures value.");
			&usage;
			return undef;
		}
	}

	my $wait_time = 600;
	if (exists $args{w}) {
		if (defined $args{w} && length $args{w} > 0 && $args{w} =~ /^[0-9]+$/) {
			$wait_time = $args{w};
		} else {
			&stderr("Invalid wait time value.");
			&usage;
			return undef;
		}
	}

	return {
		verbose   => $verbose,
		timeout   => $timeout,
		host      => $host,
		port      => $port,
		pattern   => $pattern,
		failures  => $failures,
		wait_time => $wait_time,
	};
}

sub usage {
	&stdout("Usage: $0 <arguments>

Arguments:

    [-h]           : Show this usage.

    [-v]           : Enable verbose output.

    [-t <seconds>] : Timeout in seconds for connect/receive/send.
                     Default 60.

    [-w <seconds>] : Wait time in seconds between checks.
                     Default 600.

    -n <host>      : Host to connect to.

    [-p <port>]    : Port to connect to. Default port 80.

    -a <string>    : String to look for in the response.

    [-f <count>]   : Number of consecutive failures before we take action.
                     Default 6.
");
}

sub connected {
	my ($timeout, $host, $port, $pattern) = @_;

	# I could use LWP here but I've had issues with its reliability and timeout
	# behaviour in the past.

	if ($VERBOSE) {
		&stdout("Connecting to $host:$port...");
	}
	my $sock = IO::Socket::INET->new(
		PeerHost => $host,
		PeerPort => $port,
		Proto    => 'tcp',
		Timeout  => $timeout,
		Blocking => 0,
	);
	if (!$sock) {
		&stderr("Unable to open socket: $@");
		return 0;
	}

	my $select = IO::Select->new($sock);

	if ($VERBOSE) {
		&stdout("Sending GET...");
	}
	my $get = "GET / HTTP/1.1\r\nHost: $host\r\nUser-Agent: $USERAGENT\r\n\r\n";
	if (!&send_with_timeout($select, $timeout, $get)) {
		&stderr("Unable to send GET");
		$sock->shutdown(2);
		return 0;
	}

	# Done writing.
	if (!$sock->shutdown(1)) {
		&stderr("Unable to shutdown socket (write)");
		$sock->shutdown(2);
		return 0;
	}

	if ($VERBOSE) {
		&stdout("Receiving...");
	}
	my $buf = &recv_with_timeout($select, $timeout);
	$sock->shutdown(2);

	if ($VERBOSE) {
		&stdout("Received " . length($buf) . " bytes.");
	}

	if (index($buf, $pattern) == -1) {
		return 0;
	}

	return 1;
}

sub send_with_timeout {
	my ($select, $timeout, $msg) = @_;

	my $sent = 0;

	for (my $i = 0; $i < $timeout; $i++) {
		my @ready = $select->can_write(1);
		if (!@ready) {
			next;
		}
		my $sock = $ready[0];

		my $sz = send $sock, substr($msg, $sent), 0;
		if (!defined $sz) {
			&stderr("Send failure");
			return 0;
		}

		$sent += $sz;

		if ($sent == length $msg) {
			return 1;
		}
	}

	&stderr("Timed out. Sent $sent bytes.");
	return 0;
}

sub recv_with_timeout {
	my ($select, $timeout) = @_;

	my $response = '';

	for (my $i = 0; $i < $timeout; $i++) {
		my @ready = $select->can_read(1);
		if (!@ready) {
			next;
		}
		my $sock = $ready[0];

		my $buf;
		my $ret = recv $sock, $buf, 1024, 0;
		if (!defined $ret) {
			&stderr("Recv failure");
			return $response;
		}

		if (length $buf == 0) {
			if ($VERBOSE) {
				&stdout("EOF");
			}
			return $response;
		}

		$response .= $buf;
	}

	return $response;
}

sub perform_recovery {
	&stdout("Recovering...");
	Sys::Syslog::openlog('net-check', 'ndelay,nofatal,pid', 'user');
	Sys::Syslog::syslog('info', "Recovering...");

	system('/sbin/reboot');
	return 1;
}
