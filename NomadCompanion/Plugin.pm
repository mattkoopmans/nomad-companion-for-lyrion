package Plugins::NomadCompanion::Plugin;

# Server side of Nomad Player: lets only the phone running Nomad control its
# player. Plugins::NomadCompanion::Rules decides which requests count as
# control; this module works out which device sent each request and refuses
# the ones the rules don't allow.
#
# Every request Lyrion runs goes through Slim::Control::Request::execute, so
# requests are checked there. A request made while another one runs, such as
# a plugin acting for a controller, counts as coming from the same device.
# Requests made later, for example after fetching a menu from the internet,
# can't be traced to a device and are let through like Lyrion's own.

use strict;
use base qw(Slim::Plugin::Base);

use IO::Socket::IP;
use Scalar::Util qw(blessed looks_like_number);

use Slim::Control::Request;
use Slim::Player::Client;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Slim::Web::Cometd::Manager;
use Slim::Web::HTTP;

use Plugins::NomadCompanion::Rules qw(isNomad isPhoneAddress changesPlayer namedPlayers requestName);
use Plugins::NomadCompanion::Transfer;

my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.nomadcompanion',
	defaultLevel => 'WARN',
	description  => 'PLUGIN_NOMADCOMPANION',
});

my $prefs = preferences('plugin.nomadcompanion');

# The address of the device behind the request being run: undef for Lyrion's
# own requests, or '' when a device sent it but its address is unknown.
our $sender;

# Cometd clients' addresses by client ID, as Lyrion's Cometd module keeps its
# own list private.
my %cometdAddresses;

sub initPlugin {
	my $class = shift;

	# Test mode lets requests from this computer through the lock.
	$prefs->init({ testMode => 0 });

	# "nomad version ?" tells the app that the plugin is installed, and which
	# version, for its settings screen.
	#                                                              |requires Client
	#                                                              |  |is a Query
	#                                                              |  |  |has Tags
	#                                                              |  |  |  |Function to call
	#                                                              C  Q  T  F
	Slim::Control::Request::addDispatch(['nomad', 'version', '?'], [0, 1, 0, \&versionQuery]);

	# Moving music between Nomad and another player, see
	# Plugins::NomadCompanion::Transfer.
	Slim::Control::Request::addDispatch(['nomad', 'takeover'], [1, 0, 1, \&Plugins::NomadCompanion::Transfer::takeoverCommand]);
	Slim::Control::Request::addDispatch(['nomad', 'copy'],     [1, 0, 1, \&Plugins::NomadCompanion::Transfer::copyCommand]);
	Slim::Control::Request::addDispatch(['nomad', 'send'],     [1, 0, 1, \&Plugins::NomadCompanion::Transfer::sendCommand]);

	eval { require Plugins::NomadCompanion::Settings };

	if ($@) {
		$log->warn("Couldn't load the settings page: $@");
	}
	else {
		Plugins::NomadCompanion::Settings->new;
	}

	_wrap('Slim::Control::Request::execute', \&_execute);

	# The classic web interface runs commands while it handles a page request.
	_wrap('Slim::Web::HTTP::processURL', sub {
		my $original = shift;

		local $sender = _socketAddress($_[0]) // '';

		return $original->(@_);
	});

	# Cometd connections are HTTP connections, or sockets for Cometd over the
	# command-line interface.
	_wrap('Slim::Web::Cometd::Manager::register_connection', sub {
		my ($original, $manager, $clid, $conn) = @_;

		$cometdAddresses{$clid} = _socketAddress(ref $conn eq 'ARRAY' ? $conn->[0] : $conn);

		return $original->($manager, $clid, $conn);
	});

	_wrap('Slim::Web::Cometd::Manager::remove_client', sub {
		my ($original, $manager, $clid) = @_;

		delete $cometdAddresses{$clid};

		return $original->($manager, $clid);
	});
}

