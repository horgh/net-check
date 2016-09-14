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
					$args->{ pattern }, $args->{ show_response })) {
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
			return &perform_recovery($args->{ command });
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
	if (!Getopt::Std::getopts('hvt:n:p:a:f:w:c:r', \%args)) {
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

	my $host = 'summercat.com';
	if (exists $args{n}) {
		if (defined $args{n} && length $args{n} > 0) {
			$host = $args{n};
		} else {
			&stderr("Invalid hostname.");
			&usage;
			return undef;
		}
	}

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

	my $pattern = 'summercat.png';
	if (exists $args{a}) {
		if (defined $args{a} && length $args{a} > 0) {
			$pattern = $args{a};
		} else {
			&stderr("Invalid pattern.");
			&usage;
			return undef;
		}
	}

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

	my $command = '/sbin/reboot';
	if (exists $args{c}) {
		if (defined $args{c} && length $args{c} > 0) {
			$command = $args{c};
		} else {
			&stderr("Invalid command.");
			&usage;
			return undef;
		}
	}

	my $show_response = 0;
	if (exists $args{r}) {
		$show_response= 1;
	}

	return {
		verbose       => $verbose,
		timeout       => $timeout,
		host          => $host,
		port          => $port,
		pattern       => $pattern,
		failures      => $failures,
		wait_time     => $wait_time,
		command       => $command,
		show_response => $show_response,
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

    [-n <host>]    : Host to connect to.
                     Default is summercat.com.

    [-p <port>]    : Port to connect to. Default port 80.

    [-a <string>]  : String to look for in the response.
                     Default is summercat.png.

    [-f <count>]   : Number of consecutive failures before we take action.
                     Default 6.

    [-c <command>] : Command to run for recovery from failure.
                     Default is /sbin/reboot.

    [-r]           : Show raw response (headers and decoded body).

");
}

sub connected {
	my ($timeout, $host, $port, $pattern, $show_response) = @_;

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
	my $get = "GET / HTTP/1.1\r\nHost: $host\r\nUser-Agent: $USERAGENT\r\nAccept: */*\r\n\r\n";
	if (!&send_with_timeout($select, $timeout, $get)) {
		&stderr("Unable to send GET");
		$sock->shutdown(2);
		return 0;
	}

	# Done writing.
	# CloudFlare's httpd won't respond if we close our write side.
	#if (!$sock->shutdown(1)) {
	#	&stderr("Unable to shutdown socket (write)");
	#	$sock->shutdown(2);
	#	return 0;
	#}

	if ($VERBOSE) {
		&stdout("Receiving...");
	}
	my ($headers, $body) = &recv_with_timeout($select, $timeout);
	$sock->shutdown(2);

	if ($VERBOSE) {
		&stdout("Received body with " . length($body) . " bytes.");
	}

	if ($show_response) {
		&stdout("Header section:");
		foreach my $header (@{ $headers }) {
			# There is CRLF in there already
			&stdout($header);
		}
		&stdout("");
		&stdout("Body");
		&stdout($body);
	}

	if (index($body, $pattern) == -1) {
		&stdout("Pattern not found in the body!");
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

	my @headers;

	my $separator = 0;

	my $chunked = 0;

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
			return undef;
		}

		if (length $buf == 0) {
			if ($VERBOSE) {
				&stdout("EOF");
			}
			return undef;
		}

		$response .= $buf;

		while (!$separator) {
			my $crlf = index $response, "\r\n";

			last if $crlf == -1;

			my $line = substr $response, 0, $crlf, "";
			# Drop CRLF
			substr $response, 0, 2, "";

			if ($line =~ /^transfer-encoding: chunked$/i) {
				if ($VERBOSE) {
					&stdout("Chunked");
				}
				$chunked = 1;
			}

			if (length $line == 0) {
				if ($VERBOSE) {
					&stdout("Found header/body separator");
				}
				$separator = 1;
			} else {
				push @headers, $line;
				if ($VERBOSE) {
					&stdout("Header line: $line");
				}
			}
		}

		if ($separator) {
			if ($chunked) {
				return \@headers, recv_chunked_body($select, $timeout, $response);
			}

			# TODO: Non-chunked
		}
	}

	return undef;
}

sub recv_chunked_body {
	my ($select, $timeout, $response) = @_;

	my $decoded = '';

	my $chunk_size = -1;

	# We don't say that trailers are acceptable, so we don't handle them.

	for (my $i = 0; $i < $timeout; $i++) {
		# We need to figure out a chunk size to get.
		if ($chunk_size == -1) {
			my $crlf = index $response, "\r\n";
			if ($crlf != -1) {
				# I expect no chunk-ext.
				my $chunk_size_hex = substr $response, 0, $crlf, "";
				$chunk_size = hex $chunk_size_hex;

				# Drop the \r\n now too.
				substr $response, 0, 2, "";

				if ($VERBOSE) {
					&stdout("Chunk size: $chunk_size (hex $chunk_size_hex)");
				}

				# Chunk size 0 means we're done.
				if ($chunk_size == 0) {
					# There should be a final CRLF too, but that's okay.
					return $decoded;
				}
			}
		}

		# We know what size chunk we want.
		if ($chunk_size != -1) {
			# Chunk size + 2 to account for CRLF ending chunk-data.
			if (length $response >= $chunk_size+2) {
				$decoded .= substr $response, 0, $chunk_size, "";
				# Drop CRLF
				substr $response, 0, 2, "";
				$chunk_size = -1;
			}

			# Don't read just yet. We have some in the buffer.
			if (length $response > 0) {
				next;
			}
		}

		# Read more.

		my @ready = $select->can_read(1);
		if (!@ready) {
			next;
		}
		my $sock = $ready[0];

		my $buf;
		my $ret = recv $sock, $buf, 1024, 0;
		if (!defined $ret) {
			&stderr("Recv failure");
			return $decoded;
		}

		if (length $buf == 0) {
			if ($VERBOSE) {
				&stdout("EOF");
			}
			return $decoded;
		}

		$response .= $buf;
	}

	return $decoded;
}

sub perform_recovery {
	my ($command) = @_;

	&stdout("Recovering...");
	Sys::Syslog::openlog('net-check', 'ndelay,nofatal,pid', 'user');
	Sys::Syslog::syslog('info', "Recovering...");

	system($command);

	return 1;
}
