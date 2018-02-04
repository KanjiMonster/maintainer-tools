#!/bin/bash

# Github repository, just the name/repo part, no .git suffix, no base url!
REPO="openwrt/openwrt"

# Your repository token, generate this token at your profile page:
# - Navigate to https://github.com/settings/tokens
# - Click on "Generate new token"
# - Enter a description, e.g. "pr.sh" and pick the "repo" scope
# - Hit "Generate token"
#TOKEN="d41d8cd98f00b204e9800998ecf8427e"

# Default close comment
COMMENT="Pulled into my staging tree at https://git.openwrt.org/openwrt/staging/$(whoami).git"

PRID="$1"
BRANCH="${2:-master}"

if [ -z "$PRID" -o -n "${PRID//[0-9]*/}" ]; then
	echo "Usage: $0 <PR-ID> [rebase-branch]" >&2
	exit 1
fi

if [ -z "$(git branch --list "$BRANCH")" ]; then
	echo "Given rebase branch '$BRANCH' does not exist!" >&2
	exit 2
fi

if ! git fetch "https://github.com/$REPO.git" "pull/$PRID/head:PR$PRID"; then
	echo "Failed fetch PR #$PRID!" >&2
	exit 3
fi

git checkout "PR$PRID"

if ! git rebase "$BRANCH"; then
	echo ""                                                      >&2
	echo "Cannot automatically rebase 'PR$PRID' onto '$BRANCH'!" >&2
	echo "Fix conflicts manually and continue with:"             >&2
	echo ""                                                      >&2
	echo "  git checkout $BRANCH"                                >&2
	echo "  git merge --ff-only PR$PRID"                         >&2
	echo "  git branch -D PR$PRID"                               >&2
	echo ""                                                      >&2
	echo "Alternatively cancel the whole operation with:"        >&2
	echo ""                                                      >&2
	echo "  git rebase --abort"                                  >&2
	echo "  git checkout $BRANCH"                                >&2
	echo "  git branch -D PR$PRID"                               >&2
	echo ""                                                      >&2
fi

git checkout "$BRANCH"

if ! git merge --ff-only "PR$PRID"; then
	echo ""                                                       >&2
	echo "Failed to fast-forward merge 'PR$PRID' into '$BRANCH'!" >&2
	echo "Aborting, but leaving branch 'PR$PRID' behind."         >&2
	exit 5
fi

git branch -D "PR$PRID"

if [ -n "$TOKEN" ]; then
	echo ""
	echo "Enter a comment and hit <enter> to close the PR at Github automatically now."
	echo "Hit <ctrl>-<c> to exit."
	echo ""
	echo "If you do not provide a comment, the default will be: "
	echo "[$COMMENT]"

	echo -n "Comment > "
	read usercomment

	echo "Closing PR..."

	comment="${usercomment:-$COMMENT}"
	comment="${comment//\\/\\\\}"
	comment="${comment//\"/\\\"}"
	comment="$(printf '{"body":"%s"}' "$comment")"

	if ! curl -s -o /dev/null -w "%{http_code} %{url_effective}\\n" --user "$TOKEN:x-oauth-basic" --request POST --data "$comment" "https://api.github.com/repos/$REPO/issues/$PRID/comments" || \
	   ! curl -s -o /dev/null -w "%{http_code} %{url_effective}\\n" --user "$TOKEN:x-oauth-basic" --request PATCH --data '{"state":"closed"}' "https://api.github.com/repos/$REPO/pulls/$PRID"
	then
		echo ""                                                     >&2
		echo "Something failed while trying to close the PR via "   >&2
		echo "the Github API, please review the state manually at " >&2
		echo "https://github.com/$REPO/pull/$PRID"                  >&2
		exit 6
	fi
fi

echo ""
echo "The PR has been merged!"
echo "Consider pushing your '$BRANCH' branch to its remote now."

exit 0
