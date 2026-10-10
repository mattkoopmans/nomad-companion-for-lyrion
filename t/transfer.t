use strict;
use warnings;

use FindBin;
use Test::More;

# Runs the transfer commands against stand-in players that keep a queue and
# a play state, and react to the Lyrion commands the plugin sends them.

our @notified;

package Slim::Control::Request {
	sub new { my ($class, %args) = @_; bless { params => {}, results => {}, %args }, $class }
	sub isNotCommand { 0 }
	sub client { $_[0]{client} }
	sub getParam { $_[0]{params}{ $_[1] } }
	sub addResult { $_[0]{results}{ $_[1] } = $_[2] }
	sub setStatusDone { $_[0]{status} = 'done' }
	sub notifyFromArray { push @main::notified, [ $_[0]->id, @{ $_[1] } ] }
}

package Slim::Player::Client {
	our %players;
	sub getClient { defined $_[0] ? $players{ $_[0] } : undef }
}

package Slim::Player::Playlist {
	sub playList { $_[0]{playlist} }
	sub shuffleList { $_[0]{shufflelist} }
	sub count { scalar @{ $_[0]{playlist} } }
	sub repeat { $_[0]{repeat} }
}

package Slim::Player::Source {
	sub playingSongIndex { $_[0]{index} }
	sub playingSong { FakeSong->new($_[0]{seekable}) }
	sub songTime { $_[0]{time} }
}

package Slim::Player::StreamingController {
	use constant PAUSED => 4;
	sub _setPlayingState { $_[0]{playingState} = $_[1] }
}

package Slim::Utils::Strings {
	sub import { no strict 'refs'; *{ caller() . '::string' } = \&string }
	sub string { $_[0] eq 'PLUGIN_NOMADCOMPANION_NOTHING_TO_PLAY' ? 'NOTHING_TO_PLAY %s' : $_[0] }
}

package FakeSong {
	sub new { my ($class, $seekable) = @_; bless { seekable => $seekable }, $class }
	sub canSeek { $_[0]{seekable} }
}

