#!/usr/bin/env bash

yesno() {
	local prompt="$1"
	local default="${2:-n}"
	local input

	while [ 1 ]; do
		printf "%s y/n [%s] > " "$prompt" "$default"
		read input
		case "${input:-$default}" in
			y*) return 0 ;;
			n*) return 1 ;;
		esac
	done
}

fetch() {(
	set -e
	mkdir "pwclient.get.$$"
	cd "pwclient.get.$$"
	pwclient get "$1"
	mv * "../$1.patch"
	cd ..
	rmdir "pwclient.get.$$"
)}

get_date() {
	date +"%a, %d %b %Y %H:%M:%S %z" | sed -e 's|, 0|, |'
}

get_subject() {
	local subject line
	local IFS="
"

	for line in $(sed -ne '/^Subject: */ { s/^Subject: *//p; :next; n; s/^ \+//p; t next; b }' "$1"); do
		subject="$subject$line"
	done

	printf "%s\n" "$subject" | sed -e 's/^\[.*\] *//'
}

get_hdr_list() {
	local file="$1"
	local field="$2"
	local addr list

	local IFS=",
"

	for addr in $(sed -ne "/^$field: */ { s/^$field: *//p; :next; n; s/^ \\+//p; t next; b }" "$file"); do
		list="${list:+$list, }$(echo "$addr" | sed -e 's/^ \+//; s/ \+$//')"
	done

	[ -n "$list" ] && printf "%s: %s\n" "$field" "$list"
}

get_hdr() {
	sed -ne "s/^$2: *//p" "$1" | head -n1
}

format_reply() {
	local remote_ref remote_url remote_host remote_host remote_repo remote_user

	remote_ref="$(git for-each-ref --format='%(push:short)' $(git symbolic-ref -q HEAD))"

	[ -n "$remote_ref" ] || \
		remote_ref="$(git for-each-ref --format='%(upstream:short)' $(git symbolic-ref -q HEAD))"

	[ -n "$remote_ref" ] || \
		return 1

	remote_url="$(git remote get-url "${remote_ref%%/*}")"

	case "$remote_url" in
		http*://*)
			remote_host="${remote_url##http*://}"
			case "$remote_host" in *@*)
				remote_user="${remote_host%%@*}"
				remote_host="${remote_host##*@}"
			esac
			case "$remote_host" in */*)
				remote_repo="${remote_host#*/}"
				remote_host="${remote_host%%/*}"
			esac
		;;
		*:*)
			remote_host="$remote_url"
			case "$remote_host" in *@*)
				remote_user="${remote_host%%@*}"
				remote_host="${remote_host##*@}"
			esac
			case "$remote_host" in *:*)
				remote_repo="${remote_host##*:}"
				remote_host="${remote_host%%:*}"
			esac
		;;
	esac

	case "$remote_host" in
		git.lede-project.org|git.openwrt.org)
			case "$remote_repo" in
				source.git|openwrt/openwrt.git)
					echo "Merged into ${remote_ref##*/} with"
				;;
				lede/*/staging.git|openwrt/staging/*.git)
					echo "Merged into my staging tree with"
				;;
				*)
					echo "Merged into ${remote_repo:-the repository}, branch ${remote_ref##*/} with"
				;;
			esac
		;;
		*)
			echo "Merged with"
		;;
	esac

	echo "http://$remote_host/?p=$remote_repo;a=commitdiff;h=$(git log -1 --format=%h)."
	echo ""

	echo "Thank you!"
	echo ""
}

echo "$1" | grep -sqE '^[0-9]+$' || {
	echo "Usage: $0 <patch-id>" >&2
	exit 1
}

[ -f "$1.patch" ] || {
	pwclient info "$1" >/dev/null 2>/dev/null || {
		echo "Unknown patch ID: $1" >&2
		exit 2
	}

	fetch "$1" || {
		echo "Failed to download patch" >&2
		exit 3
	}
}

git am "$1.patch" || {
	echo "Failed to apply patch $1" >&2
	git am --abort
	exit 4
}

git log -p -1

if ! yesno "Keep change?" "y"; then
	git reset --hard HEAD^

	if yesno "Set to 'Changes Requested'?"; then
		pwclient update -s "Changes Requested" "$1"
	fi
else
	if yesno "Set to 'Accepted'?" "y"; then
		pwclient update -s "Accepted" "$1"

		if yesno "Send reply mail?" "y"; then
			{
				printf "From: %s <%s>\n" "$(git config user.name)" "$(git config user.email)"

				get_hdr_list "$1.patch" Cc

				printf "Date: %s\n" "$(get_date)"
				printf "Subject: Merged: %s\n\n" "$(get_subject "$1.patch")"

				format_reply
			} > "$1.reply"

			echo "==="
			cat "$1.reply"
			echo "==="

			if yesno "Edit reply?" "n"; then
				git send-email \
					--to "$(get_hdr "$1.patch" To)" \
					--cc "$(get_hdr "$1.patch" From)" \
					--in-reply-to "$(get_hdr "$1.patch" Message-Id)" \
					--compose "$1.reply"
			else
				git send-email \
					--to "$(get_hdr "$1.patch" To)" \
					--cc "$(get_hdr "$1.patch" From)" \
					--in-reply-to "$(get_hdr "$1.patch" Message-Id)" \
					--confirm=never "$1.reply"
			fi

			rm -f "$1.reply" "$1.patch"
		fi
	fi
fi
