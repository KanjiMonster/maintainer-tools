#!/usr/bin/env perl

use strict;
use warnings;
use Text::CSV;

my $range = $ARGV[0];

unless (defined $range) {
	printf STDERR "Usage: $0 range\n";
	exit 1;
}

my $commit_url = 'https://git.openwrt.org/?p=openwrt/openwrt.git;a=commitdiff;h=%s';

my @weblinks = (
	[ qr'^[^:]+://(git.lede-project.org/)(.+)$' => 'https://%s?p=%s;a=commitdiff;h=%%s' ],
	[ qr'^[^:]+://(git.openwrt.org/)(.+)$'      => 'https://%s?p=%s;a=commitdiff;h=%%s' ],
	[ qr'^[^:]+://(github.com/.+?)(?:\.git)?$'  => 'https://%s/commit/%%s' ],
	[ qr'^[^:]+://git.kernel.org/pub/scm/(.+)$' => 'https://git.kernel.org/cgit/%s/commit/?id=%%s' ],
	[ qr'^[^:]+://w1.fi/(?:.+/)?(.+)\.git$'     => 'https://w1.fi/cgit/%s/commit/?id=%%s' ],
);


my %topics;
my %commits;
my %reverts;
my $index = 0;

sub line(*$)
{
	my ($fh, $default) = @_;

	my $line = readline $fh;

	if (defined $line)
	{
		chomp $line;
		return $line;
	}

	return $default;
}

my @topic_paths = (
	[ qr'^package/(kernel)/linux',                 'Kernel' ],
	[ qr'^(target/linux/generic|include/kernel-version.mk)', 'Kernel' ],
	[ qr'^package/kernel/(mac80211)',              'Wireless / Common' ],
	[ qr'^package/kernel/(ath10k-ct)',             'Wireless / Ath10k CT' ],
	[ qr'^package/kernel/(mt76)',                  'Wireless / MT76' ],
	[ qr'^package/(base-files)/',                  'Packages / LEDE base files' ],
	[ qr'^package/(boot)/',                        'Packages / Boot Loaders' ],
	[ qr'^package/firmware/',                      'Packages / Firmware' ],
	[ qr'^package/.+/(uhttpd|usbmode|jsonfilter|ugps|libubox|procd|mountd|ubus|uci|usign|rpcd|fstools|ubox)/', 'Packages / LEDE system userland' ],
	[ qr'^package/.+/(iwinfo|umbim|uqmi|relayd|mdns|firewall|netifd|uclient|ustream-ssl|gre|ipip|qos-scripts|swconfig|vti|6in4|6rd|6to4|ds-lite|map|odhcp6c|odhcpd)/', 'Packages / LEDE network userland' ],
	[ qr'^package/[^/]+/([^/]+)',                  'Packages / Common' ],
	[ qr'^target/sdk/',                            'Build System / SDK' ],
	[ qr'^target/imagebuilder/',                   'Build System / Image Builder' ],
	[ qr'^target/toolchain/',                      'Build System / Toolchain' ],
	[ qr'^target/linux/([^/]+)',                   'Target / $1' ],
	[ qr'^(tools)/[^/]+',                          'Build System / Host Utilities' ],
	[ qr'^(toolchain)/[^/]+',                      'Build System / Toolchain' ],
	[ qr'^(config/|include/|scripts/|target/[^/]+$|Makefile|rules\.mk)', 'Build System / Buildroot' ],
	[ qr'^(feeds)\b',                              'Build System / Feeds' ],
);

my @subhistory_matches = (
	qr'(?i)^\S+: update to\b',
	qr'(?i)^\S+: Upstep to\b',
	qr'(?i)^\S+: bump to\b',
	qr'(?i)^\S+: fix\b',
	qr'(?i)^\S+: backport\b',
	qr'(?i)\blatest HEAD\b',
);

sub match_topics(@)
{
	my %topics;

	foreach my $path (@_)
	{
		foreach my $rs (@topic_paths)
		{
			if ($path =~ $rs->[0])
			{
				my $m = $1;
				my $s = $rs->[1];

				$s =~ s!\$1!$m!g;
				$topics{$s}++;

				last;
			}
		}
	}

	my @topics = sort keys %topics;
	return (@topics > 0 ? @topics : ('Miscellaneous'));
}

