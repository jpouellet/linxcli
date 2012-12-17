#!/usr/bin/perl

# Written by Jean-Philippe Ouellet <jpo@vt.edu>
# Provided under the ISC license (http://opensource.org/licenses/ISC)
# See http://linx.li/api.md for the latest linx API.

use strict;
use warnings 'all';

use constant VERSION => 'LinxCLI/1.0';
my %domains = (
	'linxli' => 'https://linx.li',
	'linxbin' => 'https://linxb.in'
	# I could add more, but all current linxapi compliant sites upload
	# to the same "database" anyway, and these are (currently) the only
	# ones that support SSL.
);

use Getopt::Long;
use LWP::UserAgent;
use HTTP::Request;
use File::Slurp;
use File::Basename;
use JSON::Parse qw(valid_json json_to_perl);
use JSON::XS qw(decode_json);

our $linxcli_dir = $ENV{'LINXCLI_DIR'};
unless (defined $linxcli_dir) {
	$linxcli_dir = $ENV{'HOME'};
	if (defined $linxcli_dir) {
		$linxcli_dir .= '/.linxcli';
	}
}

our $domain = ((values %domains)[0]);
our $expires;
our $rand_file;
our $rand_bare;
our $name;
our $mode = 'upload';
our $global_delete_key;

if (index($0, 'rm') != -1 || index($0, 'del') != -1 || index($0, 'un') != -1) {
	$mode = 'delete';
} elsif (index($0, 'info') != -1) {
	$mode = 'info';
}

my $ret = GetOptions(
	# The naming scheme may seem odd and inconsistent, but it was done as
	# is to ensure each option would have a unique first letter (to make
	# their implicit short-version usable).
	'upload' => sub { $mode = 'upload'; },
	'info' => sub { $mode = 'info'; },
	'delete' => sub { $mode = 'delete'; },
	'key=s' => \$global_delete_key,
	'expires=i' => \$expires,
	'name=s' => \$name,
	'randomize' => \$rand_file,
	'barename-randomize' => \$rand_bare,
	'to=s' => sub {
		my($option, $value) = @_;
		if (exists $domains{$value}) {
			$domain = $domains{$value};
		} else {
			warn "\"$value\" is not a valid domain. " .
			     "Valid domains are:\n\t" .
			     join("\n\t",
			          map { "$_\t($domains{$_})" } keys %domains
			     ) . "\n";
			exit -1;
		}
	},
	'api-url=s' => \$domain,
	'version' => sub {
		print VERSION . "\n";
		exit 0;
	},
	'help' => sub { $mode = 'help'; },
);

if ($ret != 1) {
	warn "See --help for proper usage.\n";
	exit -1;
}

