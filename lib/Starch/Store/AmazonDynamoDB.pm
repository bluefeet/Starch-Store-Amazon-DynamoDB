package Starch::Store::AmazonDynamoDB;

=head1 NAME

Starch::Store::AmazonDynamoDB - Session storage backend using Amazon::DynamoDB.

=head1 SYNOPSIS

    my $starch = Starch->new(
        store => {
            class => '::AmazonDynamoDB',
            ddb => {
                implementation => 'Amazon::DynamoDB::LWP',
                version        => '20120810',
                
                access_key   => 'access_key',
                secret_key   => 'secret_key',
                # or you specify to use an IAM role
                use_iam_role => 1,
                
                host  => 'dynamodb.us-east-1.amazonaws.com',
                scope => 'us-east-1/dynamodb/aws4_request',
                ssl   => 1,
            },
        },
    );

=head1 DESCRIPTION

This Starch store uses L<Amazon::DynamoDB> to set and get session data.

=cut

use Amazon::DynamoDB;
use Types::Standard -types;
use Types::Common::String -types;
use Scalar::Util qw( blessed );
use Try::Tiny;
use Data::Serializer::Raw;
use Carp qw( croak );

use Moo;
use strictures 2;
use namespace::clean;

with qw(
    Starch::Store
);

sub BUILD {
  my ($self) = @_;

  # Get this loaded as early as possible.
  $self->ddb();

  return;
}

=head1 REQUIRED ARGUMENTS

=head2 ddb

This must be set to either hash ref arguments for L<Amazon::DynamoDB> or a
pre-built object (often retrieved using a
L<method proxy|Starch::Manual/METHOD PROXIES>).

When configuring Starch from static configuration files using a
L<method proxy|Starch::Manual/METHOD PROXIES>
is a good way to link your existing L<Amazon::DynamoDB> object
constructor in with Starch so that starch doesn't build its own.

=cut

has _ddb_arg => (
    is       => 'ro',
    isa      => HasMethods[ 'put_item', 'get_item', 'delete_item' ] | HashRef,
    init_arg => 'ddb',
    required => 1,
);

has ddb => (
    is       => 'lazy',
    isa      => HasMethods[ 'put_item', 'get_item', 'delete_item' ],
    init_arg => undef,
);
sub _build_ddb {
    my ($self) = @_;

    my $ddb = $self->_ddb_arg();
    return $ddb if blessed $ddb;

    return Amazon::DynamoDB->new( %$ddb );
}

=head1 OPTIONAL ARGUMENTS

=head2 consistent_read

When C<true> this sets the C<ConsistentRead> flag when calling
L<get_item> on the L</ddb>.  Defaults to C<true>.

=cut

has consistent_read => (
    is      => 'ro',
    isa     => Bool,
    default => 1,
);

=head2 serializer

A L<Data::Serializer::Raw> for serializing the session data for storage
in the L</data_field>.  Can be specified as string containing the
serializer name, a hashref of Data::Serializer::Raw arguments, or as a
pre-created Data::Serializer::Raw object.  Defaults to C<JSON>.

Consider using the C<JSON::XS> or C<Sereal> serializers for speed.

=cut

has _serializer_arg => (
    is       => 'ro',
    isa      => InstanceOf[ 'Data::Serializer::Raw' ] | HashRef | NonEmptySimpleStr,
    init_arg => 'serializer',
    default  => 'JSON',
);

has serializer => (
    is       => 'lazy',
    isa      => InstanceOf[ 'Data::Serializer::Raw' ],
    init_arg => undef,
);
sub _build_serializer {
    my ($self) = @_;

    my $serializer = $self->_serializer_arg();
    return $serializer if blessed $serializer;

    if (ref $serializer) {
        return Data::Serializer::Raw->new( %$serializer );
    }

    return Data::Serializer::Raw->new(
        serializer => $serializer,
    );
}

=head2 table

The DynamoDB table name where sessions are stored. Defaults to C<sessions>.

=cut

has table => (
    is      => 'ro',
    isa     => NonEmptySimpleStr,
    default => 'sessions',
);

=head2 key_field

The field in the L</table> where the session ID is stored.
Defaults to C<key>.

=cut

has key_field => (
    is      => 'ro',
    isa     => NonEmptySimpleStr,
    default => 'key',
);

=head2 expiration_field

The field in the L</table> which will hold the epoch
time when the session should be expired.  Defaults to C<expiration>.

=cut

has expiration_field => (
    is      => 'ro',
    isa     => NonEmptySimpleStr,
    default => 'expiration',
);

=head2 data_field

The field in the L</table> which will hold the
session data.  Defaults to C<data>.

=cut

has data_field => (
    is      => 'ro',
    isa     => NonEmptySimpleStr,
    default => 'data',
);

=head1 ATTRIBUTES

=head1 reap_scan_filter

Returns the data structure used for the C<ScanFilter> argument when
scanning for session to reap.  This ScanFilter will find all sessions
which have an L</expiration_field> less than the current time.

=cut

sub reap_scan_filter {
    my ($self) = @_;

    return {
        $self->expiration_field() => {
            ComparisonOperator => 'LT',
            AttributeValueList => time(),
        },
    };
}

=head1 METHODS

=head2 reap_expired

=cut

sub can_reap_expired { 1 }