sub parse_history($$)
{
	my ($dir, $range) = @_;

	my @commits;
	my ($max_add, $total_add, $max_del, $total_del) = (0, 0, 0, 0);

	if (open GIT, '-|', 'git', "--git-dir=$dir/.git", 'log', '--format=@@%n%H%n%s%n%b%n@@', '--numstat', '--reverse', '--no-merges', $range)
	{
		# skip header line
		line(*GIT, undef);

		while (1)
		{
			my $hash = line(GIT, '');
			my $subject = line(GIT, '');

			last unless (length($subject) && $hash =~ m!^!);

			my $line = '';
			my $body = '';
			my @files;
			my ($add, $del) = (0, 0);

			my $is_revert = $subject =~ m!^Revert !;

			$reverts{$hash}++ if $is_revert;

			while ($line ne '@@')
			{
				$body .= length($line) ? "$line\n" : '';
				$line = line(*GIT, '@@');

				if ($is_revert && $line =~ m!\b([0-9a-f]{40})\b!)
				{
					$reverts{$1}++;
				}
			}

			$line = '';

			while ($line ne '@@')
			{
				if ($line =~ m!^(\d+|-)\s+(\d+|-)\s+(.+)$!)
				{
					$add += ($1 eq '-') ? 0 : int($1);
					$del += ($2 eq '-') ? 0 : int($2);
					push @files, $3;
				}

				$line = line(*GIT, '@@');
			}

			my $commit = [
				$index++,
				$hash,
				$subject,
				$body,
				\@files,
				undef,
				undef,
				$add,
				$del
			];

			$total_add += $add;
			$total_del += $del;

			$max_add = ($add > $max_add) ? $add : $max_add;
			$max_del = ($del > $max_del) ? $del : $max_del;

			push @commits, $commit;
		}

		close GIT;
	}

	if (@commits > 0 && $commits[0][2] =~ /\brevert to branch defaults$/)
	{
		shift @commits;
	}

	return wantarray ? @commits : \@commits;
}

sub fetch_subhistory($$$)
{
	my ($url, $old, $new) = @_;

	(my $path = $url) =~ s![^a-z0-9_-]+!-!g;

	unless (-d "/tmp/repos/$path")
	{
		mkdir('/tmp/repos');
		system('git', 'clone', '--quiet', $url, "/tmp/repos/$path");
	}
	else
	{
		system('git', "--work-tree=/tmp/repos/$path", "--git-dir=/tmp/repos/$path/.git", 'pull', '--quiet');
	}

	return parse_history("/tmp/repos/$path", "$old..$new");
}

sub requires_subhistory($$$)
{
	my ($subject, $body, $hash) = @_;

	foreach my $re (@subhistory_matches)
	{
		if ($subject =~ $re || $body =~ $re)
		{
			if (open DIFF, '-|', 'git', 'diff', "$hash^!")
			{
				my ($url, $old, $new);

				while (defined(my $line = readline DIFF))
				{
					chomp $line;

					if ($line =~ m!^[ +]PKG_SOURCE_URL\s*:?=\s*(\S+)!)
					{
						$url = $1;
						$url =~ s!\$\(LEDE_GIT\)!https://git.lede-project.org!g;
						$url =~ s!\$\(OPENWRT_GIT\)!https://git.openwrt.org!g;
						$url =~ s!\$\(PROJECT_GIT\)!https://git.openwrt.org!g;
					}
					elsif ($line =~ m!^-\S+\s*:?=\s*([a-f0-9]{40})\b!)
					{
						$old = $1;
					}
					elsif ($line =~ m!^\+\S+\s*:?=\s*([a-f0-9]{40})\b!)
					{
						$new = $1;
					}

					if ($url && $old && $new)
					{
						return ($url, $old, $new);
					}
				}

				close DIFF;
			}
		}
	}

	return ();
}

sub find_weblink_template($)
{
	my ($url) = @_;

	foreach my $rt (@weblinks)
	{
		my @m = $url =~ $rt->[0];
		if (@m > 0)
		{
			return sprintf $rt->[1], @m;
		}
	}

	warn "No web link template for <$url>\n";
	return undef;
}

