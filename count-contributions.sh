#!/usr/bin/env bash

commit_threshold=100
commit_timeframe="$(date --date="5 years ago" +%Y-%m-%d)"

NL="
"

IFS="$NL"
ACTIVE_PEOPLE=""


printf "### Recently active contributors:\n"
printf "[Active period begin-end] Commits (Alltime) Name <Mail>\n"

for line in $(git log --since $commit_timeframe --format="|%aN <%aE>" | sort | uniq -c | sort -nr); do
	count="${line%% |*}"; count="${count##* }"
	name="${line#* |}"

	if [ $count -lt $commit_threshold ]; then
		continue
	fi

	ACTIVE_PEOPLE="$ACTIVE_PEOPLE$name$NL"

	alltime="$(git log --use-mailmap --author="$name" --format="%aN" | wc -l)"
	begin="$(git log --use-mailmap --author="$name" --format="%cd" --date="format:%Y-%m-%d" --reverse | head -n1)"
	end="$(git log --use-mailmap --author="$name" --format="%cd" --date="format:%Y-%m-%d" -1)"

	printf "[%s - %s] %5d (%5d) %s\n" $begin $end $count $alltime "$name"
done

printf "\n"
printf "### Important all-time contributors:\n"
printf "[Active period begin-end] Commits Name <Mail>\n"

for line in $(git log --format="|%aN <%aE>" | sort | uniq -c | sort -nr); do
	count="${line%% |*}"; count="${count##* }"
	name="${line#* |}"

	if [ $count -lt $commit_threshold ] || echo "$ACTIVE_PEOPLE" | grep -qxF "$name"; then
		continue
	fi

	begin="$(git log --use-mailmap --author="$name" --format="%cd" --date="format:%Y-%m-%d" --reverse | head -n1)"
	end="$(git log --use-mailmap --author="$name" --format="%cd" --date="format:%Y-%m-%d" -1)"

	printf "[%s - %s] %5d %s\n" $begin $end $count "$name"
done
