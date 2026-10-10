package Plugins::NomadCompanion::Rules;

# Which requests may reach a Nomad player.
#
# Only the phone running Nomad may change its player. Any other device may
# still read from it: its status, queue and settings. Lyrion's own actions,
# such as moving on to the next track, carry no device and are always allowed.
#
# Lyrion flags each request as a query or a command, which mostly matches
# "reads" and "changes". The lists below correct the cases where it doesn't.

use strict;

use Exporter qw(import);

our @EXPORT_OK = qw(isNomad isPhoneAddress changesPlayer namedPlayers requestName);

# Commands that only read from the player, so other devices may still send
# them.
my %readingCommands = (
	'playlist save'                   => 1, # copies the queue into a saved playlist
	'material-skin-client get-alarm'  => 1, # Material skin's player screens
	'material-skin-client get-dstm'   => 1,
	'material-skin-client home-extra' => 1,
	'material-skin-client init'       => 1,
);

# Queries that change the player.
my %changingQueries = (
	'jiveendoftracksleep' => 1, # sleep at the end of the current track
);

# Nomad players report this model name when they connect.
sub isNomad {
	my $client = shift;

	return $client && ($client->modelName() // '') eq 'Nomad' ? 1 : 0;
}

# Whether $address is the phone's own address: the one its player connection
# comes from.
sub isPhoneAddress {
	my ($client, $address) = @_;

	return 0 unless defined $address && defined $client->ip();

	return _plainAddress($address) eq _plainAddress($client->ip()) ? 1 : 0;
}

# Whether $request, aimed at a Nomad player, would change it.
sub changesPlayer {
	my $request = shift;

	my $name = requestName($request);

	if ($request->query()) {
		# Menus play their items through "<menu> playlist <method>", such as
		# "favorites playlist play" or "tidal_browse playlist add".
		return 1 if ($request->getRequest(1) // '') eq 'playlist' && $request->getRequest(0) ne 'playlist';

		return $changingQueries{$name} ? 1 : 0;
	}

	# Commands that don't need a player act on the server instead:
	# favourites, saved playlists, preferences and rescans.
	return 0 unless $request->needClient();

	return $readingCommands{$name} ? 0 : 1;
}

# Players that $request would change by naming them in its parameters
# rather than by being aimed at them: player IDs, or player numbers for sync.
sub namedPlayers {
	my $request = shift;

	my $name = requestName($request);

	# "sync <player>" groups the target with the named player, which then
	# shares its queue.
	if ($name eq 'sync') {
		my $buddy = $request->getParam('_indexid-');

		return defined $buddy && $buddy ne '-' ? ($buddy) : ();
	}

	# "disconnect <player> <server>" moves the named player to another server.
	if ($name eq 'disconnect') {
		return grep { defined } $request->getParam('_playerid');
	}

	# Material skin's queue transfer replaces the queue on "to", and empties
	# or swaps "from" unless copying.
	if ($name eq 'material-skin transferqueue') {
		my @players = $request->getParam('to');
		push @players, $request->getParam('from') if ($request->getParam('mode') // '') ne 'copy';

		return grep { defined } @players;
	}

	return ();
}

# The request's verbs, plus the "_cmd" parameter that some plugins use as a
# sub-command, e.g. "material-skin-client init".
sub requestName {
	my $request = shift;

	my $cmd = $request->getParam('_cmd');

	return join(' ', $request->getRequestString(), defined $cmd ? $cmd : ());
}

# Addresses can arrive as IPv4 mapped into IPv6, e.g. "::ffff:100.64.0.7".
sub _plainAddress {
	my $address = lc shift;

	$address =~ s/^::ffff://;

	return $address;
}

1;