sub versionQuery {
	my $request = shift;

	if ($request->isNotQuery([['nomad'], ['version']])) {
		$request->setStatusBadDispatch();
		return;
	}

	$request->addResult('_version', __PACKAGE__->_pluginDataFor('version'));
	$request->addResult('_test_mode', $prefs->get('testMode') ? 1 : 0);
	$request->setStatusDone();
}

# Runs $request unless it would change a Nomad player from another device.
sub _execute {
	my ($original, $request, @args) = @_;

	# A failed check must never stop Lyrion from running requests.
	my ($address, $nomad) = eval {
		my $address = _requestAddress($request) // $sender;

		($address, defined $address ? _protectedPlayer($request, $address) : undef);
	};

	$log->error("Couldn't check a request, so let it through: $@") if $@;

	local $sender = $address // $sender;

	if ($nomad) {
		_refuse($request, $nomad, $address);
		return;
	}

	return $original->($request, @args);
}

# The address of the device that sent $request: undef if it didn't come
# straight from a device, or '' if it did but the address is unknown.
sub _requestAddress {
	my $request = shift;

	my $source = $request->source() // return undef;

	# JSON-RPC and the command-line interface keep the connection.
	if ($source eq 'JSONRPC' || $source eq 'CLI') {
		return _socketAddress($request->connectionID()) // '';
	}

	# Cometd keeps "<channel>|<id>|<priority>|<client ID>|<user agent>", the
	# channel starting with the client ID.
	my ($channel, undef, undef, $clid) = split /\|/, $source, 5;

	if (defined $clid && $channel =~ m{^/[0-9a-f]{8}/}) {
		return $cometdAddresses{$clid} // '';
	}

	return undef;
}

sub _socketAddress {
	my $socket = shift;

	return undef unless blessed($socket);

	return $Slim::Web::HTTP::peeraddr{$socket} // ($socket->can('peerhost') ? $socket->peerhost() : undef);
}

# The Nomad player that $request would change, if it isn't coming from that
# player's phone at $address.
sub _protectedPlayer {
	my ($request, $address) = @_;

	# Test mode lets this computer through, so the app can be tested from it.
	return undef if $prefs->get('testMode') && _isServerAddress($address);

	my @changed = map { _player($_) } namedPlayers($request);

	# Synced players share one queue, so changing one changes them all.
	if ((my $client = $request->client()) && changesPlayer($request)) {
		push @changed, $client, $client->syncedWith();
	}

	for my $player (grep { isNomad($_) } @changed) {
		return $player unless isPhoneAddress($player, $address);
	}

	return undef;
}

# Whether $address belongs to the computer Lyrion runs on. An address can
# only be bound to if one of this computer's network interfaces has it.
sub _isServerAddress {
	my $address = shift || return 0;

	$address =~ s/^::ffff://i;

	return IO::Socket::IP->new(LocalHost => $address, Proto => 'udp') ? 1 : 0;
}

# A player by ID, or by number as "sync" also accepts.
sub _player {
	my $id = shift;

	my $player = Slim::Player::Client::getClient($id);

	if (!$player && looks_like_number($id)) {
		$player = (Slim::Player::Client::clients())[$id];
	}

	return $player;
}

# Answers $request with an error instead of running it.
sub _refuse {
	my ($request, $nomad, $address) = @_;

	$log->warn(sprintf('Refused "%s" for %s from %s', requestName($request), $nomad->name(), $address || 'an unknown address'));

	$request->addResult('error', string('PLUGIN_NOMADCOMPANION_REFUSED'));
	$request->setStatusDone();
	$request->executeDone();
}

# Replaces Lyrion's function $name with $wrapper, which is passed the
# original function first.
sub _wrap {
	my ($name, $wrapper) = @_;

	no strict 'refs';
	no warnings 'redefine';

	if (!defined &$name) {
		$log->error("$name is missing, so Nomad's player is not fully protected. Has Lyrion changed?");
		return;
	}

	my $original = \&$name;

	*$name = sub { $wrapper->($original, @_) };
}

1;
