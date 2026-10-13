use strict;
use warnings;

use FindBin;
use Test::More;

# Runs the player settings hooks against stand-ins for the parts of Lyrion
# they touch: player classes, player settings with their validators, the
# settings pages and the Squeezebox controller menu.

our (%dispatched, @subscribers, @timers, @logged);

# Player settings as Lyrion keeps them: a value is only set if it passes the
# setting's validator, called as ($pref, $new, $params, $old, $client).
package FakeServerPrefs {
	sub new { bless { validators => {}, values => {} }, shift }
	sub setValidate { my ($self, $validator, @prefs) = @_; $self->{validators}{$_} = $validator for @prefs }
	sub client { my ($self, $client) = @_; bless { root => $self, client => $client }, 'FakeClientPrefs' }
}

package FakeClientPrefs {
	sub get { $_[0]{root}{values}{ $_[0]{client}->id }{ $_[1] } }
	sub set {
		my ($self, $pref, $new) = @_;
		my $old = $self->get($pref);
		return 1 if defined $old && defined $new && $old eq $new;
		my $validator = $self->{root}{validators}{$pref};
		return 0 if $validator && !$validator->($pref, $new, undef, $old, $self->{client});
		$self->{root}{values}{ $self->{client}->id }{$pref} = $new;
		return 1;
	}
}

my $serverPrefs = FakeServerPrefs->new;

# Lyrion's own check on player names.
$serverPrefs->setValidate(sub { $_[1] ne '' }, 'playername');

package Slim::Utils::Prefs {
	sub import { no strict 'refs'; *{ caller() . '::preferences' } = sub { $serverPrefs } }
}

package Slim::Player::Squeezebox2 {
	sub maxTransitionDuration { 10 }
	sub canDoReplayGain { defined $_[1] ? 1000 : 1 }

	# A SETD message from the player, carrying its name.
	sub playerSettingsFrame { my ($client, $name) = @_; $serverPrefs->client($client)->set('playername', $name) }

	sub id { $_[0]{id} }
	sub name { $_[0]{name} }
	sub modelName { $_[0]{modelName} }
}

package Slim::Player::SqueezePlay {
	our @ISA = ('Slim::Player::Squeezebox2');
	sub new { my ($class, %args) = @_; bless {%args}, $class }
}

package Slim::Web::Settings {
	sub beforeRender {}
}

package Slim::Web::Settings::Player::Basic {
	our @ISA = ('Slim::Web::Settings');
	sub handler {
		my ($class, $client, $params) = @_;
		$class->beforeRender($params, $client);
		my $page = '<input type="text" class="stdedit" name="pref_playername" id="playername" value="' . $client->name . '" size="20" maxlength="32">';
		return \$page;
	}
}

package Slim::Web::Settings::Player::Audio {
	our @ISA = ('Slim::Web::Settings');
	sub beforeRender { $_[1]{lamefound} = 1 }
}

package Slim::Web::Settings::Server::Plugins {
	our @ISA = ('Slim::Web::Settings');
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
	sub error { push @main::logged, "error: $_[1]" }
}

package Slim::Utils::Strings {
	sub import { no strict 'refs'; *{ caller() . '::cstring' } = sub { "cstring $_[1]" } }
}

package Slim::Utils::Timers {
	sub setTimer { push @main::timers, $_[2] }
}

package main;

$INC{$_} = 1 for qw(Slim/Control/Request.pm Slim/Player/Client.pm Slim/Player/SqueezePlay.pm Slim/Utils/Log.pm
                    Slim/Utils/Prefs.pm Slim/Utils/Strings.pm Slim/Utils/Timers.pm);

for my $module (qw(Hooks Rules PlayerSettings)) {
	require "$FindBin::Bin/../NomadCompanion/$module.pm";
	$INC{"Plugins/NomadCompanion/$module.pm"} = 1;
}

my $nomad       = Slim::Player::SqueezePlay->new(id => 'nomad', name => 'Test phone [Nomad]', modelName => 'Nomad');
my $squeezelite = Slim::Player::SqueezePlay->new(id => 'desk', name => 'Desk', modelName => 'SqueezeLite');
%Slim::Player::Client::players = (nomad => $nomad, desk => $squeezelite);

sub prefsOf { $serverPrefs->client(shift) }

# Both players had crossfade, fade-in and Volume Adjustment on before the
# plugin was installed.
for my $player ($nomad, $squeezelite) {
	$serverPrefs->{values}{ $player->id } = {
		playername => $player->name, transitionType => 1, fadeInDuration => 3, replayGainMode => 2,
	};
}

# Lyrion's crossfade menu for Squeezebox controllers.
$dispatched{'crossfadesettings _index _quantity'} = sub { $_[0]{results}{item_loop} = 'crossfade choices' };