if ($mode eq 'help') {
	my $valid_domains = join("\n\t\t",
	    map { "$_\t$domains{$_}" } keys %domains);
	print <<EOF;
Usage: $0 [\x1b[4moptions\x1b[0m] [\x1b[4mfile\x1b[0m \x1b[4m...\x1b[0m]

Options summary:
  --upload
	Uploads all \x1b[4mfile\x1b[0ms. This is usually the default mode,
	depending on the name used to invoke this command. See the notes
	below for more info.
  --info
	Gets info on all \x1b[4mfile\x1b[0ms.
  --delete
	Deletes all \x1b[4mfile\x1b[0ms. The delete keys must be in your
	\${LINXCLI_DIR}/delete_keys. By default, \${LINXCLI_DIR} is
	\${HOME}/.linxcli/. Delete keys are stored in the delete_keys file
	automatically when uploaded with this utility, as long as the
	directory exists. This directory is not created automatically.
  --key \x1b[4mdelete_key\x1b[0m
	In the event that the delete key is not in the delete_keys file,
	but you know it anyway, you can specify it with this option.
	However, you may only delete one file at a time with this method.
  --expires \x1b[4mtime\x1b[0m
  	Specifies the time (in seconds from now) that the file(s) to
  	upload will expire (become unavailable for downloading).
  --name \x1b[4mnew_filename\x1b[0m
	This option may be used to rename files that you are uploading.
	This option may only be used when uploading one file. This is
	especially useful when taking input from stdin instead of a file.
  --randomize
	Randomizes the filename of the file(s) being uploaded.
  --barename-randomize
	Randomizes the filename of the file(s) being uploaded, keeping
	the file extension intact.
  --to \x1b[4mdomain\x1b[0m
	Specifies the site to upload to. This is a shortcut for --api-url.
	The only supported shortcuts at this time are:
		\x1b[4mdomain\x1b[0m\t\x1b[4mapi-url\x1b[0m
		$valid_domains
  --api-url \x1b[4murl\x1b[0m
	Specifies the exact upload URL. See --to for examples.
  --version
	Prints the version and exits.
  --help
	Prints this help page and exits.

Where options are mutually exclusive, the last one prevails. Options given
which have no effect on the current mode (upload/info/delete) are silently
ignored.

All of the above options may also be specified with their short version,
a single dash, followed by the first letter of the long name, for example
--delete can also be specified as -d.

If this command is invoked with "rm", "del", or "un" in its name (e.g. via
a symlink) then the default mode will act as if --delete were specified. If
"info" is in its name, then it will act as if --info were specified.
EOF
	exit 0;
}

our @deletekeys;

sub upload {
	my($data, $filename) = @_;
	if (!defined $data || $data eq '') {
		warn "No data to upload for \"$filename\"\n";
		return -1;
	}

	# build the upload url
	my $url = $domain . '/upload/public';
	$url .= '/' . $filename if defined $filename;

	# make the request
	my $ua = LWP::UserAgent->new;
	my $req = HTTP::Request->new(PUT => $url);
	$ua->agent(VERSION . ' ' . $ua->_agent);
	$req->header('Accept' => 'application/json');

	# let possibly invalid or conflicting headers be handled server-side
	# because their usage may change in the future, and the command
	# line interface should still be able to work with those changes
	# (for example changes in the format of the expiry value, or the
	# effect of setting both randomize-filename and a randomize-barename).
	$req->header('X-Set-Expiry' => $expires) if defined $expires;
	$req->header('X-Randomize-Filename' => 'true') if defined $rand_file;
	$req->header('X-Randomize-Barename' => 'true') if defined $rand_bare;

	$req->content($data);
	my $res = $ua->request($req);

	unless ($res->is_success) {
		warn $res->status_line . "\n";
		return -1;
	}

	unless (valid_json($res->content)) {
		warn "Server returned invalid JSON for file \"$filename\"\n";
		return -1;
	}

	my $json = json_to_perl($res->content);
	print $json->{'url'} . "\n";
	push(@deletekeys, $json->{'filename'} . '/' . $json->{'delete_key'});

	0;
}

sub info {
	my($filename) = @_;
	unless (defined $filename) {
		warn "No filename specified!\n";
		return -1;
	}

	my $url = $domain . '/' . $filename;

	my $ua = LWP::UserAgent->new;
	my $req = HTTP::Request->new(GET => $url);
	$ua->agent(VERSION . ' ' . $ua->_agent);
	$req->header('Accept' => 'application/json');

	my $res = $ua->request($req);

	unless ($res->is_success) {
		warn "$filename: " . $res->status_line . "\n\n";
		return -1;
	}

	unless (valid_json($res->content)) {
		warn "Server returned invalid JSON for file \"$filename\"\n";
		return -1;
	}

	print "$filename\n";
	my $json = decode_json($res->content);
	foreach (keys %$json) {
		print "\t$_: $json->{$_}\n";
	}
	print "\n";

	0;
}

sub rm {
	my($filename, $delete_key) = @_;
	unless (defined $filename) {
		warn "No filename specified!\n";
		return -1;
	}
	unless (defined $delete_key) {
		warn "No delete_key specified for file \"$filename\"\n";
		return -1;
	}

	my $url = $domain . '/' . $filename;

	my $ua = LWP::UserAgent->new;
	my $req = HTTP::Request->new(DELETE => $url);
	$ua->agent(VERSION . ' ' . $ua->_agent);
	$req->header('Accept' => 'application/json');
	$req->header('X-Delete-Key' => $delete_key);

	my $res = $ua->request($req);

	unless ($res->is_success) {
		warn $res->status_line . "\n";
		return -1;
	}

	0;
}

if ($mode eq 'upload') {
	my $failed_count = 0;

	# not using a scalar comparator because passing "" as a file should
	# still read from stdin, and some (old and broken) versions of xargs(1)
	# do that when passed blank lines and/or no input.
	if (@ARGV == 0 || @ARGV eq '') {
		my $data = read_file(\*STDIN, binmode => ':raw',
					    err_mode => 'quiet');
		unless (defined $data) {
			warn "Unable to read data from STDIN: " .
			     "$! (not uploading)\n";
			exit 1;
		}
		if ($data eq '') {
			warn "No data provided! (not uploading)\n";
			exit 1;
		}

		if (upload($data, $name)) {
			exit 1;
		}
	} else {
		if (defined $name && @ARGV > 1) {
			warn "Error: --name can only be used when " .
			     "uploading one file at a time!\n";
			return -1;
		}
		# we were given files, upload them
		foreach (@ARGV) {
			my $data = read_file($_, binmode => ':raw',
						    err_mode => 'quiet');
			unless (defined $data) {
				warn "Unable to read file \"$_\": " .
				     "$! (not uploading)\n";
				$failed_count++;
				next;
			}
			if ($data eq '') {
				warn "\"$_\" is an empty file! " .
				     "(not uploading)\n";
				$failed_count++;
				next;
			}

			if (upload($data, defined $name ? $name : basename($_))) {
				$failed_count++;
				next;
			}
		}
	}

	# write deletion keys to the log if necessary and possible
	if (defined @deletekeys) {
		if (defined $linxcli_dir && -d $linxcli_dir) {
			my $logfile = "$linxcli_dir/delete_keys";
			if (open LOG, '>>', $logfile) {
				print LOG join("\n", @deletekeys) . "\n";
				close LOG;
			}
		} else {
			print "Deletion keys (not logged):\n\t" .
			      join("\n\t", @deletekeys) . "\n";
		}
	}

	exit $failed_count;
} elsif ($mode eq 'info') {
	my $failed_count = 0;

	if (@ARGV eq '') {
		warn "No files specified! See --help for usage.\n";
		exit -1;
	}
	foreach (@ARGV) {
		if (info($_)) {
			$failed_count++;
		}
	}

	exit $failed_count;
} elsif ($mode eq 'delete') {
	my $failed_count = 0;

	if (@ARGV == 0 || @ARGV eq '') {
		warn "No files specified! See --help for usage.\n";
		exit -1;
	}

	if (defined $global_delete_key) {
		if (@ARGV != 1) {
			warn "Error: In deletion mode, --key can only be " .
			     "used to delete one file at a time!\n";
			return -1;
		}
		if (rm($ARGV[0], $global_delete_key)) {
			$failed_count++;
		}

		exit $failed_count;
	}

	unless (open(KEY_FILE, '<', "$linxcli_dir/delete_keys")) {
		warn "Unable to open deletion key file " .
		     "(\"$linxcli_dir/delete_keys\"): $!\n";
		exit -1;
	}
	my @delete_keys = <KEY_FILE>;
	close KEY_FILE;

	foreach (@ARGV) {
		# only try the last deletion key in the file, because
		# it is possible that you uploaded, deleted, and reuploaded
		# a file under the same name using a different delete key.
		my $key = undef;
		my $thisfile = $_;
		foreach (@delete_keys) {
			if ($_ =~ m/^(.*?)\/(.*)$/) {
				$key = $2 if $1 eq $thisfile;
			}
		}
		if (defined $key) {
			if (rm($thisfile, $key)) {
				$failed_count++;
			}
		}

		# all deletion keys are kept in the file indefinitely,
		# and it is never purged by this utility. This is in case
		# the server side messes up and reports success when
		# the file wasn't really deleted, we still want to have the
		# deletion key to go back and do it manually.
	}

	exit $failed_count;
} else {
	warn "Invalid mode! Valid modes are:\n * upload\n * info\n * delete\n";
	exit -1;
}
