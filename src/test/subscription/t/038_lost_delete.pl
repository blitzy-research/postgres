# Copyright (c) 2026, PostgreSQL Global Development Group

# Test that a replicated DELETE is not lost when a concurrent local non-HOT
# UPDATE of the same row commits while the apply worker is looking that row
# up by its replica identity.
#
# RelationFindReplTupleByIndex() runs its scan under a non-MVCC dirty
# snapshot.  An index scan caches a leaf page's matching TIDs and only then
# checks heap visibility, so when another transaction updates the row and
# commits inside that window three things line up against the scan: the
# cached old version now fails the visibility check, the non-HOT update has
# broken the HOT chain that would otherwise lead to the successor, and the
# successor's own index entry was inserted too late for this scan to see it.
# A dirty snapshot reports an xid to wait for only while the other
# transaction is still in progress, so the existing wait-and-retry recovery
# is not armed for an updater that has already committed either.  The lookup
# therefore used to report "no such row" for a row that existed throughout,
# and the apply worker discarded the replicated DELETE while logging a
# spurious delete_missing conflict in place of the delete_origin_differs
# conflict that had actually happened.
#
# A discarded DELETE does not stay a quiet divergence, which is why it is
# worth a test of its own.  The row it leaves behind is an orphan, and if the
# publisher ever reuses that key the apply worker reports insert_exists at
# ERROR, exits, and is relaunched only to fail on the very same remote
# transaction again.  Replication then stops advancing altogether and the
# publisher retains WAL without bound until someone drops and rebuilds the
# subscription by hand.
#
# An injection point parks the apply worker in exactly that window, so the
# losing interleaving is produced by construction rather than by chance and a
# single run is conclusive.  Note that the subscriber table carries an index
# on a subscriber-only column: that is what forces the concurrent local
# UPDATE to be non-HOT.  Without it the HOT chain would carry the scan to
# the successor and the race could not be provoked at all.

use strict;
use warnings FATAL => 'all';
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

plan skip_all => 'Injection points not supported by this build'
  unless $ENV{enable_injection_points} eq 'yes';

###############################
# Setup
###############################

# Create a publisher node
my $node_publisher = PostgreSQL::Test::Cluster->new('publisher');
$node_publisher->init(allows_streaming => 'logical');
$node_publisher->start;

# Create a subscriber node
my $node_subscriber = PostgreSQL::Test::Cluster->new('subscriber');
$node_subscriber->init(allows_streaming => 'logical');
$node_subscriber->start;

# Check if the extension injection_points is available
plan skip_all => 'Extension injection_points not installed'
  unless $node_subscriber->check_extension('injection_points');

# Enable the track_commit_timestamp on both nodes to detect the conflict when
# attempting to delete a row that was previously modified by a different
# origin; without it no conflict would be reported at all.  Disable
# autovacuum to avoid generating xid that could affect the replication slot's
# xmin value.
$node_publisher->append_conf(
	'postgresql.conf', qq{track_commit_timestamp = on
autovacuum = off});
$node_publisher->restart;

# The subscriber additionally preloads the injection_points library, because
# the injection point has to fire in the apply worker, which is a background
# process rather than the session that attaches the point.
$node_subscriber->append_conf(
	'postgresql.conf', qq{track_commit_timestamp = on
autovacuum = off
shared_preload_libraries = 'injection_points'});
$node_subscriber->restart;

$node_subscriber->safe_psql('postgres', "CREATE EXTENSION injection_points;");

# Create the table on the publisher and seed it before the subscription
# exists, so that the rows arrive through the initial table sync.
$node_publisher->safe_psql(
	'postgres', qq[
	CREATE TABLE lost_delete_tab (a int PRIMARY KEY, data text);
	INSERT INTO lost_delete_tab
		SELECT g, 'orig' FROM generate_series(1, 10) g;
]);

# Create the same table on the subscriber, with an extra column the publisher
# does not have and an index on it.  Updating that column locally cannot be a
# HOT update: it has to insert a new entry into every index of the table,
# including the primary key that the apply worker's replica identity lookup
# scans.  That is the precondition for the race driven below, so the index is
# essential rather than incidental.  The extra column needs a default because
# the remote tuples that get applied to it are narrower.
$node_subscriber->safe_psql(
	'postgres', qq[
	CREATE TABLE lost_delete_tab (a int PRIMARY KEY, data text,
		i int DEFAULT 0);
	CREATE INDEX lost_delete_tab_i_idx ON lost_delete_tab (i);
]);

