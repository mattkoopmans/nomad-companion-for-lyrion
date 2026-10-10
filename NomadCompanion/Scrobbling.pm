package Plugins::NomadCompanion::Scrobbling;

# Keeps Lyrion's own scrobbling to Last.fm or ListenBrainz off for Nomad
# players, and points to the phone instead. Lyrion can't see what Nomad plays
# while offline, but the phone can, and the Last.fm app there keeps those
# scrobbles until the phone is back online.
#
# Lyrion scrobbles a player only if it has a scrobbling account chosen, and
# every way of choosing one goes through
# Slim::Plugin::AudioScrobbler::Plugin::changeAccount, so Nomad players are
# kept at "0", no account, there. Their scrobbling settings page and
# Squeezebox controller menu show the guidance instead.

use strict;

use Scalar::Util qw(blessed);
use Time::HiRes;

use Slim::Control::Request;
use Slim::Player::Client;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use Plugins::NomadCompanion::Hooks qw(wrap);
use Plugins::NomadCompanion::Rules qw(isNomad);

my $log   = logger('plugin.nomadcompanion');
my $prefs = preferences('plugin.audioscrobbler');

# Whether the scrobbling settings page being shown is a Nomad player's.
our $nomadSettings;

sub init {
	# Lyrion's scrobbling plugin may load after this one, so wait until
	# Lyrion has started.
	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time(), \&_setup);
}

sub _setup {
	# Nothing to do while Lyrion's scrobbling plugin is turned off.
	return unless defined &Slim::Plugin::AudioScrobbler::Plugin::changeAccount;

	wrap('Slim::Plugin::AudioScrobbler::Plugin::changeAccount', \&_changeAccount);

	# The settings page shows the guidance instead of the choice of accounts.
	my $page = wrap('Slim::Plugin::AudioScrobbler::PlayerSettings::handler', sub {
		my ($original, $class, $client, @args) = @_;

		local $nomadSettings = isNomad($client);

		return $original->($class, $client, @args);
	})
	&& wrap('Slim::Plugin::AudioScrobbler::PlayerSettings::page', sub {
		my $original = shift;

		return $nomadSettings ? 'plugins/NomadCompanion/settings/scrobbling.html' : $original->(@_);
	});

	$log->warn("Can't show the scrobbling guidance on Nomad's settings page. Has Lyrion changed?") unless $page;

	# So does the Squeezebox controller menu.
	my $menu;
	$menu = Slim::Control::Request::addDispatch(['audioscrobbler', 'settings'], [1, 1, 0, sub {
		my $request = shift;

		return _guidanceMenu($request) if isNomad($request->client()) || !$menu;
		return $menu->($request);
	}]);

	# Nomad players may have chosen an account before this plugin was installed.
	Slim::Control::Request::subscribe(sub { _turnOff(shift->client()) }, [['client'], ['new', 'reconnect']]);
	_turnOff($_) for Slim::Player::Client::clients();
}

# Lyrion's changeAccount($client, $account), with Nomad players kept at "0".
sub _changeAccount {
	my ($original, $client, $account, @args) = @_;

	my $player = blessed($client) ? $client : Slim::Player::Client::getClient($client);

	if (isNomad($player)) {
		$log->warn('Kept Lyrion from scrobbling ' . $player->name() . '; scrobble from the phone instead') if ($account // '0') ne '0';
		$account = '0';
	}

	return $original->($client, $account, @args);
}

# Turns off Lyrion's scrobbling for $client if it's a Nomad player.
sub _turnOff {
	my $client = shift;

	return unless isNomad($client) && $prefs->client($client)->get('account');

	$log->warn('Turned off Lyrion scrobbling for ' . $client->name() . '; scrobble from the phone instead');

	Slim::Plugin::AudioScrobbler::Plugin::changeAccount($client, '0');
}

sub _guidanceMenu {
	my $request = shift;

	$request->addResult('window', { textarea => $request->string('PLUGIN_NOMADCOMPANION_SCROBBLING') });
	$request->addResult('count', 0);
	$request->setStatusDone();
}

1;
