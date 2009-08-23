# TODO: Find out why DBI croaks under PerlSvc when DBD::Wire10 and Net::Wire10
#       files are in UTF-8 (with BOM), this prevents using Unicode for the POD docs.

# TODO: Put in a place where people expect to find this driver, maybe alias
#       under package names matching the supported database systems?
#       (DBD::MySQL::Wire10, DBD::Sphinx::Wire10, DBD::Drizzle::Wire10 etc)

package DBD::Wire10;

use strict;
use warnings;
use DBI;
use vars qw($VERSION $err $errstr $state $drh);

$VERSION = '1.02';
$err = 0;
$errstr = '';
$state = undef;
$drh = undef;

our $methods_already_installed = 0;

sub driver {
	return $drh if $drh;

	my $class = shift;
	my $attr  = shift;
	$class .= '::dr';

	# TODO: core->ping() + core->connect() useful as a generic mechanism
	unless ($methods_already_installed++) {
		eval {
			my $method = "DBI::db::reconnect";
			my $file = "__FILENAME__";
			my $info = {};
			DBI->_install_method($method, $file, $info);
		};
		warn "Failed to register reconnect method: $@" if $@;
	}

	$drh = DBI::_new_drh($class, {
		Name        => 'Wire10',
		Version     => $VERSION,
		Attribution => 'DBD::Wire10, see AUTHOR',
	}, {});
	return $drh;
}

sub CLONE {
	undef $drh;
}

# TODO: Is there a shrinkwrapped function to do this
sub _parse_dsn {
	my $class = shift;
	my ($dsn, $args) = @_;
	my ($hash, $var, $val);
	return undef if ! defined $dsn;

	while (length $dsn) {
		if ($dsn =~ /([^:;]*)[:;](.*)/) {
			$val = $1;
			$dsn = $2;
		} else {
			$val = $dsn;
			$dsn = '';
		}
		if ($val =~ /([^=]*)=(.*)/) {
			$var = $1;
			$val = $2;
			if ($var eq 'hostname' || $var eq 'host') {
				$hash->{host} = $val;
			} elsif ($var eq 'db' || $var eq 'dbname') {
				$hash->{database} = $val;
			} else {
				$hash->{$var} = $val;
			}
		} else {
			for $var (@$args) {
				if (! defined($hash->{$var})) {
					$hash->{$var} = $val;
					last;
				}
			}
		}
	}
	return $hash;
}

sub _parse_dsn_host {
	my ($class, $dsn) = @_;
	my $hash = $class->_parse_dsn($dsn, ['host', 'port']);
	return ($hash->{host}, $hash->{port});
}



package DBD::Wire10::dr;

use strict;
use warnings;
use Net::Wire10;

# TODO: Add support for take_imp_data() and connect({dbi_imp_data=>...}).
#       AFAICT, these are only supported for native C drivers at the moment.
$DBD::Wire10::dr::imp_data_size = 0;

sub connect {
	my $drh = shift;
	my ($dsn, $user, $password, $attrhash) = @_;

	my $data_source_info = DBD::Wire10->_parse_dsn(
		$dsn, ['database', 'host', 'port'],
	);
	$user     ||= '';
	$password ||= '';

	my $dbh = DBI::_new_dbh($drh, { Name => $dsn });
	eval {
		my $wire = Net::Wire10->new(
			host     => $data_source_info->{host},
			port     => $data_source_info->{port},
			database => $data_source_info->{database},
			user     => $user,
			password => $password,
			debug    => $attrhash->{wire10_debug} || undef,
			timeout  => $attrhash->{wire10_timeout} || undef,
		);
		$wire->connect;
		$dbh->STORE('wire10_driver_dbh', $wire);
		$dbh->STORE('wire10_thread_id', $wire->{server_thread_id});
		$dbh->STORE('wire10_server_version', $wire->{server_version});
	};
	if ($@) {
		$dbh->DBI::set_err(-1, $@);
		return undef;
	}
	$dbh->STORE('Active', 1);
	return $dbh;
}

sub data_sources {
	return ("DBI:Wire10:");
}



package DBD::Wire10::db;

use strict;
use warnings;

