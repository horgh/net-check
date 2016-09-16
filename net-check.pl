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
use IO::Socket::SSL qw//;
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
					$args->{ pattern }, $args->{ show_response }, $args->{ tls })) {
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
	if (!Getopt::Std::getopts('hvt:n:p:a:f:w:c:rs', \%args)) {
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

	my $host = 'www.summercat.com';
	if (exists $args{n}) {
		if (defined $args{n} && length $args{n} > 0) {
			$host = $args{n};
		} else {
			&stderr("Invalid hostname.");
			&usage;
			return undef;
		}
	}

	my $tls = 0;
	if (exists $args{s}) {
		$tls = 1;
	}

	my $port = 80;
	$port = 443 if $tls;
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
		$show_response = 1;
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
		tls           => $tls,
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
                     Default is www.summercat.com.

    [-p <port>]    : Port to connect to. Default port 80 without TLS, or 443
                     with TLS.

    [-a <string>]  : String to look for in the response.
                     Default is summercat.png.

    [-f <count>]   : Number of consecutive failures before we take action.
                     Default 6.

    [-c <command>] : Command to run for recovery from failure.
                     Default is /sbin/reboot.

    [-r]           : Show raw response (headers and decoded body).

    [-s]           : Connect with TLS.

");
}

sub connected {
	my ($timeout, $host, $port, $pattern, $show_response, $tls) = @_;

	# I could use LWP here but I've had issues with its reliability and timeout
	# behaviour in the past.

	if ($VERBOSE) {
		&stdout("Connecting to $host:$port...");
	}

	my $sock;

	if (!$tls) {
		$sock = IO::Socket::INET->new(
			PeerHost => $host,
			PeerPort => $port,
			Proto    => 'tcp',
			Timeout  => $timeout,
			Blocking => 0,
		);
	} else {
		$sock = IO::Socket::SSL->new(
			PeerHost    => $host,
			PeerPort    => $port,
			Timeout     => $timeout,
			Blocking    => 0,
			# TLS 1.2 only.
			SSL_version => '!SSLv2:!SSLv3:!TLSv1:!TLSv1_1:TLSv1_2',
		);
	}
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

	if ($VERBOSE) {
		&stdout("Receiving...");
	}
	my ($headers, $body) = &read_response($select, $timeout, $tls);
	$sock->shutdown(2);

	if (!$headers) {
		&stderr("Problem receiving response.");
		return 0;
	}

	if ($VERBOSE) {
		&stdout("Received body with " . length($body) . " bytes.");
	}

	if ($show_response) {
		&stdout("Header section:");
		foreach my $header (@{ $headers }) {
			&stdout($header);
		}
		&stdout("");
		&stdout("Body section:");
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

		my $left = length($msg)-$sent;
		my $sz = syswrite $sock, $msg, $left, $sent;
		if (!defined $sz) {
			&stderr("syswrite failure: $!");
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

sub read_response {
	my ($select, $timeout, $tls) = @_;

	my ($headers, $buffer) = &read_headers($select, $timeout, $tls);
	if (!$headers) {
		&stderr("Unable to read headers");
		return undef;
	}

	# Pull out some interesting headers.
	# How to receive/decode the body depends on Transfer-Encoding.
	# If no Transfer-Encoding, we use Content-Length to know how large the body is.
	my $chunked_encoding = 0;
	my $content_length = -1;
	foreach my $header (@{ $headers }) {
		if ($header =~ /^transfer-encoding: chunked$/i) {
			$chunked_encoding = 1;
		}
		if ($header =~ /^content-length: (\d+)$/i) {
			$content_length = $1;
		}
	}

	my $body;
	if ($chunked_encoding) {
		$body = &read_chunked_body($select, $timeout, $buffer, $tls);
	} else {
		# Assume non-chunked. Use Content-Length.
		$body = &read_non_chunked_body($select, $timeout, $buffer, $content_length,
			$tls);
	}

	if (!defined $body) {
		&stderr("Unable to read body");
		return undef;
	}

	return $headers, $body;
}

sub read_headers {
	my ($select, $timeout, $tls) = @_;

	my $buf = '';
	my @headers;

	my @handles = $select->handles;
	my $sock = $handles[0];

	for (my $i = 0; $i < $timeout; $i++) {
		# IO::Socket::SSL says we should not wait on socket reporting read ready.
		# We should check if there is pending data first.
		if (!$tls || !$sock->pending) {
			my @ready = $select->can_read(1);
			if (!@ready) {
				next;
			}
		}

		my $recv_buf;
		my $sz = sysread $sock, $recv_buf, 1024;
		if (!defined $sz) {
			&stderr("sysread failure: $!");
			return undef;
		}

		if ($sz == 0) {
			&stderr("EOF.");
			return undef;
		}

		$buf .= $recv_buf;

		# Pull out all the headers we have received.

		while (1) {
			my $crlf = index $buf, "\r\n";
			last if $crlf == -1;

			my $line = substr $buf, 0, $crlf, "";
			# Drop CRLF
			substr $buf, 0, 2, "";

			if (length $line == 0) {
				return \@headers, $buf;
			}

			push @headers, $line;
		}
	}

	&stderr("Timed out reading headers.");
	return undef;
}

# $buf is a buffer which contains data read from the connection but not yet
# processed.
#
# We don't say that trailers are acceptable in our request, so we don't handle
# them.
# I also don't handle any chunk-ext.
sub read_chunked_body {
	my ($select, $timeout, $buf, $tls) = @_;

	my @handles = $select->handles;
	my $sock = $handles[0];

	my $decoded_body = '';
	my $chunk_size = -1;

	for (my $i = 0; $i < $timeout; $i++) {
		# If we don't know a chunk size, then we're looking for the start of a
		# chunk. We need to figure out a chunk size to get.
		if ($chunk_size == -1) {
			my $crlf = index $buf, "\r\n";
			if ($crlf != -1) {
				my $chunk_size_hex = substr $buf, 0, $crlf, "";
				# Drop the CRLF.
				substr $buf, 0, 2, "";

				if (length $chunk_size_hex > 0) {
					$chunk_size = hex $chunk_size_hex;
				}

				# Chunk size 0 means we're done.
				if ($chunk_size == 0) {
					# There should be a final CRLF too, but that's okay.
					return $decoded_body;
				}
			}
		}

		# We know what size chunk we want. Pull out the chunk once we have enough
		# data.
		if ($chunk_size != -1) {
			# Chunk size + 2 to account for CRLF ending chunk-data.
			if (length $buf >= $chunk_size+2) {
				$decoded_body .= substr $buf, 0, $chunk_size, "";
				# Drop CRLF
				substr $buf, 0, 2, "";

				# Indicate we need a new chunk size.
				$chunk_size = -1;

				# Don't read again just yet. We have some in the buffer.
				if (length $buf > 0) {
					next;
				}
			}
		}

		# Read more.

		if (!$tls || !$sock->pending) {
			my @ready = $select->can_read(1);
			if (!@ready) {
				next;
			}
		}

		my $recv_buf;
		my $sz = sysread $sock, $recv_buf, 1024, 0;
		if (!defined $sz) {
			&stderr("sysread failure: $!");
			return undef;
		}

		if ($sz == 0) {
			&stderr("EOF");
			return undef;
		}

		$buf .= $recv_buf;
	}

	&stderr("Timed out reading chunked body.");
	return undef;
}

sub read_non_chunked_body {
	my ($select, $timeout, $buf, $content_length, $tls) = @_;

	# We need to know how large the body is.
	# While it is not required per RFC, I'm going to require Content-Length.
	if ($content_length <= 0) {
		&stderr("No Content-Length available.");
		return undef;
	}

	my @handles = $select->handles;
	my $sock = $handles[0];

	for (my $i = 0; $i < $timeout; $i++) {
		if (length $buf >= $content_length) {
			my $body = substr $buf, 0, $content_length;
			return $body;
		}

		if (!$tls || !$sock->pending) {
			my @ready = $select->can_read(1);
			if (!@ready) {
				next;
			}
		}

		my $recv_buf;
		my $sz = sysread $sock, $recv_buf, 1024, 0;
		if (!defined $sz) {
			&stderr("sysread failure: $!");
			return undef;
		}

		if ($sz == 0) {
			&stderr("EOF");
			return undef;
		}

		$buf .= $recv_buf;
	}

	&stderr("Timed out reading non-chunked body.");
	return undef;
}

sub perform_recovery {
	my ($command) = @_;

	&stdout("Recovering...");
	Sys::Syslog::openlog('net-check', 'ndelay,nofatal,pid', 'user');
	Sys::Syslog::syslog('info', "Recovering...");

	system($command);

	return 1;
}
