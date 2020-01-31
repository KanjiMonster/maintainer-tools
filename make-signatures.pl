#!/usr/bin/env perl

use strict;
use warnings;
use locale;

use POSIX qw(mktime strftime setlocale LC_COLLATE);

setlocale(LC_COLLATE, "en_US.UTF-8");

my $page = 'https://openwrt.org/docs/guide-user/security/signatures';

my @keytypes = (
	undef,
	'RSA',
	'RSA, encrypt only',
	'RSA, sign only',
	undef,
	undef,
	undef,
	undef,
	undef,
	undef,
	undef,
	undef,
	undef,
	undef,
	undef,
	undef,
	'Elgamal, encrypt only',
	'DSA',
	'EC',
	'ECDSA',
	'Elgamal'
);

sub format_title {
	my ($key) = @_;

	if ($key->{is_system_key}) {
		return $key->{comment};
	}

	return sprintf 'Public key of %s', $key->{name};
}

sub format_keytype {
	my ($key, $is_subkey) = @_;

	my $type = $key->{$is_subkey ? 'stype' : 'type'};
	my $size = $key->{$is_subkey ? 'ssize' : 'size'};

	my ($d, $m, $y, $s);

	if (defined($size) && $size > 0) {
		$s = sprintf '%d Bit %s', $size, $keytypes[$type];
	}
	else {
		$s = $keytypes[$type];
	}

	(undef, undef, undef, $d, $m, $y) =
		localtime $key->{$is_subkey ? 'sctime' : 'ctime'};

	$s .= sprintf ', created %04d-%02d-%02d', $y + 1900, $m + 1, $d;

	(undef, undef, undef, $d, $m, $y) =
		localtime $key->{$is_subkey ? 'setime' : 'etime'};

	if ($d && $m && $y) {
		$s .= sprintf ', expires %04d-%02d-%02d', $y + 1900, $m + 1, $d;
	}

	return $s;
}

sub format_fingerprint {
	my ($key, $is_subkey) = @_;

	my $fprint = $key->{$is_subkey ? 'sfprint' : 'fprint'};
	my (@fields) = $fprint =~ m!([A-F0-9]{4})!g;

	return join(' ', @fields[0..4]) . '  ' . join(' ', @fields[5..9]);
}

sub format_download {
	my ($key) = @_;

	my $mtime = $key->{ctime};

	if (open GIT, '-|', qw(git log -1 --format=%ct --), $key->{filename}) {
		if (defined(my $line = readline GIT)) {
			chomp $line;
			$mtime = $line;
		}
		close GIT;
	}

	my $ts = strftime '%F %T %z', gmtime $mtime;

	return sprintf
		"[[https://git.openwrt.org/?p=keyring.git;a=history;f=%s|Last change: %s]] | " .
		"[[https://git.openwrt.org/?p=keyring.git;a=blob_plain;f=%s|Download]]\n"	,
		$key->{filename}, $ts, $key->{filename};
}

sub parse_timestamp {
	my ($s) = @_;

	if ($s =~ m!^(\d\d\d\d)-(\d\d)-(\d\d)$!) {
		return mktime(0, 0, 0, $3 + 0, $2 - 1, $1 - 1900);
	}

	return int $s;
}


my $markup_template = '';

if (open RAW, '-|', 'curl', '-s', "$page?do=export_raw") {
	local $/;
	$markup_template = readline RAW;
	close RAW;
}


my @pubkeys;

