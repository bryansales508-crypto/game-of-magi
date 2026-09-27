#!/usr/bin/env bash
# Waits until cloud builders finish, then prints where their work is.
#
# Cloud sessions choose their own branch names (e.g. claude/m1-01-folder-layout-qf1ju2),
# so this does not watch a branch. It scans EVERY branch on origin and looks for a tip
# commit whose message starts with "DONE <TASK-ID>:".
#
# Usage: scripts/watch-done.sh M1-02 M1-03 [...]
#   To wait for a NEW done commit after a follow-up, add the old one to ignore: M1-01@7ded19b
#   Prints "DONE <ID> <branch> <sha>" for each task as it finishes, and exits once all are done.
#   Polls every 60 s (free: only git ls-remote/fetch). Gives up after 3 hours with "TIMEOUT <ids>".

set -u
cd "$(dirname "$0")/.." || exit 1

pending=("$@")
if [ ${#pending[@]} -eq 0 ]; then
	echo "usage: scripts/watch-done.sh <TASK-ID> [...]"
	exit 2
fi

deadline=$(( $(date +%s) + 3 * 60 * 60 ))

while [ ${#pending[@]} -gt 0 ]; do
	git fetch -q --prune origin 2>/dev/null
	still=()
	for entry in "${pending[@]}"; do
		id="${entry%%@*}"
		ignore=""
		[ "$entry" != "$id" ] && ignore="${entry#*@}"
		found=""
		while read -r sha ref; do
			branch="${ref#refs/remotes/}"
			if [ -n "$ignore" ] && [ "${sha#"$ignore"}" != "$sha" ]; then continue; fi
			subject=$(git log -1 --format=%s "$sha" 2>/dev/null)
			case "$subject" in
				"DONE $id:"*) found="$branch $sha"; break ;;
			esac
		done < <(git for-each-ref --format='%(objectname) %(refname)' refs/remotes/origin)
		if [ -n "$found" ]; then
			echo "DONE $id $found"
		else
			still+=("$entry")
		fi
	done
	pending=("${still[@]+"${still[@]}"}")
	[ ${#pending[@]} -eq 0 ] && break
	if [ "$(date +%s)" -ge "$deadline" ]; then
		echo "TIMEOUT ${pending[*]}"
		exit 1
	fi
	sleep 60
done