sub format_stat($)
{
	my ($commit) = @_;

	my $s = '';
	my $c = '<color #ccc>%s</color>';
	my $g = '<color #282>%s</color>';
	my $r = '<color #f00>%s</color>';

	if ($commit->[7] > 1000)
	{
		$s .= sprintf $g, sprintf '+%.1fK', $commit->[7] / 1000;
	}
	elsif ($commit->[7] > 0)
	{
		$s .= sprintf $g, sprintf '+%d', $commit->[7];
	}

	if ($commit->[8] > 1000)
	{
		$s .= $s ? sprintf($c, ',') : '';
		$s .= sprintf $r, sprintf '-%.1fK', $commit->[8] / 1000;
	}
	elsif ($commit->[8] > 0)
	{
		$s .= $s ? sprintf($c, ',') : '';
		$s .= sprintf $r, sprintf '-%d', $commit->[8];
	}

	return sprintf($c, '(') . $s . sprintf($c, ')');
}

sub format_subject($$)
{
	my ($subject, $body) = @_;

	if (length($subject) > 80)
	{
		$subject = substr($subject, 0, 77) . '...';
	}

	$subject =~ s!^([^\s:]+):\s*!</nowiki>**<nowiki>$1:</nowiki>** <nowiki>!g;

	$subject = sprintf '<nowiki>%s</nowiki>', $subject;
	$subject =~ s!<nowiki></nowiki>!!g;

	return $subject;
}

sub format_change($)
{
	my ($change) = @_;

	printf "''[[%s|%s]]'' %s //%s//\\\\\n",
		sprintf($commit_url, $change->[1]),
		substr($change->[1], 0, 7),
		format_subject($change->[2], $change->[3]),
		format_stat($change);

	if ($change->[6])
	{
		my $n = 0;
		foreach my $subchange (@{$change->[6]})
		{
			if ($change->[5])
			{
				printf " => ''[[%s|%s]]'' %s //%s//\\\\\n",
					sprintf($change->[5], $subchange->[1]),
					substr($subchange->[1], 0, 7),
					format_subject($subchange->[2], $subchange->[3]),
					format_stat($subchange);
			}
			else
			{
				printf " => ''%s'' %s //%s//\\\\\n",
					substr($subchange->[1], 0, 7),
					format_subject($subchange->[2], $subchange->[3]),
					format_stat($subchange);
			}

			if (++$n > 15 && @{$change->[6]} > $n)
			{
				printf " => + //%u more...//\\\\\n", @{$change->[6]} - $n;
				last;
			}
		}
	}
}

sub fetch_cve_info()
{
	unless (-f '/tmp/cveinfo.csv')
	{
		system('wget', '-O', '/tmp/cveinfo.csv.gz', 'https://cve.mitre.org/data/downloads/allitems.csv.gz') && return 0;
		system('gunzip', '-f', '/tmp/cveinfo.csv.gz') && return 0;
	}

	return 1;
}

sub parse_cves(@)
{
	my $csv = Text::CSV->new({ binary => 1 });
	my %cves;

	if (fetch_cve_info() && $csv)
	{
		if (open CVE, '<', '/tmp/cveinfo.csv')
		{
			while (defined(my $row = $csv->getline(*CVE)))
			{
				foreach my $cve_id (@_)
				{
					if ($row->[0] eq $cve_id)
					{
						$cves{$cve_id} = [$row->[2], $row->[6]];
						last;
					}
				}
			}

			close CVE;
		}
	}

	return \%cves;
}

sub fetch_bug_info()
{
	unless (-f '/tmp/buginfo.csv')
	{
		system('wget', '-O', '/tmp/buginfo.csv', 'https://bugs.openwrt.org/index.php?string=&project=2&do=index&export_list=Export+Tasklist&advancedsearch=on&type%5B%5D=&sev%5B%5D=&pri%5B%5D=&due%5B%5D=&reported%5B%5D=&cat%5B%5D=&status%5B%5D=&percent%5B%5D=&opened=&dev=&closed=&duedatefrom=&duedateto=&changedfrom=&changedto=&openedfrom=&openedto=&closedfrom=&closedto=') && return 0;
	}

	return 1;
}

sub parse_bugs(@)
{
	my $csv = Text::CSV->new({ binary => 1, allow_loose_quotes => 1, eol => "\012" });
	my %bugs;

	if (fetch_bug_info() && $csv)
	{
		if (open BUG, '<', '/tmp/buginfo.csv')
		{
			while (defined(my $row = $csv->getline(*BUG)))
			{
				foreach my $bug_id (@_)
				{
					if ($row->[0] eq $bug_id)
					{
						$bugs{$bug_id} = [$row->[4], $row->[5]];
						last;
					}
				}
			}

			$csv->error_diag;

			close BUG;
		}
	}

	return \%bugs;
}