$DBD::Wire10::db::imp_data_size = 0;

sub quote {
	my $dbh = shift;
	my ($statement, $type) = @_;
	return Net::Wire10::Util::quote($statement);
}

sub quote_identifier {
	my $dbh = shift;
	my $name = shift;
	return Net::Wire10::Util::quote_identifier($name);
}

sub prepare {
	my $dbh = shift;
	my ($statement, @attribs) = @_;
	my $wire = $dbh->FETCH('wire10_driver_dbh');

	my $sth;
	eval {
		$sth = DBI::_new_sth($dbh, {Statement => $statement});
		DBD::Wire10::st::_constructor($sth, $wire, $statement);
	};
	if ($@) {
		$dbh->DBI::set_err(-1, $@);
		return undef;
	}
	return $sth;
}

sub STORE {
	my $dbh = shift;
	my ($key, $value) = @_;

	if ($key =~ /^AutoCommit$/) {
		my $wire = $dbh->FETCH('wire10_driver_dbh');
		$wire->query("SET AUTOCOMMIT=".$value);
		# Can't store as AutoCommit via SUPER::STORE, not sure why.
		$dbh->STORE('wire10_autocommit', $value);
		return 1;
	}

	if ($key =~ /^(?:wire10_timeout)$/) {
		my $wire = $dbh->FETCH('wire10_driver_dbh');
		$wire->{timeout} = $value;
		return 1;
	}

	if ($key =~ /^(?:wire10_debug)$/) {
		my $wire = $dbh->FETCH('wire10_driver_dbh');
		$wire->{debug} = $value;
		return 1;
	}

	if ($key =~ /^(?:wire10_.*)$/) {
		$dbh->{$key} = $value;
		return 1;
	}

	return $dbh->SUPER::STORE($key, $value);
}

sub FETCH {
	my $dbh = shift;
	my $key = shift;

	if ($key =~ /^(?:wire10_timeout)$/) {
		my $wire = $dbh->FETCH('wire10_driver_dbh');
		return $wire->{timeout};
	}
	if ($key =~ /^(?:wire10_debug)$/) {
		my $wire = $dbh->FETCH('wire10_driver_dbh');
		return $wire->{debug};
	}

	if ($key =~ /^AutoCommit$/) {
		# See comment in STORE.
		return $dbh->FETCH('wire10_autocommit');
	}

	return $dbh->{$key} if $key =~ /^(?:wire10_.*)$/;
	return $dbh->SUPER::FETCH($key);
}

sub commit {
	my $dbh = shift;

	if ($dbh->FETCH('AutoCommit')) {
		if ($dbh->FETCH('Warn')) {
			warn 'Commit ineffective while AutoCommit is on';
		}
	}

	my $wire = $dbh->FETCH('wire10_driver_dbh');
	$wire->query("COMMIT");

	return 1;
}

sub rollback {
	my $dbh = shift;

	if ($dbh->FETCH('AutoCommit')) {
		if ($dbh->FETCH('Warn')) {
			warn 'Rollback ineffective while AutoCommit is on';
		}
	}

	my $wire = $dbh->FETCH('wire10_driver_dbh');
	$wire->query("ROLLBACK");

	return 1;
}

sub ping {
	my $dbh = shift;
	my $wire = $dbh->FETCH('wire10_driver_dbh');

	eval {
		$wire->ping;
	};

	if ($wire->is_error) {
		$dbh->DBI::set_err($wire->get_error_code || -1, $wire->get_error_message, $wire->get_error_state);
	} elsif ($@) {
		$dbh->DBI::set_err(-1, $@);
	}

	return $wire->is_connected;
}

sub reconnect {
	my $dbh = shift;
	my $wire = $dbh->FETCH('wire10_driver_dbh');

	if ($wire->is_connected) {
		eval {
			$wire->ping;
		};
	}
	# ping() also sets is_connected, unnecessary to check ping return value.
	if (not $wire->is_connected) {
		eval {
			$wire->connect;
			# The below is copy/paste from the drh connect() call. 
			$dbh->STORE('wire10_thread_id', $wire->{server_thread_id});
			$dbh->STORE('wire10_server_version', $wire->{server_version});
			$dbh->STORE('Active', 1);
			$dbh->STORE('AutoCommit', $dbh->FETCH('AutoCommit'));
		};
		if ($wire->is_error) {
			$dbh->DBI::set_err($wire->get_error_code || -1, $wire->get_error_message, $wire->get_error_state);
			return 0;
		} elsif ($@) {
			$dbh->DBI::set_err(-1, $@);
			return 0;
		}
	}
	return 1;
}

