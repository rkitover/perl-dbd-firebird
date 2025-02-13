#!/usr/local/bin/perl -w
#
#

# test cases:
# event creation, register callback, cancel callback
# event creation, fork / thread (except win32), destruction
# event creation, fork / thread (except win32), wait event, destruction
# event creation, fork / thread (except win32), register callback, destruction

use strict;
use warnings;

use Data::Dumper;

use DBI;
use Config;
use Test::More;
use lib 't','.';

plan skip_all => 'DBD_FIREBIRD_TEST_SKIP_EVENTS found in the environment'
    if $ENV{DBD_FIREBIRD_TEST_SKIP_EVENTS};

use TestFirebird;
my $T = TestFirebird->new;

my ($dbh, $error_str) = $T->connect_to_database;

my ( $test_dsn, $test_user, $test_password ) =
  ( $T->{tdsn}, $T->{user}, $T->{pass} );

if ($error_str) {
    BAIL_OUT("Error! $error_str!");
}

unless ( $dbh->isa('DBI::db') ) {
    plan skip_all => 'Connection to database failed, cannot continue testing';
}
else {
    plan tests => 22;
}

ok($dbh, 'Connected to the database');

my $table = find_new_table($dbh);
ok($table, qq{Table is '$table'});

# create required test table and triggers
{
    my @ddl = (<<"DDL", <<"DDL", <<"DDL");
CREATE TABLE $table (
    id    INTEGER NOT NULL,
    title VARCHAR(255) NOT NULL
);
DDL

CREATE TRIGGER ins_${table}_trig FOR $table
    AFTER INSERT POSITION 0
    AS BEGIN
        POST_EVENT 'foo_inserted';
    END
DDL

CREATE TRIGGER del_${table}_trig FOR $table
    AFTER DELETE POSITION 0
    AS BEGIN
        POST_EVENT 'foo_deleted';
    END
DDL

    ok($dbh->do($_)) foreach @ddl; # 3 times
}

my $evh = $dbh->func('foo_inserted', 'foo_deleted', 'ib_init_event');
ok($evh);

ok($dbh->func($evh, sub { print "about to cancel"; 1 }, 'ib_register_callback'));
ok($dbh->func($evh, 'ib_cancel_callback'));

my $worker = sub {
    my $table = shift;
    my $dbh = DBI->connect(@_, {AutoCommit => 1 }) or return 0;
    for (1..5) {
        $dbh->do(qq{INSERT INTO $table VALUES($_, 'bar')});
    }
    $dbh->do(qq{DELETE FROM $table});
    $dbh->disconnect;
};

# try ithreads
{
    my $how_many = 10;
SKIP: {
    skip "this $^O perl $] is not configured to support iThreads", $how_many if (!$Config{useithreads} || $] < 5.008);
    skip "known problems under MSWin32 ActivePerl's iThreads", $how_many if $Config{osname} eq 'MSWin32';
    skip "Perl version is older than 5.8.8", $how_many if $^V and $^V lt v5.8.8;
    eval { require threads };
    skip "unable to use threads;", $how_many if $@;

    %::CNT = ();

    ok($dbh->func($evh,
        sub {
            my $posted_events = shift;
            while (my ($k, $v) = each %$posted_events) {
                $::CNT{$k} += $v;
            }
            1;
        },
        'ib_register_callback'
    ));

    my $t = threads->create($worker, $table, $test_dsn, $test_user, $test_password);
    ok($t);
    ok($t->join);

    while (not exists $::CNT{'foo_deleted'}) {}
    ok($dbh->func($evh, 'ib_cancel_callback'));
    is($::CNT{'foo_inserted'}, 5);
    is($::CNT{'foo_deleted'}, 5);

    # test ib_wait_event
    %::CNT = ();
    $t = threads->create($worker, $table, $test_dsn, $test_user, $test_password);
    ok($t, "create thread");
    for (1..6) {
        my $posted_events = $dbh->func($evh, 'ib_wait_event');
        while (my ($k, $v) = each %$posted_events) {
            $::CNT{$k} += $v;
        }
    }
    ok($t->join);
    is($::CNT{'foo_inserted'}, 5);
    is($::CNT{'foo_deleted'}, 5);
}}

ok($dbh->do(qq(DROP TRIGGER ins_${table}_trig)));
ok($dbh->do(qq(DROP TRIGGER del_${table}_trig)));
ok($dbh->do(qq(DROP TABLE $table)));
ok($dbh->disconnect);
