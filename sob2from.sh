#!/bin/bash

git filter-branch -f --tag-name-filter cat --commit-filter '
	MESSAGE="$(git show --format=%B "$GIT_COMMIT")"
	SOB_LINE="$(echo "$MESSAGE" | sed -ne "s|^ *Signed-off-by: *||p" | head -n1)"
	SOB_AUTHOR="$(echo "$SOB_LINE" | sed -e "s|^\(.*\) <.*>\$|\\1|")"
	SOB_EMAIL="$(echo "$SOB_LINE" | sed -e "s|^.* <\(.*\)>\$|\\1|")"

	if [ -n "$SOB_AUTHOR" -a -n "$SOB_EMAIL" ] && \
	   [ "$GIT_AUTHOR_NAME <$GIT_AUTHOR_EMAIL>" != "$SOB_AUTHOR <$SOB_EMAIL>" ] && \
	   ! echo "$MESSAGE" | grep -sqE "^ *Signed-off-by: *$GIT_AUTHOR_NAME <$GIT_AUTHOR_EMAIL>"; then
		printf "\nRewrite $GIT_COMMIT: $GIT_AUTHOR_NAME <$GIT_AUTHOR_EMAIL> => $SOB_AUTHOR <$SOB_EMAIL>\n" >&2
		export GIT_AUTHOR_NAME="$SOB_AUTHOR"
		export GIT_AUTHOR_EMAIL="$SOB_EMAIL"
	fi

	git commit-tree "$@"

' -- "${1:-HEAD~1..HEAD}"

git for-each-ref --format="%(refname)" refs/original/ | xargs -r -n 1 git update-ref -d