# Setup logical replication
my $publisher_connstr = $node_publisher->connstr . ' dbname=postgres';
$node_publisher->safe_psql('postgres',
	"CREATE PUBLICATION pub_lost_delete FOR TABLE lost_delete_tab");

my $appname = 'sub_lost_delete';
$node_subscriber->safe_psql(
	'postgres',
	"CREATE SUBSCRIPTION sub_lost_delete
	 CONNECTION '$publisher_connstr application_name=$appname'
	 PUBLICATION pub_lost_delete;");

# Wait for initial table sync to finish
$node_subscriber->wait_for_subscription_sync($node_publisher, $appname);

##################################################
# A replicated DELETE racing a local non-HOT
# UPDATE of the same row
##################################################

# Park the apply worker between reading the index entry for the row and
# checking whether the heap tuple it points at is visible.  The point has to
# be attached cluster-wide rather than with injection_points_set_local(),
# because it fires in the apply worker and not in this session.
$node_subscriber->safe_psql('postgres',
	"SELECT injection_points_attach('find-repl-tuple-by-index-before-heap-fetch', 'wait');"
);

my $log_location = -s $node_subscriber->logfile;

# Replicate a DELETE of the row the apply worker is about to look up.
$node_publisher->safe_psql('postgres',
	"DELETE FROM lost_delete_tab WHERE a = 1");

# Wait until the apply worker reaches the injection point.  It holds no tuple
# lock there, and its RowExclusiveLock on the table and on the index does not
# conflict with the local UPDATE below, so that UPDATE is free to commit
# while the worker is parked.  This is the whole basis of the race.
$node_subscriber->wait_for_event('logical replication apply worker',
	'find-repl-tuple-by-index-before-heap-fetch');

# Update the same row locally.  Because the indexed column i changes, this is
# a non-HOT update: it leaves the old heap tuple dead with an already
# committed xmax, breaks the HOT chain that led to it, and inserts a fresh
# primary key entry that the parked scan has already read past.  From here on
# that scan cannot reach any live version of the row, so its negative result
# has to be verified under a fresh MVCC snapshot before it is believed.
$node_subscriber->safe_psql('postgres',
	"UPDATE lost_delete_tab SET i = i + 1 WHERE a = 1");

# Let the apply worker resume, and detach so that it cannot park again.
$node_subscriber->safe_psql(
	'postgres',
	"SELECT injection_points_wakeup('find-repl-tuple-by-index-before-heap-fetch');
	 SELECT injection_points_detach('find-repl-tuple-by-index-before-heap-fetch');"
);

# Only now can the worker make progress, so only now is it safe to wait for
# it to catch up.
$node_publisher->wait_for_catchup($appname);

# The row the DELETE named has to be gone.  This is the assertion that
# matters most: a row surviving here is exactly the orphan the defect used to
# leave behind, and an orphan is what later wedges the apply worker for good.
my $orphans = $node_subscriber->safe_psql('postgres',
	"SELECT count(*) FROM lost_delete_tab WHERE a = 1");
is($orphans, '0', 'replicated delete was applied, leaving no orphan row');

# Convergence, not merely the absence of a log line, is what matters here,
# because the harm this defect does is divergence.  Compare the replicated
# columns only: the subscriber has a column the publisher does not, so
# SELECT * could never match.
my $pub_rows = $node_publisher->safe_psql('postgres',
	"SELECT a, data FROM lost_delete_tab ORDER BY a");
my $sub_rows = $node_subscriber->safe_psql('postgres',
	"SELECT a, data FROM lost_delete_tab ORDER BY a");
is($sub_rows, $pub_rows,
	'subscriber converged with publisher after the raced delete');

# The conflict is real, so it must still be reported, with the type that
# describes what actually happened.
my $logfile = slurp_file($node_subscriber->logfile(), $log_location);
like(
	$logfile,
	qr/conflict detected on relation "public.lost_delete_tab": conflict=delete_origin_differs/,
	'raced delete reported as delete_origin_differs');

# And the row was never missing, so no missing-row conflict may be reported.
unlike($logfile, qr/conflict=delete_missing/,
	'no spurious delete_missing conflict reported');

done_testing();