# A player: its queue, play state ("play", "pause" or "stop") and position,
# changed by the commands it's sent, which are also kept in "commands".
package FakePlayer {
	sub new {
		my ($class, %args) = @_;
		return bless {
			playlist => [], shufflelist => [], shuffle => 0, repeat => 0, index => 0, time => 0,
			state => 'stop', power => 1, seekable => 1, controller => {}, commands => [], %args,
		}, $class;
	}

	sub id { $_[0]{id} }
	sub name { $_[0]{name} }
	sub modelName { $_[0]{modelName} }
	sub power { $_[0]{power} }
	sub controller { $_[0]{controller} }
	sub isStopped { $_[0]{state} eq 'stop' }
	sub isPlaying { $_[0]{state} eq 'play' }

	sub execute {
		my ($self, $command) = @_;
		push @{ $self->{commands} }, join ' ', map { ref $_ ? 'REF' : $_ // 'undef' } @$command;

		my ($verb, @args) = @$command;
		$verb .= ' ' . shift @args if $verb eq 'playlist';

		if ($verb eq 'playlist clear') {
			@$self{qw(playlist shufflelist state index time)} = ([], [], 'stop', 0, 0);
		}
		elsif ($verb eq 'playlist shuffle') {
			$self->{shuffle} = $args[0];
		}
		elsif ($verb eq 'playlist addtracks') {
			die "added to a shuffled queue\n" if $self->{shuffle};
			push @{ $self->{playlist} }, @{ $args[1] };
			$self->{shufflelist} = [ 0 .. $#{ $self->{playlist} } ];
		}
		elsif ($verb eq 'playlist repeat') {
			$self->{repeat} = $args[0];
		}
		elsif ($verb eq 'playlist jump') {
			my ($index, undef, $noplay, $seekdata) = @args;
			$self->{index} = $index;
			$self->{time}  = $seekdata ? $seekdata->{timeOffset} : 0;
			$self->{state} = $noplay ? 'stop' : 'play';
		}
		elsif ($verb eq 'stop') {
			$self->{state} = 'stop';
		}
		elsif ($verb eq 'power') {
			$self->{power} = $args[0];
		}
		else {
			die "unexpected command: $verb\n";
		}
	}
}

package main;

$INC{$_} = 1 for qw(Slim/Control/Request.pm Slim/Player/Client.pm Slim/Player/Playlist.pm Slim/Player/Source.pm
                    Slim/Player/StreamingController.pm Slim/Utils/Strings.pm);

require "$FindBin::Bin/../NomadCompanion/Rules.pm";
$INC{'Plugins/NomadCompanion/Rules.pm'} = 1;
require "$FindBin::Bin/../NomadCompanion/Transfer.pm";

my ($nomad, $kitchen);

# A fresh Nomad with a two-track queue, and a kitchen player playing the
# third of four tracks, shuffled, 95 seconds in.
sub players {
	$nomad = FakePlayer->new(id => 'nomad', name => 'Test phone [Nomad]', modelName => 'Nomad',
		playlist => [qw(n1 n2)], shufflelist => [0, 1], @_);
	$kitchen = FakePlayer->new(id => 'kitchen', name => 'Kitchen', modelName => 'Squeezebox Touch',
		playlist => [qw(k1 k2 k3 k4)], shufflelist => [3, 1, 0, 2], shuffle => 1, repeat => 2,
		state => 'play', index => 2, time => 95);
	%Slim::Player::Client::players = map { $_->id => $_ } $nomad, $kitchen;
	@notified = ();
}

sub command {
	my ($action, %params) = @_;
	my $client = exists $params{client} ? $Slim::Player::Client::players{ delete $params{client} } : $nomad;
	my $request = Slim::Control::Request->new(client => $client, params => \%params);
	Plugins::NomadCompanion::Transfer->can("${action}Command")->($request);
	return $request->{results};
}

subtest 'take over a playing player' => sub {
	players();
	my $result = command('takeover', player => 'kitchen');

	is_deeply($nomad->{playlist}, [qw(k4 k2 k1 k3)], "Nomad has the kitchen's queue in play order");
	is($nomad->{shuffle}, 0, 'unshuffled');
	is($nomad->{repeat}, 2, 'same repeat');
	is_deeply([ @$nomad{qw(state index time)} ], ['play', 2, 95], 'Nomad plays from the same track and time');
	is($kitchen->{state}, 'stop', 'the kitchen stops');
	is_deeply($kitchen->{playlist}, [qw(k1 k2 k3 k4)], '... keeping its queue');
	is_deeply($result, { _count => 4, _index => 2, _time => 95, _mode => 'play' }, 'result');
};

subtest 'take over a paused player' => sub {
	players();
	$kitchen->{state} = 'pause';
	my $result = command('takeover', player => 'kitchen');

	is($nomad->{state}, 'stop', 'Nomad plays nothing');
	is($nomad->{index}, 2, '... is at the same track');
	is_deeply($nomad->{controller}, { resumeTime => 95, playingState => 4 }, '... and held paused at the same time');
	ok((grep { "@$_" eq 'nomad playlist pause 1' } @notified), 'Lyrion told it paused');
	is($kitchen->{state}, 'stop', 'the kitchen stops');
	is($result->{_mode}, 'pause', 'result');
};

subtest 'take over a stopped player' => sub {
	players();
	$kitchen->{state} = 'stop';
	my $result = command('takeover', player => 'kitchen');

	is_deeply($nomad->{controller}, { resumeTime => 0, playingState => 4 }, 'Nomad held paused at the start of the track');
	is_deeply([ @$result{qw(_index _time _mode)} ], [2, 0, 'pause'], 'result');
};

subtest 'take over a radio stream' => sub {
	players();
	$kitchen->{seekable} = 0;
	my $result = command('takeover', player => 'kitchen');

	is_deeply([ @$nomad{qw(state time)} ], ['play', 0], 'Nomad plays it from the start');
	is($result->{_time}, 0, 'result');
};

subtest 'Lyrion without the paused state' => sub {
	players();
	$kitchen->{state} = 'pause';
	no warnings 'once';
	local *Slim::Player::StreamingController::_setPlayingState;
	my $result = command('takeover', player => 'kitchen');

	is_deeply([ @$nomad{qw(state index)} ], ['stop', 2], 'Nomad stopped at the same track');
	is_deeply($nomad->{controller}, {}, '... and not held paused');
	is($result->{_mode}, 'stop', 'result');
};

subtest 'copy and start' => sub {
	players();
	my $result = command('copy', player => 'kitchen', mode => 'replace', start => 1);

	is_deeply($nomad->{playlist}, [qw(k4 k2 k1 k3)], "Nomad has the kitchen's queue in play order");
	is_deeply([ @$nomad{qw(state index time)} ], ['play', 2, 95], 'Nomad plays from the same track and time');
	is_deeply($kitchen->{commands}, [], 'the kitchen is left alone');
	is($kitchen->{state}, 'play', '... and keeps playing');
	is_deeply($result, { _count => 4, _index => 2, _time => 95, _mode => 'play' }, 'result');
};

subtest 'copy without starting' => sub {
	players(state => 'play', index => 1, time => 30);
	my $result = command('copy', player => 'kitchen', mode => 'replace', start => 0);

	is_deeply($nomad->{playlist}, [qw(k4 k2 k1 k3)], "Nomad has the kitchen's queue");
	is_deeply([ @$nomad{qw(state index)} ], ['stop', 0], 'Nomad is stopped at the top');
	is_deeply($kitchen->{commands}, [], 'the kitchen is left alone');
	is_deeply($result, { _count => 4, _index => 0, _time => 0, _mode => 'stop' }, 'result');
};

subtest 'copy onto the end' => sub {
	players(state => 'play', index => 1, time => 30);
	my $result = command('copy', player => 'kitchen', mode => 'append');

	is_deeply($nomad->{playlist}, [qw(n1 n2 k4 k2 k1 k3)], "the kitchen's queue follows Nomad's");
	is_deeply([ @$nomad{qw(state index time)} ], ['play', 1, 30], 'Nomad carries on playing');
	is_deeply($nomad->{commands}, ['playlist addtracks listRef REF'], '... with nothing but tracks added');
	is_deeply($kitchen->{commands}, [], 'the kitchen is left alone');
	is_deeply($result, { _count => 4 }, 'result');
};

subtest 'send' => sub {
	players(state => 'play', index => 1, time => 30, repeat => 1);
	$kitchen->{power} = 0;
	my $result = command('send', player => 'kitchen');

	is($kitchen->{commands}[0], 'power 1 1', 'the kitchen is switched on without resuming its own queue');
	is_deeply($kitchen->{playlist}, [qw(n1 n2)], "the kitchen has Nomad's queue");
	is($kitchen->{repeat}, 1, '... and repeat');
	is_deeply([ @$kitchen{qw(state index time)} ], ['play', 1, 30], 'the kitchen plays from the same track and time');
	is($nomad->{state}, 'stop', 'Nomad stops');
	is_deeply($nomad->{playlist}, [qw(n1 n2)], '... keeping its queue');
	is_deeply($result, { _count => 2, _index => 1, _time => 30, _mode => 'play' }, 'result');
};

subtest 'send while paused' => sub {
	players(state => 'pause', index => 1, time => 30);
	my $result = command('send', player => 'kitchen');

	is_deeply($kitchen->{controller}, { resumeTime => 30, playingState => 4 }, 'the kitchen is held paused at the same time');
	is($result->{_mode}, 'pause', 'result');
};

subtest 'errors' => sub {
	my %errors = (
		'not aimed at Nomad'         => [ 'takeover', client => 'kitchen', player => 'nomad' ],
		'unknown player'             => [ 'takeover', player => 'garage' ],
		'Nomad itself'               => [ 'send', player => 'nomad' ],
		'another Nomad'              => [ 'takeover', player => 'other nomad' ],
		'bad mode'                   => [ 'copy', player => 'kitchen', mode => 'swap' ],
		'nothing to take over'       => [ 'takeover', player => 'kitchen', empty => 'kitchen' ],
		'nothing to send'            => [ 'send', player => 'kitchen', empty => 'nomad' ],
	);
	my %expected = (
		'not aimed at Nomad' => 'PLUGIN_NOMADCOMPANION_NOT_NOMAD', 'unknown player' => 'PLUGIN_NOMADCOMPANION_NO_PLAYER',
		'Nomad itself' => 'PLUGIN_NOMADCOMPANION_NO_PLAYER', 'another Nomad' => 'PLUGIN_NOMADCOMPANION_OTHER_NOMAD',
		'bad mode' => 'PLUGIN_NOMADCOMPANION_BAD_MODE', 'nothing to take over' => 'NOTHING_TO_PLAY Kitchen',
		'nothing to send' => 'NOTHING_TO_PLAY Test phone [Nomad]',
	);

	for my $case (sort keys %errors) {
		players();
		$Slim::Player::Client::players{'other nomad'} = FakePlayer->new(id => 'other nomad', modelName => 'Nomad', playlist => ['x']);
		my ($action, %params) = @{ $errors{$case} };
		if (my $empty = delete $params{empty}) { $Slim::Player::Client::players{$empty}{playlist} = [] }

		my $result = command($action, %params);
		is_deeply($result, { error => $expected{$case} }, $case);
		ok(!@{ $nomad->{commands} } && !@{ $kitchen->{commands} }, "... and nothing changed");
	}
};

done_testing();
