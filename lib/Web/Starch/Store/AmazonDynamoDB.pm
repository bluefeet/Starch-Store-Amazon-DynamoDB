package Web::Starch::Store::AmazonDynamoDB;

=head1 NAME

Web::Starch::Store::AmazonDynamoDB - Session storage backend using Amazon::DynamoDB.

=head1 SYNOPSIS

    my $starch = Web::Starch->new(
        store => {
            class => '::AmazonDynamoDB',
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
    );

=head1 DESCRIPTION

This Starch store uses L<Amazon::DynamoDB> to set and get session data.

=head1 CONSTRUCTOR

The arguments to this class are automatically shifted into the
L</dynamodb> argument if the L</dynamodb> argument is not specified. So,

    store => {
        class          => '::AmazonDynamoDB',
        implementation => 'Amazon::DynamoDB::LWP',
        version        => '20120810',
    },

Is the same as:

    store => {
        class  => '::AmazonDynamoDB',
        dynamodb => {
            implementation => 'Amazon::DynamoDB::LWP',
            version        => '20120810',
        },
    },

Also, don't forget about method proxies which allow you to build
the L<Amazon::DynamoDB> object using your own code but still specify a static
configuration.  The below is equivelent to the previous two examples:

    package MyDynamoDB;
    sub get_dynamodb {
        my ($class) = @_;
        return Amazon::DynamoDB->new(
            implementation => 'Amazon::DynamoDB::LWP',
            version        => '20120810',
        );
    }

    store => {
        class  => '::AmazonDynamoDB',
        chi => [ '&proxy', 'MyDynamoDB', 'get_dynamodb' ],
    },

You can read more about method proxies at
L<Web::Starch::Manual/METHOD PROXIES>.

=cut

use Amazon::DynamoDB;
use Types::Standard -types;
use Types::Common::String -types;
use Scalar::Util qw( blessed );

use Moo;
use strictures 2;
use namespace::clean;

with qw(
    Web::Starch::Store
);

around BUILDARGS => sub{
    my $orig = shift;
    my $self = shift;

    my $args = $self->$orig( @_ );
    return $args if exists $args->{dynamodb};

    my $dynamodb = $args;
    $args = { dynamodb=>$dynamodb };
    $args->{factory} = delete( $dynamodb->{factory} );
    $args->{max_expires} = delete( $dynamodb->{max_expires} ) if exists $dynamodb->{max_expires};

    return $args;
};

sub BUILD {
  my ($self) = @_;

  # Get this loaded as early as possible.
  $self->dynamodb();

  return;
}

=head1 REQUIRED ARGUMENTS

=head2 dynamodb

This must be set to either hash ref arguments for L<Amazon::DynamoDB> or a
pre-built object (often retrieved using a method proxy).

When configuring Starch from static configuration files using a
method proxy is a good way to link your existing L<Amazon::DynamoDB>
object constructor in with Starch so that starch doesn't build its own.

=cut

has _dynamodb_arg => (
    is       => 'ro',
    isa      => InstanceOf[ 'Amazon::DynamoDB' ] | HashRef,
    init_arg => 'dynamodb',
    required => 1,
);

has dynamodb => (
    is       => 'lazy',
    isa      => InstanceOf[ 'Amazon::DynamoDB' ],
    init_arg => undef,
);
sub _build_dynamodb {
    my ($self) = @_;

    my $dynamodb = $self->_dynamodb_arg();
    return $dynamodb if blessed $dynamodb;

    return Amazon::DynamoDB->new( %$dynamodb );
}

=head1 OPTIONAL ARGUMENTS

=head2 session_table

The DynamoDB table name where sessions are stored.
Defaults to C<sessions>.

=cut

has session_table => (
    is      => 'ro',
    isa     => NonEmptySimpleString,
    default => 'sessions',
);

=head2 id_field

The field in the L</session_table> where the session ID is stored.
Defaults to C<id>.

=cut

has id_field => (
    is      => 'ro',
    isa     => NonEmptySimpleString,
    default => 'id',
);

=head2 expiration_field

The field in the L</session_table> which will hold the epoch
time when the session should be expired.
Defaults to C<expiration>.

=cut

has expiration_field => (
    is      => 'ro',
    isa     => NonEmptySimpleString,
    default => 'expiration',
);

=head1 STORE METHODS

See L<Web::Starch::Store> for more documentation about the methods
which all stores implement.

=cut

sub set {
    my ($self, $id, $data, $expires) = @_;

    $self->dynamodb->put_item(
        TableName => $self->session_table(),
        Item => {
            $self->id_field() => $id,
            $self->expiration_field() => time() + $expires,
            data => $data,
        },
    )->get();

    return;
}

sub get {
    my ($self, $id) = @_;

    my $data;
    $self->dynamodb->get_item(
        sub{ $data = shift },
        TableName => $self->session_table(),
        Key => {
            $self->id_field() => $id,
        },
    )->get();

    return $data;
}

sub remove {
    my ($self, $id) = @_;

    $self->dynamodb->delete_item(
        TableName => $self->session_table(),
        Key => {
            $self->id_field() => $id,
        },
    )->get();

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

