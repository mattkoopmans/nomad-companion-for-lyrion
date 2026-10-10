package Plugins::NomadCompanion::Transfer;

# Moves music between a Nomad player and another player without syncing
# them. Queues are copied in play order, with shuffle flattened, and the
# receiving player starts at the same track and time: playing if the source
# was playing, or held paused there if it wasn't.
#
#   nomad takeover player:<id>                       Nomad continues from <id>, which stops
#   nomad copy player:<id> mode:replace|append start:0|1
#                                                    Nomad gets <id>'s queue; <id> is left alone
#   nomad send player:<id>                           <id> continues from Nomad, which stops
#
# All three are aimed at the Nomad player, so only its phone may send them.
# They answer with _count (tracks copied) and, when a player was started,
# _index, _time and _mode ("play", "pause" or "stop"); or with an error.

use strict;

use Slim::Control::Request;
use Slim::Player::Client;
use Slim::Player::Playlist;
use Slim::Player::Source;
use Slim::Player::StreamingController;
use Slim::Utils::Strings qw(string);

use Plugins::NomadCompanion::Rules qw(isNomad);

sub takeoverCommand { _command(shift, 'takeover') }

sub copyCommand { _command(shift, 'copy') }

sub sendCommand { _command(shift, 'send') }

sub _command {
	my ($request, $action) = @_;

	if ($request->isNotCommand([['nomad'], [$action]])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $nomad = $request->client();
	my $other = Slim::Player::Client::getClient($request->getParam('player'));
	my $mode  = $request->getParam('mode') // 'replace';

	my $error =
		!isNomad($nomad)                         ? string('PLUGIN_NOMADCOMPANION_NOT_NOMAD')
		: !$other || $other == $nomad            ? string('PLUGIN_NOMADCOMPANION_NO_PLAYER')
		: isNomad($other)                        ? string('PLUGIN_NOMADCOMPANION_OTHER_NOMAD')
		: $mode !~ /^(?:replace|append)$/        ? string('PLUGIN_NOMADCOMPANION_BAD_MODE')
		: !Slim::Player::Playlist::count($action eq 'send' ? $nomad : $other)
		                                         ? sprintf(string('PLUGIN_NOMADCOMPANION_NOTHING_TO_PLAY'), ($action eq 'send' ? $nomad : $other)->name())
		: undef;

	if ($error) {
		$request->addResult('error', $error);
		$request->setStatusDone();
		return;
	}

	my %result;

	if ($action eq 'takeover') {
		%result = _move($other, $nomad);
	}
	elsif ($action eq 'send') {
		$other->execute(['power', 1, 1]) unless $other->power();
		%result = _move($nomad, $other);
	}
	elsif ($mode eq 'append') {
		my @tracks = _queue($other);
		$nomad->execute(['playlist', 'addtracks', 'listRef', \@tracks]);
		%result = (count => scalar @tracks);
	}
	elsif ($request->getParam('start')) {
		%result = _copy($other, $nomad);
	}
	else {
		my @tracks = _queue($other);
		_load($nomad, \@tracks, Slim::Player::Playlist::repeat($other));
		%result = (count => scalar @tracks, index => 0, time => 0, mode => 'stop');
	}

	$request->addResult("_$_", $result{$_}) for sort keys %result;
	$request->setStatusDone();
}

# Copies $from's queue and position to $to, then stops $from.
sub _move {
	my ($from, $to) = @_;

	my %result = _copy($from, $to);
	$from->execute(['stop']);

	return %result;
}

# Copies $from's queue to $to and starts $to where $from is, without
# changing $from.
sub _copy {
	my ($from, $to) = @_;

	my @tracks = _queue($from);
	my ($index, $time, $playing) = _position($from);

	_load($to, \@tracks, Slim::Player::Playlist::repeat($from));

	return (count => scalar @tracks, index => $index, time => $time, mode => _start($to, $index, $time, $playing));
}

# $player's queue in play order, with shuffle flattened.
sub _queue {
	my $player = shift;

	my $list  = Slim::Player::Playlist::playList($player);
	my $order = Slim::Player::Playlist::shuffleList($player);

	return map { $list->[ $order->[$_] // $_ ] } 0 .. $#$list;
}

# Where $player is in its queue: the play-order index, the elapsed seconds,
# and whether it's playing. Tracks that can't be started part-way, such as
# radio streams, count as at the start.
sub _position {
	my $player = shift;

	my $index = Slim::Player::Source::playingSongIndex($player);
	my $song  = Slim::Player::Source::playingSong($player);
	my $time  = !$player->isStopped() && $song && scalar $song->canSeek() ? Slim::Player::Source::songTime($player) || 0 : 0;

	return ($index, $time, $player->isPlaying() ? 1 : 0);
}

# Replaces $player's queue with $tracks, in that order.
sub _load {
	my ($player, $tracks, $repeat) = @_;

	$player->execute(['playlist', 'clear']);

	# Adding to a shuffled queue would reshuffle it.
	$player->execute(['playlist', 'shuffle', 0]);
	$player->execute(['playlist', 'addtracks', 'listRef', $tracks]);
	$player->execute(['playlist', 'repeat', $repeat]);
}

# Starts $player at $index and $time, playing or paused. Returns the mode it
# ends up in.
sub _start {
	my ($player, $index, $time, $playing) = @_;

	if ($playing) {
		# As Lyrion does when it resumes a player after it reconnects.
		$player->execute(['playlist', 'jump', $index, 0, 0, $time ? { timeOffset => $time } : undef]);
		return 'play';
	}

	# Stopped at the track, without playing.
	$player->execute(['playlist', 'jump', $index, 0, 1]);

	return _holdPaused($player, $time) ? 'pause' : 'stop';
}

# Leaves a stopped $player paused at $time in its current track. Lyrion has
# no command for this, but it's the state Lyrion uses after a seek while
# paused: nothing plays, and pressing play streams from $time. If this
# Lyrion's player controller lacks that state, $player stays stopped.
sub _holdPaused {
	my ($player, $time) = @_;

	my $controller = $player->controller();
	my $setState   = Slim::Player::StreamingController->can('_setPlayingState');
	my $paused     = Slim::Player::StreamingController->can('PAUSED');

	return 0 unless $setState && $paused && $player->isStopped();

	$controller->{'resumeTime'} = $time;
	$setState->($controller, $paused->());

	Slim::Control::Request::notifyFromArray($player, ['playlist', 'pause', 1]);

	return 1;
}

1;
