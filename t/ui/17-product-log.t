#! /usr/bin/perl

# Copyright (C) 2016-2017 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

BEGIN {
    unshift @INC, 'lib';
    $ENV{OPENQA_TEST_IPC} = 1;
}

use Mojo::Base;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Test::Mojo;
use Test::Warnings;

use OpenQA::Test::Case;
use OpenQA::Client;

use OpenQA::SeleniumTest;

OpenQA::Test::Case->new->init_data;

sub schema_hook {
    # simulate typo in START_AFTER_TEST to check for error message in this case
    my $schema     = OpenQA::Test::Database->new->create;
    my $test_suits = $schema->resultset('TestSuites');
    $test_suits->find(1017)->settings->find({key => 'START_AFTER_TEST'})->update({value => 'kda,textmode'});
}

my $driver = call_driver(\&schema_hook);
if (!$driver) {
    plan skip_all => $OpenQA::SeleniumTest::drivermissing;
    exit(0);
}

my $t = Test::Mojo->new('OpenQA::WebAPI');

# we need to talk to the phantom instance or else we're using wrong database
my $url = 'http://localhost:' . OpenQA::SeleniumTest::get_mojoport;

# Schedule iso - need UA change to add security headers
# XXX: Test::Mojo loses it's app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(
    OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

my $ret = $t->post_ok(
    $url . '/api/v1/isos',
    form => {
        ISO     => 'whatever.iso',
        DISTRI  => 'opensuse',
        VERSION => '13.1',
        FLAVOR  => 'DVD',
        ARCH    => 'i586',
        BUILD   => '0091'
    })->status_is(200);
is($ret->tx->res->json->{count}, 9, '9 new jobs created, 1 fails due to wrong START_AFTER_TEST');

$driver->get($url . '/admin/productlog');
like($driver->get_title(), qr/Scheduled products log/, 'on product log');
my $table = $driver->find_element_by_id('product_log_table');
ok($table, 'products tables present when not logged in');
my @rows = $driver->find_child_elements($table, './tbody/tr[./td[text() = "whatever.iso"]]', 'xpath');
is(scalar @rows, 1, 'one row present');
my @restart_buttons = $driver->find_elements('.iso_restart', 'css');
is(scalar @restart_buttons, 0, 'no restart buttons present when not logged in');

# Log in as Demo in phantomjs webui
$driver->find_element_by_link_text('Login')->click();
is($driver->find_element('#user-action a')->get_text(), 'Logged in as Demo', 'logged in as demo');

# Test Scheduled isos are displayed
$driver->find_element('#user-action a')->click();
$driver->find_element_by_link_text('Scheduled products')->click();
like($driver->get_title(), qr/Scheduled products log/, 'on product log');
$table = $driver->find_element_by_id('product_log_table');
ok($table, 'products tables found');
@rows = $driver->find_child_elements($table, './tbody/tr[./td[text() = "whatever.iso"]]', 'xpath');
my $nrows = scalar @rows;
my $row   = shift @rows;
my $cell  = $driver->find_child_element($row, './td[2]', 'xpath');
is($cell->get_text, 'opensuse', 'ISO scheduled for opensuse distri');
$cell = $driver->find_child_element($row, './td[8]/span', 'xpath');
like($cell->get_attribute('title'), qr/"ARCH": "i586"/, 'ISO data present');
$cell = $driver->find_child_element($row, './td[1]/a', 'xpath');
my ($id) = $cell->get_attribute('href') =~ m{$url/admin/auditlog\?eventid=(\d)};
ok($id, 'time is actually link to event id');

# Replay works for operator (perci)
$cell = $driver->find_child_element($row, './td[9]/a', 'xpath');
like($cell->get_attribute('href'), qr{$url/api/v1/isos}, 'replay action poinst to isos api route');
$cell->click();
wait_for_ajax;
like(
    $driver->find_element('#flash-messages span')->get_text(),
qr/ISO rescheduled - 9 new jobs but 1 failed\s*START_AFTER_TEST=kda:64bit not found - check for typos and dependency cycles/,
    'flash with error messages occurs'
);
$driver->refresh;
# refresh page
$driver->find_element('#user-action a')->click();
$driver->find_element_by_link_text('Scheduled products')->click();
like($driver->get_title(), qr/Scheduled products log/, 'on product log');
$table = $driver->find_element_by_id('product_log_table');
ok($table, 'products tables found');
@rows = $driver->find_child_elements($table, './tbody/tr[./td[text() = "whatever.iso"]]', 'xpath');
is(scalar @rows, $nrows + 1, 'iso rescheduled by replay action');

like(
    $driver->find_element_by_id('product_log_table_info')->get_text(),
    qr/Showing 1 to 2 of 2 entries/,
    'Info line shows number of entries'
);
$driver->get($url . '/admin/productlog?entries=1');
like(
    $driver->find_element_by_id('product_log_table_info')->get_text(),
    qr/Showing.*of 1 entries/,
    'Maximum number of entries can be configured by query'
);

kill_driver();

done_testing();