subtest 'waits until Lyrion has started' => sub {
	Plugins::NomadCompanion::PlayerSettings::init();

	is($nomad->maxTransitionDuration, 10, 'nothing changed yet');
	is(scalar @timers, 1, 'set up when the timer fires');

	shift(@timers)->();
};

subtest 'Nomad players report no crossfade or Volume Adjustment' => sub {
	is($nomad->maxTransitionDuration, 0, 'no crossfade or fade-in');
	is($nomad->canDoReplayGain(-5), 0, 'no Volume Adjustment');
	is($nomad->canDoReplayGain(0), 0, '... as asked by the settings page');

	is($squeezelite->maxTransitionDuration, 10, 'other players unchanged');
	is($squeezelite->canDoReplayGain(-5), 1000, '...');
};

subtest 'turned off for Nomad players already connected' => sub {
	is_deeply([ map { prefsOf($nomad)->get($_) } qw(transitionType fadeInDuration replayGainMode) ], [0, 0, 0], 'Nomad');
	is_deeply([ map { prefsOf($squeezelite)->get($_) } qw(transitionType fadeInDuration replayGainMode) ], [1, 3, 2], 'not other players');
	ok((grep { /Turned off transitionType for Test phone \[Nomad\]/ } @logged), 'logged');
};

subtest 'turning them back on' => sub {
	ok(!prefsOf($nomad)->set(transitionType => 1), 'crossfade refused for Nomad');
	ok(!prefsOf($nomad)->set(fadeInDuration => 2), 'fade-in refused');
	ok(!prefsOf($nomad)->set(replayGainMode => 1), 'Volume Adjustment refused');
	is(prefsOf($nomad)->get('transitionType'), 0, '... and still off');
	ok(prefsOf($nomad)->set(fadeInDuration => '0'), 'off is fine');

	ok(prefsOf($squeezelite)->set(transitionType => 2), 'other players can');
};

subtest 'name' => sub {
	ok(!prefsOf($nomad)->set(playername => 'Kitchen'), 'renaming Nomad in Lyrion refused');
	is(prefsOf($nomad)->get('playername'), 'Test phone [Nomad]', '... keeping the phone\'s name');

	$nomad->playerSettingsFrame('Renamed phone [Nomad]');
	is(prefsOf($nomad)->get('playername'), 'Renamed phone [Nomad]', 'the phone sending a new name');

	my $newNomad = Slim::Player::SqueezePlay->new(id => 'new', name => 'New', modelName => 'Nomad');
	ok(prefsOf($newNomad)->set(playername => 'Squeezelite'), "Lyrion's first name for a new Nomad");

	ok(prefsOf($squeezelite)->set(playername => 'Office'), 'other players can be renamed');
	ok(!prefsOf($squeezelite)->set(playername => ''), "... still with Lyrion's own check");
};

subtest 'Nomad players that connect later' => sub {
	$serverPrefs->{values}{nomad}{replayGainMode} = 1;
	$_->(Slim::Control::Request->new(client => $nomad)) for @subscribers;
	is(prefsOf($nomad)->get('replayGainMode'), 0, 'turned off');
};

subtest 'settings pages' => sub {
	my %params = (warning => 'Changes saved');
	my $page = Slim::Web::Settings::Player::Basic->handler($nomad, \%params);
	is($params{warning}, 'cstring PLUGIN_NOMADCOMPANION_NAME<br/>Changes saved', 'name guidance on the Basic page, with Lyrion\'s message kept');
	like($$page, qr/name="pref_playername"[^>]* readonly>/, 'name box read-only');

	%params = ();
	$page = Slim::Web::Settings::Player::Basic->handler($squeezelite, \%params);
	ok(!$params{warning}, 'no guidance for other players');
	unlike($$page, qr/readonly/, '... and their name box editable');

	%params = ();
	Slim::Web::Settings::Player::Audio->beforeRender(\%params, $nomad);
	is($params{warning}, 'cstring PLUGIN_NOMADCOMPANION_AUDIO', 'audio guidance on the Audio page');
	ok($params{lamefound}, "... after Lyrion's own preparation");

	%params = ();
	Slim::Web::Settings::Server::Plugins->beforeRender(\%params, $nomad);
	ok(!$params{warning}, 'nothing on other settings pages');
};

subtest 'Squeezebox controller menu' => sub {
	my $request = Slim::Control::Request->new(client => $nomad);
	$dispatched{'crossfadesettings _index _quantity'}->($request);
	is_deeply($request->{results}, { window => { textarea => 'string PLUGIN_NOMADCOMPANION_AUDIO' }, count => 0 }, 'guidance for Nomad');

	$request = Slim::Control::Request->new(client => $squeezelite);
	$dispatched{'crossfadesettings _index _quantity'}->($request);
	is($request->{results}{item_loop}, 'crossfade choices', 'choices for other players');
};

done_testing();
