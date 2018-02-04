#!/usr/bin/env bash

git_author="Release System"
git_email="lede-dev@lists.infradead.org"

base_url="http://downloads.openwrt.org/releases"

[ -f "./feeds.conf.default" ] || {
	echo "Please execute as ./${0##*/}" >&2
	exit 1
}

usage() {
	{
		echo ""
		echo "Usage: $0 [-i] [-a <Git author>] [-e <Git email>] \\"
		echo "          [-u <Download base url>] [-n <codename>] -v <version>"
		echo ""
		echo "-i"
		echo "Exit successfully if branch already exists"
		echo ""
		echo "-a Git author [$git_author]"
		echo "Override the author name used for automated Git commits"
		echo ""
		echo "-e Git email [$git_email]"
		echo "Override the email used for automated Git commits"
		echo ""
		echo "-u Download base url [$base_url]"
		echo "Use the given URL as base for download repositories"
		echo ""
		exit 1
	} >&2
}

while getopts "a:e:iu:n:v:" opt; do
	case "$opt" in
		a) git_author="$OPTARG" ;;
		e) git_email="$OPTARG" ;;
		i) ignore_existing=1 ;;
		u) base_url="${OPTARG%/}" ;;
		n) codename="$OPTARG" ;;
		v)
			case "$OPTARG" in
				[0-9]*.[0-9]*)
					version="$(echo "$OPTARG" | cut -d. -f1-2)"
				;;
				*)
					echo "Unexpected version format: $OPTARG" >&2
					exit 1
				;;
			esac
		;;
		\?)
			echo "Unexpected option: -$OPTARG" >&2
			usage
		;;
		:)
			echo "Missing argument for option: -$OPTARG" >&2
			usage
		;;
	esac
done

[ -n "$version" ] || usage

revnum="$(./scripts/getver.sh)"
githash="$(git log --format=%h -1)"

prev_branch="$(git symbolic-ref -q HEAD)"

if [ "$prev_branch" != "refs/heads/master" ]; then
	echo "Expecting current branch name to be \"master\"," \
	     "but it is \"${prev_branch#refs/heads/}\" - aborting."

	exit 1
fi

distname="$(sed -ne '/config VERSION_DIST/ { :next; n; s/^[[:space:]]*default "\(.*\)"/\1/p; T next }' \
	package/base-files/image-config.in)"

distname="${distname:-OpenWrt}"
distname_lc="$(echo "$distname" | tr 'A-Z' 'a-z')"

if git rev-parse "${distname_lc}-${version}^{tree}" >/dev/null 2>/dev/null; then
	if [ -z "$ignore_existing" ]; then
		echo "Branch ${distname_lc}-${version} already exists!" >&2
		exit 1
	fi

	exit 0
fi

if grep -sq 'RELEASE:=' include/version.mk && [ -z "$codename" ]; then
	echo "A codename is required for this ${distname} version!" >&2
	exit 1
fi

export GIT_AUTHOR_NAME="$git_author"
export GIT_AUTHOR_EMAIL="$git_email"
export GIT_COMMITTER_NAME="$git_author"
export GIT_COMMITTER_EMAIL="$git_email"

git checkout -b "${distname_lc}-$version"

while read type name url; do
	case "$type" in
		src-git)
			case "$url" in
				*^*|*\;*) : ;;
				*)
					ref="$(git ls-remote "$url" "${distname_lc}-$version")"

					if [ -z "$ref" ]; then
						echo "WARNING: Feed \"$name\" provides no" \
						     "\"${distname_lc}-$version\" branch - using master!" >&2
					else
						url="$url;${distname_lc}-$version"
					fi
				;;
			esac
			echo "$type $name $url"
		;;
		src-*)
			echo "$type $name $url"
		;;
	esac
done < feeds.conf.default > feeds.conf.branch && \
	mv feeds.conf.branch feeds.conf.default

sed -e 's!^RELEASE:=.*!RELEASE:='"$codename"'!g' \
    -e 's!\(VERSION_NUMBER:=\$(if .*\),[^,]*)!\1,'"$version-SNAPSHOT"')!g' \
    -e 's!\(VERSION_REPO:=\$(if .*\),[^,]*)!\1,'"$base_url/$version-SNAPSHOT"')!g' \
	include/version.mk > include/version.branch && \
		mv include/version.branch include/version.mk

sed -e 's!http://downloads.\(openwrt\|lede-project\).org/[^"]*!'"$base_url/$version-SNAPSHOT"'!g' \
	package/base-files/image-config.in > package/base-files/image-config.branch && \
		mv package/base-files/image-config.branch package/base-files/image-config.in

git commit -sm "${distname:-OpenWrt} v$version: set branch defaults" \
	feeds.conf.default \
	include/version.mk \
	package/base-files/image-config.in

git --no-pager log -p -1
git checkout "${prev_branch#refs/heads/}"

cat <<EOT
# Push the branch with:
git push origin "refs/heads/${distname_lc}-$version:refs/heads/${distname_lc}-$version"
EOT

