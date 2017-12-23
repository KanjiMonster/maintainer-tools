#!/bin/bash

git filter-branch -f --tag-name-filter cat --commit-filter '

	eval $(git show --format=%B "$GIT_COMMIT" | sed -ne "s|Signed-off-by: \(.*\) <\(.*\)>$|SOB_AUTHOR='"'"'\\1'"'"'; SOB_EMAIL='"'"'\\2'"'"'|p" | head -n1)

	if [ -n "$SOB_AUTHOR" -a -n "$SOB_EMAIL" -a "$GIT_AUTHOR_NAME <$GIT_AUTHOR_EMAIL>" != "$SOB_AUTHOR <$SOB_EMAIL>" ]; then
		echo -e "\nRewrite $GIT_COMMIT: $GIT_AUTHOR_NAME <$GIT_AUTHOR_EMAIL> => $SOB_AUTHOR <$SOB_EMAIL>" >&2
		export GIT_AUTHOR_NAME="$SOB_AUTHOR"
		export GIT_AUTHOR_EMAIL="$SOB_EMAIL"
	fi

	git commit-tree "$@"

' -- "${1:-HEAD~1..HEAD}"

git for-each-ref --format="%(refname)" refs/original/ | xargs -r -n 1 git update-ref -d
