#!/usr/bin/env perl
use strictures 2;

use Test::More;
use Try::Tiny;

if (!$ENV{TEST_DYNAMODB}) {
    plan skip_all => 'Run a Local DynamoDB and set TEST_DYNAMODB=1 to run this test.';
}

use Web::Starch;

my $starch = Web::Starch->new_with_plugins(
    ['::TimeoutStores'],
    store => {
        class  => '::AmazonDynamoDB',
        session_table => "sessions_$$",
        timeout => 1,
        ddb => {
            implementation => 'Amazon::DynamoDB::LWP',
            version        => '20120810',
            access_key     => 'access_key',
            secret_key     => 'secret_key',
            host  => 'localhost',
            port  => 8000,
            scope => 'us-east-1/dynamodb/aws4_request',
        },
    },
);

my $store = $starch->store();

$store->create_table();

is( $store->get('foo'), undef, 'get an unknown key' );

$store->set( 'foo', {bar=>6}, 0 );
isnt( $store->get('foo'), undef, 'add, then get a known key' );
is( $store->get('foo')->{bar}, 6, 'known key data value' );

$store->set( 'foo', {bar=>3}, 10 );
is( $store->get('foo')->{bar}, 3, 'update, then get a known key' );

$store->remove( 'foo' );
is( $store->get('foo'), undef, 'get a removed key' );

done_testing();