sub disconnect {
	my $dbh = shift;
	my $wire = $dbh->FETCH('wire10_driver_dbh');
	$wire->disconnect;
	$dbh->STORE('wire10_thread_id', undef);
	$dbh->STORE('Active', 0);
	return 1;
}

sub DESTROY {
	my $dbh = shift;
	$dbh->disconnect if $dbh->FETCH('Active');
	$dbh->SUPER::DESTROY;
}

sub get_info {
	my $dbh = shift;
	my $type = shift;
	# 17: SQL_DBMS_NAME
	# Difficult to return something intelligent here, the server
	# only reports a version, not a daemon name in the handshake
	# packet.  A SELECT could be constructed to reveal the server
	# type, if necessary.
	return 'Wire10' if $type == 17;
	# 18: SQL_DBMS_VER
	return $dbh->FETCH('wire10_server_version') if $type == 18;
	# 29: SQL_IDENTIFIER_QUOTE_CHAR
	return '`' if $type == 29;
	# 41: SQL_CATALOG_NAME_SEPARATOR
	return '.' if $type == 41;
	# 114: SQL_CATALOG_LOCATION
	# According to MSDN, 0 means "catalog not supported" which is accurate.
	# (The server happily accepts, discards and prints a catalog named
	#  'def', though.)
	return 0 if $type == 114;
	# Unknown/unsupported attribute.
	return undef;
}



package DBD::Wire10::st;

use strict;
use warnings;
use DBI qw(:sql_types);

$DBD::Wire10::st::imp_data_size = 0;

# TODO: Find out if DBI already calls a DBD st constructor somewhere
sub _constructor {
	my $sth = shift;
	my $wire = shift;
	my $sql = shift;

	my $ps = $wire->prepare($sql);

	# Store driver handle and prepared statement for later.
	$sth->STORE('wire10_driver_sth', $wire);
	$sth->STORE('wire10_prepared', $ps);
	$sth->STORE('NUM_OF_PARAMS', $ps->get_marker_count);
}

sub bind_param {
	my $sth = shift;
	my ($index, $value, $attr) = @_;
	my $binary = _test_for_binary_flag($sth, $attr);
	my $ps = $sth->FETCH('wire10_prepared');
	$ps->set_parameter($index, $value, $binary);
	return 1;
}

sub _test_for_binary_flag {
	my $sth = shift;
	my $attr = shift;
	return 0 unless defined $attr;
	my $binary = Net::Wire10::DATA_BINARY;
	my $text = Net::Wire10::DATA_TEXT;
	my $sqltype;
	# May be undefined.
	$sqltype = $attr if ref($attr) eq '';
	$sqltype = $attr->{TYPE} if ref($attr) eq 'HASH';
	if (defined $sqltype) {
		return $binary if $sqltype == SQL_BINARY;
		return $binary if $sqltype == SQL_VARBINARY;
		return $binary if $sqltype == SQL_LONGVARBINARY;
		return $binary if $sqltype == SQL_BLOB;
	}
	# For testing Oracle-based code with MySQL.
	# ORA_BLOB is 113, defined in Oracle.h.
	my $oratype;
	$oratype = $attr->{ora_type} if ref($attr) eq 'HASH';
	return $binary if defined $oratype and $oratype == 113;
	return $text;
}

