#!/usr/bin/env perl

use strict;
use warnings;
use File::Temp 'tempfile';

$ENV{'LC_ALL'} = 'C';

sub version_cmp($$) {
	my ($a, $b) = @_;

	my $x = join '', map { sprintf "%04s", $_ } split /\./, $a;
	my $y = join '', map { sprintf "%04s", $_ } split /\./, $b;

	return ($x cmp $y);
}

sub print_diag($$) {
	my ($source, $pkgs) = @_;
	my $issues = 0;
	my @messages;

	foreach my $pkg (@$pkgs) {
		my (@pkgissues, %abi_versions);

		next if !defined($pkg->{'libs'}) || @{$pkg->{'libs'}} == 0;

		foreach my $lib (@{$pkg->{'libs'}}) {
			next unless defined $lib->{'soname'};

			if ($lib->{'soname'} =~ m!^.+\.so\.(.+?)$!) {
				$abi_versions{$1}++;
			}
		}

		if (keys(%abi_versions) > 1) {
			push @pkgissues, "bundles multiple libraries with different SONAME versions,\n".
			                 "      consider splitting into multiple packages:";

			foreach my $lib (@{$pkg->{'libs'}}) {
				next unless defined $lib->{'soname'};

				$pkgissues[-1] .= sprintf "\n       - define Package/lib%s (%s)",
					$lib->{'name'}, $lib->{'soname'};
			}
		}

		my ($highest_version) = sort version_cmp keys %abi_versions;

		if (defined($highest_version) && !defined($pkg->{'abiversion'})) {
			push @pkgissues, sprintf "should specify ABI_VERSION:=%s", $highest_version;
		}
		elsif (defined($highest_version) && defined($pkg->{'abiversion'}) &&
		       !exists($abi_versions{$pkg->{'abiversion'}})) {
			push @pkgissues,
				sprintf "specifies ABI_VERSION:=%s but none of the libary sonames matches, " .
				        "consider changing to ABI_VERSION:=%s",
					$pkg->{'abiversion'}, $highest_version;
		}

		foreach my $lib (@{$pkg->{'libs'}}) {
			next unless defined $lib->{'soname'};

			if ($lib->{'soname'} =~ m!\.so(?:\.[0-9a-zA-Z]+)+$! && $lib->{'unversioned_symlink'}) {
				push @pkgissues,
					sprintf "should not package unversioned %s symlink",
						$lib->{'unversioned_symlink'};
			}
		}

		if (@pkgissues > 0) {
			push @messages,
				sprintf " Package %s (define Package/%s)\n",
					$pkg->{'name'}, $pkg->{'name'};

			foreach my $issue (@pkgissues) {
				push @messages,
					sprintf "  [-] %s\n", $issue;
			}

			$issues += @pkgissues;
		}
	}

	if ($issues) {
		printf "Source %s/Makefile\n", $source;
		print @messages;
	}
}

sub analyze_ipk($) {
	my $ipk = shift;
	my (%info, $lib);

	$ipk =~ s/'/'"'"'/g;

	if (open my $control, '-|', "tar -Ozxf '$ipk' ./control.tar.gz | tar -Ozx ./control") {
		while (defined(my $line = readline $control)) {
			chomp $line;

			if ($line =~ m!^Package: *(\S+)$!) {
				$info{'name'} = $1;
			}
			elsif ($line =~ m!^Source: *(\S+)$!) {
				$info{'source'} = $1;
			}
			elsif ($line =~ m!^SourceName: *(\S+)$!) {
				my $abiv = substr $info{'name'}, length $1;

				$info{'name'} = $1;
				$abiv =~ s/^-//;
				$info{'abiversion'} = $abiv if length $abiv;
			}
		}

		close $control;
	}

	if (open my $listing, '-|', "tar -Ozxf '$ipk' ./data.tar.gz | tar -tz | sort") {
		while (defined(my $entry = readline $listing)) {
			chomp $entry; $entry =~ s/'/'"'"'/g;

			if ($entry =~ m!.+/lib/lib(\S+)\.so((?:\.[0-9a-zA-Z]+)+)?$!) {
				my ($fd, $fname) = tempfile('/tmp/libfile.so.XXXXXXX', 'UNLINK' => 1);
				my ($libname, $libversion) = ($1, $2);

				if (!$lib || $lib->{'name'} ne $libname) {
					$lib = { 'name' => $libname };
					push @{$info{'libs'}}, $lib;
				}

				if (open my $extract, '-|', "tar -Ozxf '$ipk' ./data.tar.gz | tar -Ozx '$entry'") {
					while (read $extract, my $buf, 1024) {
						print $fd $buf;
					}

					close $extract;
				}

				if (tell($fd) > 0) {
					if (open my $readelf, '-|', 'readelf', '-d', $fname) {
						while (defined(my $line = readline $readelf)) {
							chomp $line;

							if ($line =~ m!^ 0x[0-9a-f]{8,16} \(SONAME\) +Library soname: \[(.+)\]$!) {
								$lib->{'soname'} = $1;
								last;
							}
						}

						close $readelf;
					}
					else {
						warn "Failed to execute readelf: $!\n";
					}
				}
				elsif ($libversion) {
					$lib->{'versioned_symlink'} = $entry;
				}
				else {
					$lib->{'unversioned_symlink'} = $entry;
				}

				unlink $fname;
				close $fd;
			}
		}

		close $listing;
	}

	return \%info;
}

@ARGV >= 1 || die "Usage: $0 <.ipk directory> [<.ipk directory>...]\n";

my %sources;

foreach my $dir (@ARGV) {
	if (open my $find, '-|', 'find', $dir, '-type', 'f', '-name', 'lib*.ipk') {
		while (defined(my $ipk = readline $find)) {
			chomp $ipk;
			my $pkg = analyze_ipk($ipk);
			if (defined($pkg) && defined($pkg->{'source'})) {
				push @{$sources{$pkg->{'source'}}}, $pkg;
			}
		}

		close $find;
	}
}

foreach my $source (sort keys %sources) {
	print_diag($source, $sources{$source});
}
