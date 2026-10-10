use strict;
use warnings;

use FindBin;
use Test::More;

# Runs the scrobbling hooks against stand-ins for Lyrion's scrobbling plugin
# and the parts of Lyrion they touch.

our (%dispatched, @subscribers, @timers, @logged, @accountChanges, %accounts);

package Slim::Plugin::AudioScrobbler::Plugin {
	sub changeAccount {
		my ($client, $account) = @_;
		push @main::accountChanges, [ (ref $client ? $client->id : $client), $account ];
		$main::accounts{ ref $client ? $client->id : $client } = $account;
	}
}

# Renders the page its page() names, as Lyrion's settings pages do.
package Slim::Plugin::AudioScrobbler::PlayerSettings {
	sub page { 'plugins/AudioScrobbler/settings/player.html' }
	sub handler { my ($class, $client, $params) = @_; return 'rendered ' . $class->page }
}

package Slim::Control::Request {
	sub addDispatch {
		my ($verbs, $data) = @_;
		my $key = join ' ', @$verbs;
		my $previous = $main::dispatched{$key};
		$main::dispatched{$key} = $data->[3];
		return $previous;
	}
	sub subscribe { push @main::subscribers, $_[0] }
	sub new { my ($class, %args) = @_; bless { results => {}, %args }, $class }
	sub client { $_[0]{client} }
	sub addResult { $_[0]{results}{ $_[1] } = $_[2] }
	sub setStatusDone { $_[0]{status} = 'done' }
	sub string { "string $_[1]" }
}

package Slim::Player::Client {
	our %players;
	sub getClient { defined $_[0] ? $players{ $_[0] } : undef }
	sub clients { map { $players{$_} } sort keys %players }
}

package Slim::Utils::Log {
	sub import { no strict 'refs'; *{ caller() . '::logger' } = sub { bless {}, 'FakeLog' } }
}

package FakeLog {
	sub warn { push @main::logged, $_[1] }
}

package Slim::Utils::Prefs {
	sub import { no strict 'refs'; *{ caller() . '::preferences' } = sub { bless {}, 'FakePrefs' } }
}

package FakePrefs {
	sub client { my ($self, $client) = @_; bless { id => $client->id }, 'FakeClientPrefs' }
}

package FakeClientPrefs {
	sub get { $main::accounts{ $_[0]{id} } }
}

package Slim::Utils::Timers {
	sub setTimer { push @main::timers, $_[2] }
}

package FakePlayer {
	sub new { my ($class, %args) = @_; bless {%args}, $class }
	sub id { $_[0]{id} }
	sub name { $_[0]{name} }
	sub modelName { $_[0]{modelName} }
}

package main;

$INC{$_} = 1 for qw(Slim/Control/Request.pm Slim/Player/Client.pm Slim/Utils/Log.pm Slim/Utils/Prefs.pm Slim/Utils/Timers.pm);

for my $module (qw(Hooks Rules Scrobbling)) {
	require "$FindBin::Bin/../NomadCompanion/$module.pm";
	$INC{"Plugins/NomadCompanion/$module.pm"} = 1;
}

my $nomad   = FakePlayer->new(id => 'nomad', name => 'Test phone [Nomad]', modelName => 'Nomad');
my $kitchen = FakePlayer->new(id => 'kitchen', name => 'Kitchen', modelName => 'Squeezebox Touch');
%Slim::Player::Client::players = (nomad => $nomad, kitchen => $kitchen);

# Lyrion's own menu for choosing an account.
$dispatched{'audioscrobbler settings'} = sub { $_[0]{results}{item_loop} = 'accounts' };

# Both players chose an account before the plugin was installed.
%accounts = (nomad => 'matt', kitchen => 'matt');

subtest 'waits until Lyrion has started' => sub {
	Plugins::NomadCompanion::Scrobbling::init();

	is($accounts{nomad}, 'matt', 'nothing changed yet');
	is(scalar @timers, 1, 'set up when the timer fires');

	shift(@timers)->();
};

subtest 'turned off for Nomad players already connected' => sub {
	is($accounts{nomad}, '0', 'Nomad');
	is($accounts{kitchen}, 'matt', 'not other players');
	like($logged[-1], qr/Turned off Lyrion scrobbling for Test phone \[Nomad\]/, 'logged');
};

subtest 'choosing an account' => sub {
	Slim::Plugin::AudioScrobbler::Plugin::changeAccount($nomad, 'matt');
	is($accounts{nomad}, '0', 'refused for Nomad');
	like($logged[-1], qr/Kept Lyrion from scrobbling Test phone \[Nomad\]/, 'logged');

	Slim::Plugin::AudioScrobbler::Plugin::changeAccount('nomad', 'matt');
	is($accounts{nomad}, '0', '... also when named by ID');

	Slim::Plugin::AudioScrobbler::Plugin::changeAccount($nomad, undef);
	is($accounts{nomad}, '0', '... and saving its settings page leaves it off');

	Slim::Plugin::AudioScrobbler::Plugin::changeAccount($kitchen, 'anna');
	is($accounts{kitchen}, 'anna', 'allowed for other players');
};

subtest 'Nomad players that connect later' => sub {
	$accounts{nomad} = 'matt';
	$_->(Slim::Control::Request->new(client => $nomad)) for @subscribers;
	is($accounts{nomad}, '0', 'turned off');

	@accountChanges = ();
	$_->(Slim::Control::Request->new(client => $kitchen)) for @subscribers;
	is_deeply(\@accountChanges, [], 'other players left alone');
};

subtest 'settings page' => sub {
	is(Slim::Plugin::AudioScrobbler::PlayerSettings->handler($nomad, {}), 'rendered plugins/NomadCompanion/settings/scrobbling.html', 'guidance for Nomad');
	is(Slim::Plugin::AudioScrobbler::PlayerSettings->page, 'plugins/AudioScrobbler/settings/player.html', "Lyrion's own address for the page afterwards");
	is(Slim::Plugin::AudioScrobbler::PlayerSettings->handler($kitchen, {}), 'rendered plugins/AudioScrobbler/settings/player.html', 'accounts for other players');
};

subtest 'Squeezebox controller menu' => sub {
	my $request = Slim::Control::Request->new(client => $nomad);
	$dispatched{'audioscrobbler settings'}->($request);
	is_deeply($request->{results}, { window => { textarea => 'string PLUGIN_NOMADCOMPANION_SCROBBLING' }, count => 0 }, 'guidance for Nomad');

	$request = Slim::Control::Request->new(client => $kitchen);
	$dispatched{'audioscrobbler settings'}->($request);
	is($request->{results}{item_loop}, 'accounts', 'accounts for other players');
};

subtest "Lyrion's scrobbling plugin turned off" => sub {
	no warnings 'once';
	local *Slim::Plugin::AudioScrobbler::Plugin::changeAccount;
	local %dispatched;
	@subscribers = ();

	Plugins::NomadCompanion::Scrobbling::_setup();
	is_deeply([ \%dispatched, \@subscribers ], [ {}, [] ], 'nothing set up');
};

done_testing();