sub execute {
	my $sth = shift;
	my @new_params = @_;
	my $dbh = $sth->{Database};
	my $wire = $sth->FETCH('wire10_driver_sth');
	my $ps = $sth->FETCH('wire10_prepared');

	unless (defined($ps)) {
		$sth->DBI::set_err(-1, "execute without prepare");
		return undef;
	}

	if (scalar(@new_params) > 0) {
		$ps->clear_parameter;
		my $i = 1;
		foreach my $p (@new_params) {
			$ps->set_parameter($i++, $p, 0);
		}
	}

	my $rowcount = eval {
		$sth->finish;
		my $res = $ps->query;

		die if $wire->is_error;

		$sth->STORE('wire10_warning_count', $res->get_warning_count);
		# For backward compatibility and/or do(), store in dbh too.
		my $dbh = $sth->{Database};
		$dbh->STORE('wire10_warning_count', $res->get_warning_count);

		if ($res->has_results) {
			$sth->{wire10_iterator} = $res;
			$sth->STORE('NUM_OF_FIELDS', $res->get_no_of_columns);
			$sth->STORE('NAME', [ $res->get_column_names ]);
			# DBI docs says this is important
			# for bind_columns and bind_cols.
			$sth->STORE('Active', 1);
			# DBI docs say set this to -1.
			$sth->{wire10_rows} = -1;
			$sth->STORE('wire10_selectedrows', $res->get_no_of_selected_rows);
			# For backward compatibility and/or do(), store in dbh too.
			$dbh->STORE('wire10_selectedrows', $res->get_no_of_selected_rows);
		} else {
			$sth->{wire10_iterator} = undef;
			$sth->STORE('NUM_OF_FIELDS', 0);
			$sth->STORE('NAME', []);
			$sth->{wire10_rows} = $res->get_no_of_affected_rows;
			$sth->STORE('wire10_insertid', $res->get_insert_id);
			# For backward compatibility and/or do(), store in dbh too.
			$dbh->STORE('wire10_insertid', $res->get_insert_id);
		}
		return $res->get_no_of_affected_rows;
	};

	if ($wire->is_error) {
		$sth->DBI::set_err($wire->get_error_code || -1, $wire->get_error_message, $wire->get_error_state);
		return undef;
	} elsif ($@) {
		$sth->DBI::set_err(-1, $@);
		return undef;
	}

	return $rowcount ? $rowcount : '0E0';
}

sub cancel {
	my $sth = shift;
	my $wire = $sth->FETCH('wire10_driver_sth');

	eval {
		$wire->cancel;
	};

	if ($@) {
		$sth->DBI::set_err(-1, $@);
		return undef;
	}

	return 1;
}

sub finish {
	my $sth = shift;
	my $dbh = $sth->{Database};
	# Always working in non-streaming mode, so no need to flush.
	$sth->{wire10_iterator} = undef;
	$sth->STORE('Active', 0);
	$sth->SUPER::finish();
}