if (open KEYS, '-|', qw(find gpg/ -type f -name *.asc -print)) {
	while (defined(my $file = readline KEYS)) {
		chomp $file;
		if (open GPG, '-|', qw(gpg --with-fingerprint --with-fingerprint --with-colons), $file) {
			my %data;

			while (defined(my $line = readline GPG)) {
				chomp $line;
				my @fields = split ':', $line;
				if ($fields[0] eq 'uid' && !exists $data{name}) {
					($data{name}, $data{comment}, $data{email}) =
						$fields[9] =~ m!^([^()]+)(?: \((.+?)\))? <(.+)>$!;
				}
				elsif ($fields[0] eq 'pub') {
					$data{size} = int $fields[2];
					$data{type} = int $fields[3];
					$data{eid} = $fields[4];
					$data{ctime} = parse_timestamp($fields[5]);
					$data{etime} = $fields[6] ? parse_timestamp($fields[6]) : 0;
					if ($fields[9] && !exists $data{name}) {
						($data{name}, $data{comment}, $data{email}) =
							$fields[9] =~ m!^([^()]+)(?: \((.+?)\))? <(.+)>$!;
					}
				}
				elsif ($fields[0] eq 'sub') {
					$data{ssize} = int $fields[2];
					$data{stype} = int $fields[3];
					$data{seid} = $fields[4];
					$data{sctime} = parse_timestamp($fields[5]);
					$data{setime} = $fields[6] ? parse_timestamp($fields[6]) : 0;
				}
				elsif ($fields[0] eq 'fpr') {
					$data{exists($data{stype}) ? 'sfprint' : 'fprint'} = $fields[9];
				}
			}

			close GPG;

			$data{filename} = $file;
			$data{is_system_key} =
				(index($data{email}, 'openwrt.org') >= 0) ||
				(index($data{email}, 'lede-project.org') >= 0) ||
				(index($data{email}, 'lists.openwrt.org') >= 0) ||
				(index($data{email}, 'lists.infradead.org') >= 0);

			push @pubkeys, \%data;
		}
	}

	close KEYS;
}

my $gpg_markup = '';

foreach my $key (sort {
	!$a->{is_system_key} <=> !$b->{is_system_key} ||
	$a->{name} cmp $b->{name}
} @pubkeys) {

	$gpg_markup .= sprintf "---\n\n=== %s ===\n\n",
		format_title($key);

	$gpg_markup .= sprintf "User ID: **%s** <%s>\\\\\n",
		$key->{name}, $key->{email};

	$gpg_markup .= sprintf "Public Key: 0x%s**%s** (%s)\\\\\n",
		substr($key->{eid}, 0, 8), substr($key->{eid}, 8),
		format_keytype($key, 0);

	$gpg_markup .= sprintf "Fingerprint: ''%%%%%s%%%%''\\\\\n",
		format_fingerprint($key, 0);

	if (exists $key->{stype}) {
		$gpg_markup .= sprintf "Signing Subkey: 0x%s **%s** (%s)\\\\\n",
			substr($key->{seid}, 0, 8), substr($key->{seid}, 8),
			format_keytype($key, 1);

		$gpg_markup .= sprintf "Fingerprint: ''%%%%%s%%%%''\\\\\n",
			format_fingerprint($key, 1);
	}

	$gpg_markup .= sprintf "%s\n", format_download($key);
}


my @usignkeys;

if (open KEYS, '-|', qw(find usign/ -type f -name *[0-9a-f] -print)) {
	while (defined(my $file = readline KEYS)) {
		chomp $file;

		if (open USIGN, '<', $file) {
			my %data;

			while (defined(my $line = readline USIGN)) {
				chomp $line;

				if ($line =~ m!^untrusted comment: (.+)$!) {
					$data{comment} = $1;
				}
				else {
					$data{key} = $line;
				}
			}

			close USIGN;

			$file =~ m!/([0-9a-f]{16})$!;

			$data{id} = $1;
			$data{filename} = $file;

			push @usignkeys, \%data;
		}
	}

	close KEYS;
}

my $usign_markup = '';

foreach my $key (sort { $a->{comment} cmp $b->{comment} } @usignkeys) {
	$usign_markup .= sprintf "---\n\n=== %s ===\n\n",
		$key->{comment};

	$usign_markup .= sprintf "  * Key-ID: ''%%%%%s%%%%''\n",
		$key->{id};

	$usign_markup .= sprintf "  * Key-Data: ''%%%%%s%%%%''\n\n",
		$key->{key};

	$usign_markup .= sprintf "%s\n",
		format_download($key);
}


$markup_template =~ s!
	( /\*\sBEGIN\sGPG\sKEYS\s\*/ )
	.+
	( /\*\sEND\sGPG\sKEYS\s\*/ )
!
	$1 . "\n\n" . $gpg_markup . $2;
!esx;

$markup_template =~ s!
	( /\*\sBEGIN\sUSIGN\sKEYS\s\*/ )
	.+
	( /\*\sEND\sUSIGN\sKEYS\s\*/ )
!
	$1 . "\n\n" . $usign_markup . $2;
!esx;


print $markup_template;