my @commits = parse_history('.', $range);
my (%bugs, %cves);

foreach my $commit (@commits)
{
	my @topics = match_topics(@{$commit->[4]});

	unless ($commit->[5])
	{
		my ($su, $so, $sn) = requires_subhistory($commit->[2], $commit->[3], $commit->[1]);
		if ($su) {
			$commit->[5] = find_weblink_template($su);
			$commit->[6] = fetch_subhistory($su, $so, $sn);
		}
	}

	foreach my $topic (@topics)
	{
		$topics{$topic} ||= [ ];
		push @{$topics{$topic}}, $commit;
	}

	my (%bug_ids, %cve_ids);

	foreach my $bug ($commit->[2] =~ m!([A-Z]*#\d+)\b!g,
	                 $commit->[3] =~ m!([A-Z]*#\d+)\b!g)
	{
		if ($bug =~ m!^(?:FS|GH|)#(\d+)$!)
		{
			$bug_ids{$1}++;
		}
	}

	foreach my $cve ($commit->[2] =~ m!\b(CVE-\d+-\d+|\d+-CVE-\d+)\b!g,
	                 $commit->[3] =~ m!\b(CVE-\d+-\d+|\d+-CVE-\d+)\b!g)
	{
		# fix misspelled CVE IDs
		$cve =~ s!^(\d+)-CVE-!CVE-$1-!;
		$cve_ids{$cve}++;
	}

	foreach my $bug (keys %bug_ids)
	{
		$bugs{$bug} ||= [ ];
		push @{$bugs{$bug}}, $commit;
	}

	foreach my $cve (keys %cve_ids)
	{
		$cves{$cve} ||= [ ];
		push @{$cves{$cve}}, $commit;
	}
}


my @topics = sort { (($a eq 'Miscellaneous') <=> ($b eq 'Miscellaneous')) || $a cmp $b } keys %topics;

foreach my $topic (@topics)
{
	my @commits = grep { !$reverts{$_->[1]} } @{$topics{$topic}};

	printf "==== %s (%d change%s) ====\n", $topic, 0 + @commits, @commits > 1 ? 's' : '';

	foreach my $change (sort { $a->[0] <=> $b->[0] } @commits)
	{
		format_change($change);
	}

	print "\n";
}

my @bugs = sort { int($a) <=> int($b) } keys %bugs;
my $bug_info = parse_bugs(@bugs);

@bugs = grep { $bug_info->{$_} && $bug_info->{$_}[0] } @bugs;

if (@bugs > 0)
{
	printf "===== Addressed bugs =====\n";

	foreach my $bug (@bugs)
	{
		printf "=== #%s ===\n", $bug;
		printf "**Description:** <nowiki>%s</nowiki>\\\\\n", $bug_info->{$bug}[0];
		printf "**Link:** [[https://bugs.openwrt.org/index.php?do=details&task_id=%s]]\\\\\n", $bug;
		printf "**Commits:**\\\\\n";

		foreach my $commit (@{$bugs{$bug}})
		{
			format_change($commit);
		}

		printf "\\\\\n";
	}

	printf "\n";
}

my @cves =
	map { $_->[1] }
	sort { ($a->[0] <=> $b->[0]) || ($a->[1] cmp $b->[1]) }
	map { $_ =~ m!^CVE-(\d+)-(\d+)$! ? [ $1 * 10000000 + $2, $_ ] : [ 0, $_ ] }
	keys %cves;

my $cve_info = parse_cves(@cves);

if (@cves > 0)
{
	printf "===== Security fixes ====\n";

	foreach my $cve (@cves)
	{
		printf "=== %s ===\n", $cve;

		if ($cve_info->{$cve} && $cve_info->{$cve}[0])
		{
			printf "**Description:** <nowiki>%s</nowiki>\n\n", $cve_info->{$cve}[0];
		}

		printf "**Link:** [[https://cve.mitre.org/cgi-bin/cvename.cgi?name=%s]]\\\\\n", $cve;
		printf "**Commits:**\\\\\n";

		foreach my $commit (@{$cves{$cve}})
		{
			format_change($commit);
		}

		printf "\\\\\n";
	}

	printf "\n";
}
