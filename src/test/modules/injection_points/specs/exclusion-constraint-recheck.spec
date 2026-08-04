# Test that a unique constraint conflict check is not lost when a concurrent
# non-HOT update of the conflicting row commits while the check is in flight.
#
# check_exclusion_or_unique_constraint() scans the constraint's index with a
# non-MVCC dirty snapshot, and an index scan caches a leaf page's matching
# TIDs before it checks the visibility of any heap tuple.  s1 is parked in
# exactly that window, between reading the index entry for the pre-existing
# key and fetching its heap tuple.  s2 then updates that row and commits, so
# by the time s1 resumes the cached version is no longer visible to the dirty
# snapshot, while the successor's freshly inserted index entry is absent from
# the page copy s1 is reading from.  A dirty snapshot reports an xid to wait
# for only while the other transaction is still in progress, so the
# pre-existing wait-and-retry recovery is not armed once s2 has committed: the
# scan just ends with no rows, and the check would report "no conflict" for a
# row that existed throughout.  Verifying such a negative result once under a
# fresh MVCC snapshot, which cannot lose the row, is what keeps the conflict
# visible.
#
# The index on the column s2 updates is mandatory, not decoration.  It is
# what makes s2's update non-HOT, so that a new index entry is written and
# the HOT chain leading away from the cached version is broken.  A HOT update
# would instead carry the scan to the successor version, and then the race
# cannot be provoked at all, leaving a test that always passes.
#
# Seeding the table is mandatory for a related reason.  The negative result is
# only re-examined when the scan discarded an index entry whose tuple it could
# not see, so an index entry for the conflicting key has to exist before s1
# starts.  Against an empty table nothing is ever discarded, the injection
# point never fires, and s1 never parks.
#
# The error-mode "no-conflict" injection point is the assertion oracle, and a
# row count cannot stand in for it.  Had the check wrongly reported "no
# conflict", ExecInsert() would have gone on to insert speculatively, detected
# the conflict while inserting the index tuple, killed the speculative tuple
# and re-run the check, which would have found the row that second time.
# "INSERT 0 0" and one surviving row are therefore the outcome with or without
# the recheck, and only the marker tells the two apart.  For the same reason
# s2 must not detach that point: s1 is still inside the check when it is
# woken, so detaching the oracle would disarm the assertion.
#
# s2 detaches the wait point before waking s1, both in a single step so that
# nothing can run in between.  The recheck re-enters the same code, and hence
# the same injection point, so a still-attached wait point would park s1 a
# second time with nobody left to wake it.

setup
{
	CREATE EXTENSION injection_points;

	CREATE TABLE upsert_tab (a int PRIMARY KEY, i int);
	CREATE INDEX ups_i_idx ON upsert_tab (i);
	INSERT INTO upsert_tab VALUES (1, 0);
}
teardown
{
	DROP TABLE upsert_tab;
	DROP EXTENSION injection_points;
}

# The conflict check runs here, and is parked in the middle of its index scan.
# The points are attached locally so that they cannot fire in any other
# backend.
session s1
setup	{
	SELECT FROM injection_points_set_local();
	SELECT FROM injection_points_attach('check-exclusion-or-unique-constraint-before-heap-fetch', 'wait');
	SELECT FROM injection_points_attach('check-exclusion-or-unique-constraint-no-conflict', 'error');
}
step s1upsert	{ INSERT INTO upsert_tab VALUES (1, 0) ON CONFLICT DO NOTHING; }
step s1noop	{ }

# The non-HOT update of the row s1 is checking, and the wakeup that lets s1
# resume once that update has committed.
session s2
step s2update	{ UPDATE upsert_tab SET i = i + 1 WHERE a = 1; }
step s2wake	{
	SELECT FROM injection_points_detach('check-exclusion-or-unique-constraint-before-heap-fetch');
	SELECT FROM injection_points_wakeup('check-exclusion-or-unique-constraint-before-heap-fetch');
}

# Only one permutation is declared.  The isolation tester re-runs each
# session's setup for every permutation, and the error-mode point is
# deliberately never detached, so attaching it a second time would fail.
# s1noop runs last: it cannot be launched until s1upsert is done, which pins
# down the point at which s1upsert's completion is reported.
permutation s1upsert s2update s2wake s1noop
