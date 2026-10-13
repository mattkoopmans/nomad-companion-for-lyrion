package Plugins::NomadCompanion::PlayerSettings;

# Keeps Lyrion's settings for Nomad players to what Nomad can do.
#
# - Crossfade, fade-in and Volume Adjustment (ReplayGain): Nomad can't apply
#   them, so Nomad players report that they can't. Lyrion then leaves them
#   out of what it sends and off its Audio settings page, and the settings
#   themselves are kept off.
# - Name: Nomad names its player after the phone, so the name only changes
#   when the player sends a new one, never from Lyrion's settings.
#
# Lyrion's Basic and Audio settings pages, and the Squeezebox controller's
# crossfade menu, explain this for Nomad players.

use strict;

use Time::HiRes;

use Slim::Control::Request;
use Slim::Player::Client;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Timers;

use Plugins::NomadCompanion::Hooks qw(wrap override);
use Plugins::NomadCompanion::Rules qw(isNomad);

my $log   = logger('plugin.nomadcompanion');
my $prefs = preferences('server');

# Settings Nomad can't apply, and their values for off.
my %off = (transitionType => 0, fadeInDuration => 0, replayGainMode => 0);

# Guidance on Lyrion's player settings pages, by page.
my %pageGuidance = (
	'Slim::Web::Settings::Player::Basic' => 'PLUGIN_NOMADCOMPANION_NAME',
	'Slim::Web::Settings::Player::Audio' => 'PLUGIN_NOMADCOMPANION_AUDIO',
);

# Whether the setting being changed comes from the player itself.
our $fromPlayer;

sub init {
	# Lyrion's player classes and settings pages may load after this plugin,
	# so wait until Lyrion has started.
	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time(), \&_setup);
}

sub _setup {
	# Nomad connects as a SqueezePlay player, like Squeezelite.
	eval { require Slim::Player::SqueezePlay };

	my $cant = sub { my ($original, $client, @args) = @_; isNomad($client) ? 0 : $original->($client, @args) };

	override('Slim::Player::SqueezePlay', 'maxTransitionDuration', $cant)
		&& override('Slim::Player::SqueezePlay', 'canDoReplayGain', $cant)
		or $log->error("Can't turn off crossfade and Volume Adjustment for Nomad players. Has Lyrion changed?");

	# The player sends its name in a SETD message.
	wrap('Slim::Player::Squeezebox2::playerSettingsFrame', sub {
		my $original = shift;

		local $fromPlayer = 1;

		return $original->(@_);
	})
	or $log->error("Can't tell the phone's name from other names for Nomad players. Has Lyrion changed?");

	_validate('playername', sub {
		my (undef, undef, undef, $old, $client) = @_;
		return !isNomad($client) || $fromPlayer || !defined $old;
	});

	for my $pref (sort keys %off) {
		_validate($pref, sub {
			my (undef, $new, undef, undef, $client) = @_;
			return !isNomad($client) || ($new || 0) == $off{$pref};
		});
	}

	my $pages = wrap('Slim::Web::Settings::beforeRender', \&_beforeRender)
		&& wrap('Slim::Web::Settings::Player::Audio::beforeRender', \&_beforeRender)
		&& wrap('Slim::Web::Settings::Player::Basic::handler', \&_basicPage);

	$log->warn("Can't explain Nomad's settings on Lyrion's settings pages. Has Lyrion changed?") unless $pages;

	my $menu;
	$menu = Slim::Control::Request::addDispatch(['crossfadesettings', '_index', '_quantity'], [1, 1, 1, sub {
		my $request = shift;

		return _guidanceMenu($request) if isNomad($request->client()) || !$menu;
		return $menu->($request);
	}]);

	# Nomad players may have had these on before this plugin was installed.
	Slim::Control::Request::subscribe(sub { _turnOff(shift->client()) }, [['client'], ['new', 'reconnect']]);
	_turnOff($_) for Slim::Player::Client::clients();
}

# Adds $rule to Lyrion's own check, if any, for player setting $pref.
sub _validate {
	my ($pref, $rule) = @_;

	my $lyrions = $prefs->{'validators'}->{$pref};

	$prefs->setValidate(sub { $rule->(@_) && (!$lyrions || $lyrions->(@_)) }, $pref);
}

# Turns off the settings Nomad can't apply, if $client is a Nomad player.
sub _turnOff {
	my $client = shift;

	return unless isNomad($client);

	my $clientPrefs = $prefs->client($client);

	for my $pref (sort keys %off) {
		next if ($clientPrefs->get($pref) || 0) == $off{$pref};

		$clientPrefs->set($pref, $off{$pref});
		$log->warn("Turned off $pref for " . $client->name() . ", as Nomad can't apply it");
	}
}

# Adds the guidance for a Nomad player to the top of its settings page.
sub _beforeRender {
	my ($original, $class, $params, $client, @args) = @_;

	if (isNomad($client) && (my $token = $pageGuidance{$class})) {
		$params->{'warning'} = join('<br/>', cstring($client, $token), $params->{'warning'} || ());
	}

	return $original->($class, $params, $client, @args);
}

# Lyrion's Basic settings page, with the name box read-only for Nomad players.
sub _basicPage {
	my ($original, $class, $client, @args) = @_;

	my $page = $original->($class, $client, @args);

	if (isNomad($client) && ref $page eq 'SCALAR') {
		$$page =~ s{(<input\b[^>]*\bname="pref_playername"[^>]*?)\s*(/?>)}{$1 readonly$2};
	}

	return $page;
}

sub _guidanceMenu {
	my $request = shift;

	$request->addResult('window', { textarea => $request->string('PLUGIN_NOMADCOMPANION_AUDIO') });
	$request->addResult('count', 0);
	$request->setStatusDone();
}

1;
