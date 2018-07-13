#!/bin/bash

for d in "$@"
do
	pushd "$d" || continue

	find . -type f -not -empty | 
	grep -Ev "^\.?/(dev|proc|sys|media|mnt|incoming|backup|tmp)/" | 
        grep -Ev "(/.svn/|/thumbs/|/.thumbnails/|/Thumbs.db$|/.comments$)" |
	manage-fdb.pl --verbose --import

	popd
done