sub fetchrow_arrayref {
	my $sth = shift;

	my $iterator = $sth->FETCH('wire10_iterator');
	unless ($iterator) {
		if ($sth->FETCH('Warn')) {
			warn 'fetch() without execute(), previous execute() failed, executed query does not have results, or last row was already fetched';
		}
		return undef;
	}

	my $row = undef;
	eval {
		$row = $iterator->next_array;
	};
	if ($@) {
		$sth->DBI::set_err(-1, $@);
		return undef;
	}
	if (! $row) {
		$sth->finish;
		return undef;
	}

	if ($sth->FETCH('ChopBlanks')) {
		map {s/\s+$//} @$row;
	}

	return $sth->_set_fbav($row);
}

# required alias for fetchrow_arrayref
*fetch = \&fetchrow_arrayref;

sub rows {
	my $sth = shift;
	my $rows = $sth->FETCH('wire10_rows');
	return $rows unless $rows == -1;
	return $sth->SUPER::rows;
}

sub FETCH {
	my $sth = shift;
	my $key = shift;

	return $sth->{NAME} if $key eq 'NAME';
	return $sth->{$key} if $key =~ /^wire10_/;
	return $sth->SUPER::FETCH($key);
}

sub STORE {
	my $sth = shift;
	my ($key, $value) = @_;

	if ($key eq 'NAME') {
		$sth->{NAME} = $value;
		return 1;
	}
	if ($key =~ /^wire10_/) {
		$sth->{$key} = $value;
		return 1;
	}

	return $sth->SUPER::STORE($key, $value);
}

sub DESTROY {
	my $sth = shift;
	$sth->finish if $sth->FETCH('Active');
	$sth->SUPER::DESTROY;
}



1;
__END__

=pod

=head1 NAME

DBD::Wire10 - Pure Perl MySQL, Sphinx, and Drizzle driver for DBI.

=head1 DESCRIPTION

C<DBD::Wire10> is a Pure Perl interface able to connect to MySQL, Sphinx and Drizzle servers, utilizing L<Net::Wire10> for the actual driver core.

=head1 SYNOPSIS

  use DBI;

  $drh = DBI->install_driver("wire10");

  $dsn = "DBI:Wire10:database=$database;host=$host";

  $dbh = DBI->connect($dsn, $user, $password);

  $sth = $dbh->prepare("SELECT * FROM foo WHERE bar=1");
  $sth->execute;
  $numCols = $sth->{NUM_OF_FIELDS};
  $numRows = $sth->{wire10_selectedrows};
  $sth->finish;

  $sth = $dbh->prepare("UPDATE foo SET bar=0 WHERE bar=1");
  $sth->execute;
  $numRows = $sth->rows;
  $sth->finish;

=head1 INSTALLATION

DBD::Wire10 is installed like any other CPAN module:

  $ perl -MCPAN -e shell
  cpan> install DBD::Wire10

For Perl installations where the CPAN module (used above) is missing, you can also just download the .tar.gz from this site and drop the B<DBD> folder in the same folder as the Perl file you want to use the connector from.

Some (particularly commercial) Perl distributions may have their own package management systems.  Refer to the documentation that comes with your particular Perl distribution for details.

=head1 USAGE

From Perl you just need to make use of DBI to get started:

  use DBI;

After that you can connect to servers and send queries via a simple object oriented interface.  Two types of objects are mainly used: database handles and statement handles.  DBI returns a database handle via the connect() method.

=head2 Example: connect

  use DBI;

  my $host = 'localhost';
  my $user = 'test';
  my $password = 'test';

  # Connect to the database server on 'localhost'.
  my $dbh = DBI->connect(
    "DBI:Wire10:host=$host",
    $user, $password,
    {RaiseError' => 1, 'AutoCommit' => 1}
  );

=head2 Example: create table

  # Drop table 'foo'. This may fail, if 'foo' doesn't exist.
  # Thus we put an eval around it.
  eval { $dbh->do("DROP TABLE foo") };
  print "Dropping foo failed: $@\n" if $@;

  # Create a new table 'foo'. If this fails, we don't want to
  # continue, thus we don't catch errors.
  $dbh->do("CREATE TABLE foo (id INTEGER, name VARCHAR(20))");

=head2 Example: insert data

  # INSERT some data into 'foo'. We are using $dbh->quote() for
  # quoting the name.
  $dbh->do("INSERT INTO foo VALUES (1, " . $dbh->quote("Tim") . ")");

  # Same thing, but using placeholders
  $dbh->do("INSERT INTO foo VALUES (?, ?)", undef, 2, "Jochen");

=head2 Example: retrieve data

  # Now retrieve data from the table.
  my $sth = $dbh->prepare("SELECT id, name FROM foo");
  $sth->execute();
  while (my $ref = $sth->fetchrow_arrayref()) {
    print "Found a row: id = $ref->[0], name = $ref->[1]\n";
  }
  $sth->finish();

=head2 Example: disconnect

  # Disconnect from the database server.
  $dbh->disconnect();

=head1 FEATURES

The following DBI features are supported.

=head2 Features in C<DBD::Wire10>

=head3 I<Driver factory>: methods

Methods available from the C<DBD::Wire10> driver factory.

=head4 driver (internal)

Creates a new driver.

=head4 CLONE (internal)

Helper that decouples non-shareable driver internals when the application needs to create a new process using fork().

=head2 Features in C<DBD::Wire10::dr>

=head3 I<Driver>: methods

=head4 connect

Creates a new driver core and dbh object, returns the dbh object.

A DSN is specified in the usual format and connect() is called via DBI:

  my $dsn = "DBI:Wire10:database=$database;host=$host;port=$port";
  my $options = {'RaiseError'=>1, 'Warn'=>1};
  my $dbh = DBI->connect($dsn, $user, $password, $options);

The default port numbers are 3306 for MySQL Server, 3307 for Sphinx and 4427 for Drizzle.  Some server types support multiple protocols, in which case they may also listen on other, unrelated ports.

C<wire10_debug> can be specified in the attribute hash for very noise debug output.  It is a bitmask, where 1 shows normal debug messages, 2 shows messages flowing back and forth between client and server, and 4 shows raw TCP traffic.

C<wire10_timeout> can be specified in the attribute hash to set a connect and query timeout.  Otherwise, the driver's default values are used.

C<Warn> can be specified to 1 in the attribute hash to output warnings when some silly things are attempted.

C<RaiseError> can be specified to 1 in the attribute hash to enable error handling.  Use C<eval { ... };> guard blocks to catch errors.  After the guard block, the special variable $@ is either undefined or contains an error message.

C<PrintError> can be specified to 1 in the attribute hash to disable error handling, and instead print a line on the console and continue execution whenever an error happens.

=head4 data_sources

Implemented, but does not return a list of databases, just a blank entry with the name of the driver.

=head2 Features in C<DBD::Wire10::db>

=head3 I<Database server connection>: methods

Some methods have default implementations in DBI, those are not listed here.  Refer also to the L<DBI::DBI> documentation.

=head4 quote

Quotes a string literal.

MySQL Server chokes if you give it LIMIT parameters that are properly quoted.  To work around this, the quote() method specifically does not quote purely numerical values.  To quote all values, including numerical values, use Net::Wire10::Util::quote().

=head4 quote_identifier

Quotes a schema identifier such as database or table names.

=head4 prepare

Given an SQL string, prepares a statement for executing.

Question marks (?) can be used in place of parameters.  Actual parameters can then be added later either with a call to bind_param(), or when calling execute().

=head4 get_info

Returns various information about the database server when given a code for the particular information to retrieve.

=head4 commit

Commits the active transaction.

=head4 rollback

Rolls back the active transaction.

=head4 disconnect

Disconnects from the database server.

=head4 ping

Sends a ping over the network protocol.  An error is reported via the standard DBI error mechanism if this fails.

=head4 reconnect

Makes sure that there is a connection to the database server.  If there is no connection, and the attempt to reconnect fails, an error is reported via the standard DBI error reporting mechanism.

Notice that the timeout when calling this method is in a sense doubled.  reconnect() first performs a ping() if the connection seems to be alive.  If the ping fails after C<timeout> seconds, then a new underlying connection is established, and establishing this connection could last an additional C<timeout> seconds.

=head4 err

Contains an error code when an error has happened.  Always use RaiseError and eval {} to catch errors in production code.

=head4 state

Contains an SQLSTATE code when an error has happened.

=head4 errstr

Contains an error message when an error has happened.  Always use RaiseError and eval {} to catch errors in production code.

=head4 STORE (internal)

Used internally to store attributes.

=head4 FETCH (internal)

Used internally to fetch attributes.

=head4 DESTROY (internal)

Used internally to destroy the object.

=head3 I<Database server connection>: attributes

Some attributes have default implementations in DBI, those are not listed here.  Refer also to the L<DBI::DBI> documentation.

=head4 AutoCommit

Enables or disables automatic commit after each query, in effect wrapping each query in an implicit transaction.

=head4 Warn

If enabled, warnings are emitted when unexpected things might occur.

=head4 wire10_timeout

The timeout, in seconds, before the driver stops waiting for data from the network when executing a command or connecting to a server.

=head4 wire10_thread_id

Returns the connection id of the current connection on the server.

=head4 wire10_server_version

Returns the server version of the currently connected-to server.

=head4 wire10_debug

A debug bitmask, which when enabled will spew a lots of messages to the console.  1 shows normal debug messages, 2 shows messages flowing back and forth between client and server, and 4 shows raw TCP traffic.

=head4 wire10_insertid (imposed by sth->execute)

Contains the auto_increment value for the last row inserted.  Always use $sth->{wire10_insertid} instead, if the $sth object is available, since this value can be overwritten by irrelevant transactions.

Potentially useful for single-threaded applications that make use of DBI commands which does not return $sth objects, such as do().

=head4 wire10_selectedrows (imposed by sth->execute)

Contains the number of rows returned in the last result set.  Always use $sth->{wire10_selectedrows} instead, if the $sth object is available, since this value can be overwritten by irrelevant transactions.

=head4 wire10_warning_count (imposed by sth->execute)

Contains the number of warnings produced by the last query.  Always use $sth->{wire10_warning_count} instead, if the $sth object is available, since this value can be overwritten by irrelevant transactions.

=head4 Active (internal)

Used internally to notify DBI that connect() has been called and disconnect() has not.

=head4 wire10_driver_dbh (internal)

This is the internal handle for the core driver object associated with the DBI connection.

=head4 wire10_autocommit (internal)

Used internally to store the current AutoCommit setting.

=head2 Features in C<DBD::Wire10::st>

=head3 I<Statement>: methods

=head4 bind_param

Given an index and a value, binds that value to the parameter at the given index in the prepared statement.  Use after prepare() and before execute().

To bind binary data to a parameter, specify a type such as SQL_BLOB.  This prevents the data from being considered Latin-1 or Unicode text.  Example:

  $sth->bind_param(1, $mydata, SQL_BLOB);

Parameters are numbered beginning from 1.

=head4 execute

Runs a prepared statement, optionally using parameters.  Parameters are supplied either via bind_param(), or directly in the call to execute().  When parameters are given in the call to execute(), they override earlier bound parameters for the duration of the call.

=head4 cancel

Cancels the currently executing command (query or ping).  Safe to call from another thread, but note that DBI currently prevents this.

Non-threaded approaches to invoking cancel() such as SIGALRM is generally unsupported by Windows distributions of Perl, so the above affects that query cancelling is only supported on Unix.  A workaround (for this DBD driver) is to grab a reference to the internal driver core and call cancel() on that instead.

Use cancel for interactive code only, where a user may cancel an operation at any time.  Do not use cancel for setting query timeouts.  For that, use the timeout property instead.  The timeout property has slightly better performance, because it does not precipitate creation of an extra thread.

Always returns 1 (success).  The actual status of the query (finished or cancelled, depending on timing) appears in the thread which is running the actual query.

The driver core fetches all results in execute(), so cancelling later on during a fetch does nothing to the current statement.

If a cancel happens to be performed after the current command has finished executing, it will instead take effect during the next command.  In that case, the cancel can be forced out of the system with a ping(), or a reconnect() which implicitly does a ping().

=head4 finish

Clears out the resources used by a statement.  This is called automatically at the start of a new query, among other places, and is therefore normally not necessary to call explicitly.

=head4 fetchrow_arrayref

Fetch one row as an array.

=head4 fetch

Deprecated alias for fetchrow_arrayref.

=head4 rows

The number of affected rows after an UPDATE or similar query, or the number of rows so far read by the client during a SELECT or similar query.

=head4 STORE (internal)

Used internally to store attributes.

=head4 FETCH (internal)

Used internally to fetch attributes.

=head4 DESTROY (internal)

Used internally to destroy the object.

=head3 I<Statement>: attributes

=head4 wire10_insertid

Contains the auto_increment value for the last row inserted.

  my $id = $sth->{wire10_insertid};

=head4 wire10_selectedrows

Contains the number of rows returned in the last result set.

  my $numRows = $sth->{wire10_selectedrows};

=head4 wire10_warning_count

Contains the number of warnings produced by the last query.

  my $warnings = $sth->{wire10_warning_count};

=head4 ChopBlanks

If enabled, runs every field value in result sets through a regular expression that trims for whitespace.

=head4 NUM_OF_PARAMS

Returns the number of parameter tokens found in the prepared statement after a prepare().

=head4 NUM_OF_FIELDS

Returns the number of columns in the result set after a query has been executed.

  my $numCols = $sth->{NUM_OF_FIELDS};

=head4 NAME

Returns the names of all the columns in the result set after a query has been executed.

=head4 Active (internal)

Used internally to notify DBI that the statement has an active result iterator.

=head4 wire10_driver_sth (internal)

Used internally to store a reference to the core driver object.

=head4 wire10_iterator (internal)

Used internally to store a reference to the active result iterator, if any.

=head4 wire10_prepared (internal)

Used internally to store a reference to the prepared statement created by the core driver.

=head4 wire10_rows (internal)

Used internally to store the number of affected rows.

=head1 TROUBLESHOOTING

=head2 Supported operating systems and Perl versions

This module has been tested on these OSes.

=over 4

=item * Windows Server 2008

with ActivePerl 5.10.0 build 1004, 32 and 64-bit

=back

=head2 Unsupported features

DBI has a rich set of reference features, some of which are not implemented by each individual driver.

In general, it should be possible to check for particular features before using them with the can() method, available on all types of DBI handles, and raise an error if a required feature is not supported.

Here is a list of some notable features that this driver does not have.

See also the documentation for L<Net::Wire10/Unsupported features> for limitations in the driver core.

=head3 Unsupported database server connection features in C<DBD::Wire10::db>

The following methods are supposed to be implemented by the DBD connection, but is not (yet) supported in this driver.  For an up-to-date list, see the DBI documentation.

=over 4

=item * type_info_all

=item * type_info

=item * table_info (and tables)

    @names = $dbh->tables;

Should return a list of table and view names, possibly including a schema prefix. This list should include all tables that can be used in a "SELECT" statement without further qualification.

=item * column_info

=item * primary_key_info (and primary_key)

=item * foreign_key_info

=item * statistics_info

=item * list_tables

=item * last_insert_id

=item * take_imp_data

=back

The following attributes are supposed to be implemented by each DBD driver, but is not (yet) supported in this driver.  For an up-to-date list, see the DBI documentation.

=over 4

=item * Name

=item * RowCacheSize

=item * LongReadLen

=item * LongTruncOk

=back

=head3 Unsupported statement features in C<DBD::Wire10::st>

The following methods are supposed to be implemented by each DBD driver, but is not (yet) supported in this driver.  For an up-to-date list, see the DBI documentation.

=over 4

=item * bind_col

=item * bind_columns

=item * bind_param_inout

=back

The following attributes are supposed to be implemented by each DBD driver, but is not (yet) supported in this driver.  For an up-to-date list, see the DBI documentation.

=over 4

=item * TYPE

=item * PRECISION

=item * SCALE

=item * NULLABLE

=item * CursorName

=item * RowsInCache

=item * ParamValues

=item * ParamArrays

=item * ParamTypes

=back

=head2 Return value of C<execute('SELECT * from something')>

B<DBD::Wire10> returns true on success, and false on failure, as specified in DBI documentation.  This differs from B<DBD::mysql>, which returns the number of selected rows.

To get the number of rows from a SELECT statement, use this:

  my $numRows = $sth->{wire10_selectedrows};

If streaming is turned on in the DBD driver (by switching internally from query() to stream()), the above functionality would be disabled, and -1 would be returned every time.

The wire protocol does not have any means by which the server can tell the client how many rows are in the result set, even if the server should discover this at some point.  Therefore the row count is only available after the entire result set has been pulled down to the client.

=head2 Using tokens for LIMITs in prepared statements

MySQL Server chokes if you give it LIMIT parameters that are properly quoted.  As a workaround, this DBD driver scans all field values given to it, and when a purely numerical value is found, it is not quoted.

=head2 Dependencies

This module requires these other modules and libraries:

  L<DBI::DBI>
  L<Net::Wire10>

B<Net::Wire10> is a Pure Perl connector for MySQL, Sphinx and Drizzle servers.

B<Net::Wire10> implements the network protool used to communicate between server and client.

=head1 SEE ALSO

L<DBI::FAQ>
L<DBI::DBI>
L<Net::Wire10>

=head1 AUTHORS

DSN parsing and various code by Hiroyuki OYAMA E, Japan.  DBD boilerplate by DBD authors.  Various code by the open source team at Dubex A/S.

=head1 COPYRIGHT AND LICENCE

Copyright (C) 2002 and (C) 2009 as described in AUTHORS.

This is free software; you can redistribute it and/or modify
it under the same terms as Perl itself. 

=head1 WARRANTY

Because this software is licensed free of charge, there is
absolutely no warranty of any kind, expressed or implied.

=cut