sub reap_expired {
    my ($self) = @_;

    my $ddb = $self->ddb();
    my $table = $self->table();
    my $key_field = $self->key_field();

    my @keys;

    $self->log->infof(
        'Scanning DynamoDB for expired sessions in the %s table.',
        $table,
    );

    try {
        $ddb->scan(
            sub {
                my ($record) = @_;
                push @keys, $record->{ $key_field };
            },
            TableName       => $table,
            AttributesToGet => [ $key_field ],
            ScanFilter      => $self->reap_scan_filter(),
        )->get();
    }
    catch {
        $self->_throw_ddb_error( 'scan', $_ )
    };

    if (!@keys) {
        $self->log->infof('No expired sessions found in DynamoDB.');
        return;
    }

    $self->log->infof(
        'Deleting %d expired sessions in DynamoDB.',
        @keys + 0,
    );

    try {
        $ddb->batch_write_item(
            RequestItems => {
                $table => [
                    map { {
                        DeleteRequest => {
                            Key => { $key_field => $_ },
                        },
                    } }
                    @keys
                ],
            },
        )->get();
    }
    catch {
        $self->_throw_ddb_error( 'batch_write_item', $_ )
    };

    $self->log->infof(
        'Finished deleting %d expired sessions from DynamoDB.',
        @keys + 0,
    );

    return;
}

=head2 create_table_args

Returns the appropriate arguments to use for calling C<create_table>
on the L</ddb> object.  By default it will look like this:

    {
        TableName => 'sessions',
        ReadCapacityUnits => 10,
        WriteCapacityUnits => 10,
        AttributeDefinitions => { key => 'S' },
        KeySchema => [ 'key' ],
    }

Any arguments you pass will override those in the returned arguments.

=cut

sub create_table_args {
    my $self = shift;

    my $key_field = $self->key_field();

    return {
        TableName => $self->table(),
        ReadCapacityUnits => 10,
        WriteCapacityUnits => 10,
        AttributeDefinitions => {
            $key_field => 'S',
        },
        KeySchema => [ $key_field ],
        @_,
    };
}

=head2 create_table

Creates the L</table> by passing any arguments to L</create_table_args>
and issueing the C<create_table> command on the L</ddb> object.

=cut

sub create_table {
    my $self = shift;

    my $args = $self->create_table_args( @_ );

    my $f = $self->ddb->create_table( %$args );

    my $create_errored;
    try { $f->get() }
    catch { $self->_throw_ddb_error( 'create_table', $_ ); $create_errored=1 };

    return if $create_errored;

    $f = $self->ddb->wait_for_table_status(
        TableName => $args->{TableName},
    );

    try { $f->get() }
    catch { $self->_throw_ddb_error( 'wait_for_table_status', $_ ) };

    return;
}

sub _throw_ddb_error {
    my ($self, $method, $error) = @_;

    local $Carp::Internal{ (__PACKAGE__) } = 1;

    my $context = "Amazon::DynamoDB::$method";

    if (!ref $error) {
        $error = 'UNDEFINED' if !defined $error;
        croak "$context Unknown Error: $error";
    }

    elsif (ref($error) eq 'HASH' and defined($error->{message})) {
        if (defined($error->{type})) {
            croak "$context: $error->{type}: $error->{message}";
        }
        else {
            croak "$context: $error->{message}";
        }
    }

    require Data::Dumper;
    croak "$context Unknown Error: " . Data::Dumper::Dumper( $error );
}

=head2 set

Set L<Starch::Store/set>.

=head2 get

Set L<Starch::Store/get>.

=head2 remove

Set L<Starch::Store/remove>.

=cut

sub set {
    my ($self, $key, $data, $expires) = @_;

    $expires += time() if $expires;

    my $serializer = $self->serializer();

    my $raw = $serializer->serialize( $data );

    my $f = $self->ddb->put_item(
        TableName => $self->table(),
        Item => {
            $self->key_field()        => $key,
            $self->expiration_field() => $expires,
            defined($raw) ? ($self->data_field() => $raw) : (),
        },
    );

    try { $f->get() }
    catch { $self->_throw_ddb_error( 'put_item', $_ ) };

    return;
}

sub get {
    my ($self, $key) = @_;

    my $record;
    my $f = $self->ddb->get_item(
        sub{ $record = shift },
        TableName => $self->table(),
        Key => {
            $self->key_field() => $key,
        },
        AttributesToGet => [ $self->data_field() ],
        ConsistentRead  => ($self->consistent_read() ? 'true' : 'false'),
    );

    try { $f->get() }
    catch { $self->_throw_ddb_error( 'get_item', $_ ) };

    return undef if !$record;

    my $raw = $record->{data};
    return undef if !defined $raw;

    my $serializer = $self->serializer();

    return $self->serializer->deserialize( $raw );
}

sub remove {
    my ($self, $key) = @_;

    my $f = $self->ddb->delete_item(
        TableName => $self->table(),
        Key => {
            $self->key_field() => $key,
        },
    );

    try { $f->get() }
    catch { $self->_throw_ddb_error( 'delete_item', $_ ) };

    return;
}

1;
__END__

=head1 AUTHOR

Aran Clary Deltac <bluefeetE<64>gmail.com>

=head1 ACKNOWLEDGEMENTS

Thanks to L<ZipRecruiter|https://www.ziprecruiter.com/>
for encouraging their employees to contribute back to the open
source ecosystem.  Without their dedication to quality software
development this distribution would not exist.

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

