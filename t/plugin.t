use strict;
use warnings;

use FindBin;
use Test::More;

# Runs requests through the plugin's hooks the way Lyrion would, using
# stand-ins for the few parts of Lyrion the plugin touches.

our (%dispatched, @executed, @logged);

package Slim::Plugin::Base {
	sub _pluginDataFor { $_[1] eq 'version' ? '0.2.0' : undef }
}

package Slim::Control::Request {
	sub addDispatch { $main::dispatched{ join ' ', @{ $_[0] } } = $_[1] }

	sub new {
		my ($class, %args) = @_;
		return bless { verbs => [], params => {}, results => {}, query => 0, needClient => 1, %args }, $class;
	}

	# Lyrion's own execute: runs the request, including any requests it makes.
	sub execute {
		my $request = shift;
		push @main::executed, $request;
		$request->{run}->() if $request->{run};
	}

	sub source { $_[0]{source} }
	sub connectionID { $_[0]{connectionID} }
	sub client { Slim::Player::Client::getClient($_[0]{clientid}) }
	sub getRequestString { join ' ', @{ $_[0]{verbs} } }
	sub getRequest { $_[0]{verbs}[ $_[1] ] }
	sub getParam { $_[0]{params}{ $_[1] } }
	sub query { $_[0]{query} }
	sub needClient { $_[0]{needClient} }
	sub isNotQuery { 0 }
	sub addResult { $_[0]{results}{ $_[1] } = $_[2] }
	sub setStatusDone { $_[0]{status} = 'done' }
	sub executeDone { $_[0]{answered}++ }
}

package Slim::Player::Client {
	our %players;
	sub getClient { defined $_[0] ? $players{ $_[0] } : undef }
	sub clients { map { $players{$_} } sort keys %players }
}

package Slim::Utils::Log {
	sub addLogCategory { bless {}, 'FakeLog' }
}

package FakeLog {
	sub warn { push @main::logged, $_[1] }
	sub error { push @main::logged, "error: $_[1]" }
}

package Slim::Utils::Prefs {
	our %values;
	sub import { no strict 'refs'; *{ caller() . '::preferences' } = sub { bless {}, 'FakePrefs' } }
}

package FakePrefs {
	sub init { my ($self, $defaults) = @_; $Slim::Utils::Prefs::values{$_} //= $defaults->{$_} for keys %$defaults }
	sub get { $Slim::Utils::Prefs::values{ $_[1] } }
}

package Slim::Utils::Strings {
	sub import { no strict 'refs'; *{ caller() . '::string' } = \&string }
	sub string { $_[0] }
}

# The classic web interface: runs $handler as if handling a page request.
package Slim::Web::HTTP {
	our %peeraddr;
	sub processURL { my ($httpClient, $handler) = @_; $handler->() }
}

package Slim::Web::Cometd::Manager {
	sub register_connection {}
	sub remove_client {}
}

package FakeSocket {
	sub new { my ($class, $address) = @_; bless { address => $address }, $class }
	sub peerhost { $_[0]{address} }
}

package FakePlayer {
	sub new { my ($class, %args) = @_; bless { synced => [], %args }, $class }
	sub id { $_[0]{id} }
	sub name { $_[0]{name} }
	sub modelName { $_[0]{modelName} }
	sub ip { die "no address\n" if $_[0]{noAddress}; $_[0]{ip} }
	sub syncedWith { @{ $_[0]{synced} } }
}

package main;

$INC{$_} = 1 for qw(Slim/Plugin/Base.pm Slim/Control/Request.pm Slim/Player/Client.pm Slim/Player/Playlist.pm
                    Slim/Player/Source.pm Slim/Player/StreamingController.pm Slim/Utils/Log.pm Slim/Utils/Prefs.pm
                    Slim/Utils/Strings.pm Slim/Web/Cometd/Manager.pm Slim/Web/HTTP.pm);

for my $module (qw(Rules Transfer)) {
	require "$FindBin::Bin/../NomadCompanion/$module.pm";
	$INC{"Plugins/NomadCompanion/$module.pm"} = 1;
}

require "$FindBin::Bin/../NomadCompanion/Plugin.pm";

Plugins::NomadCompanion::Plugin->initPlugin();

my $phone  = '100.64.0.7';
my $laptop = '192.168.1.50';

my $nomad   = FakePlayer->new(id => '02:00:00:00:00:01', name => 'Test phone [Nomad]', modelName => 'Nomad', ip => $phone);
my $kitchen = FakePlayer->new(id => '00:04:20:12:34:56', name => 'Kitchen', modelName => 'Squeezebox Touch', ip => '192.168.1.60');

sub setPlayers { %Slim::Player::Client::players = map { $_->id => $_ } @_ }
setPlayers($nomad, $kitchen);

# A request as Lyrion builds it: aimed at $player, with its verbs, sent from
# $source ("JSONRPC" and so on, or undef for Lyrion's own).
sub request {
	my ($player, $verbs, %args) = @_;
	return Slim::Control::Request->new(clientid => $player && $player->id, verbs => [ split ' ', $verbs ], %args);
}

sub jsonrpc {
	my ($address, $player, $verbs, %args) = @_;
	my $socket = FakeSocket->new;
	$Slim::Web::HTTP::peeraddr{$socket} = $address;
	return request($player, $verbs, source => 'JSONRPC', connectionID => $socket, %args);
}

sub ran { my $request = shift; return scalar grep { $_ == $request } @executed }

sub refused {
	my ($request, $name) = @_;
	subtest $name => sub {
		ok(!ran($request), 'not run');
		is($request->{results}{error}, 'PLUGIN_NOMADCOMPANION_REFUSED', 'answered with an error');
		is($request->{answered}, 1, 'answered once');
	};
}

sub run { @executed = (); $_[0]->execute(); return $_[0] }

subtest 'JSON-RPC' => sub {
	refused(run(jsonrpc($laptop, $nomad, 'pause')), 'another device pausing Nomad');
	like($logged[-1], qr/Refused "pause" for Test phone \[Nomad\] from 192\.168\.1\.50/, 'refusal logged');

	ok(ran(run(jsonrpc($phone, $nomad, 'pause'))), 'the phone pausing Nomad');
	ok(ran(run(jsonrpc($laptop, $nomad, 'status', query => 1))), 'another device reading Nomad');
	ok(ran(run(jsonrpc($laptop, $kitchen, 'pause'))), 'another device pausing another player');
	ok(ran(run(request($nomad, 'pause'))), "Lyrion's own request");
	ok(ran(run(request($nomad, 'pause', source => 'ALARM'))), "Lyrion's alarm");

	refused(run(jsonrpc($laptop, $nomad, 'favorites playlist', query => 1, params => { _method => 'play' })), 'playing a favourite on Nomad');
	refused(run(jsonrpc(undef, $nomad, 'pause')), 'a device whose address is unknown');
	refused(run(jsonrpc("::ffff:$laptop", $nomad, 'pause')), 'another device over IPv6');
	ok(ran(run(jsonrpc("::ffff:$phone", $nomad, 'pause'))), 'the phone over IPv6');
};

subtest 'command-line interface' => sub {
	refused(run(request($nomad, 'pause', source => 'CLI', connectionID => FakeSocket->new($laptop))), 'another device');
	ok(ran(run(request($nomad, 'pause', source => 'CLI', connectionID => FakeSocket->new($phone)))), 'the phone');
};

subtest 'Cometd' => sub {
	Slim::Web::Cometd::Manager->register_connection('abcd1234', [ FakeSocket->new($laptop) ]);
	Slim::Web::Cometd::Manager->register_connection('0123beef', FakeSocket->new($phone));

	my $cometd = sub { my $clid = shift; request($nomad, 'pause', source => "/$clid/slim/request|1||$clid|SqueezePlay") };

	refused(run($cometd->('abcd1234')), 'another device');
	ok(ran(run($cometd->('0123beef'))), 'the phone, over the command-line interface');
	refused(run($cometd->('99999999')), 'a client that never connected');

	Slim::Web::Cometd::Manager->remove_client('0123beef');
	refused(run($cometd->('0123beef')), 'a client that has gone');
};

subtest 'classic web interface' => sub {
	my $page = sub {
		my $address = shift;
		my $socket  = FakeSocket->new;
		$Slim::Web::HTTP::peeraddr{$socket} = $address;

		my $request = request($nomad, 'pause');
		Slim::Web::HTTP::processURL($socket, sub { run($request) });
		return $request;
	};

	refused($page->($laptop), 'another device');
	ok(ran($page->($phone)), 'the phone');
	ok(ran(run(request($nomad, 'pause'))), 'Lyrion afterwards');
};

subtest 'requests made while another runs' => sub {
	my $walkWithMe = sub {
		my $address = shift;
		my $inner = request($nomad, 'playlist play');
		my $outer = jsonrpc($address, $kitchen, 'walkwithme', run => sub { $inner->execute() });
		run($outer);
		return ($outer, $inner);
	};

	my ($outer, $inner) = $walkWithMe->($laptop);
	ok(ran($outer), "another device's request to another player runs");
	refused($inner, '... but not its change to Nomad');

	($outer, $inner) = $walkWithMe->($phone);
	ok(ran($inner), "the phone's runs in full");

	ok(ran(run(request($nomad, 'pause'))), "Lyrion's own request afterwards");
};

subtest 'players named rather than aimed at' => sub {
	refused(run(jsonrpc($laptop, $kitchen, 'sync', params => { '_indexid-' => $nomad->id })), 'syncing another player with Nomad');
	refused(run(jsonrpc($laptop, $kitchen, 'sync', params => { '_indexid-' => 1 })), '... by player number');
	refused(run(jsonrpc($laptop, $nomad, 'sync', params => { '_indexid-' => '-' })), 'unsyncing Nomad itself');
	ok(ran(run(jsonrpc($laptop, $kitchen, 'sync', params => { '_indexid-' => '-' }))), 'unsyncing another player');
	refused(run(jsonrpc($laptop, undef, 'material-skin', needClient => 0,
		params => { _cmd => 'transferqueue', from => $kitchen->id, to => $nomad->id, mode => 'copy' })), 'copying a queue onto Nomad');
};

subtest 'players synced with Nomad' => sub {
	$kitchen->{synced} = [$nomad];

	refused(run(jsonrpc($laptop, $kitchen, 'pause')), 'another device pausing the group');
	ok(ran(run(jsonrpc($phone, $kitchen, 'pause'))), 'the phone pausing the group');
	ok(ran(run(jsonrpc($laptop, $kitchen, 'status', query => 1))), 'another device reading the group');

	$kitchen->{synced} = [];
};

subtest 'a failed check lets the request through' => sub {
	local $nomad->{noAddress} = 1;

	ok(ran(run(jsonrpc($laptop, $nomad, 'pause'))), 'request runs');
	like($logged[-1], qr/^error: Couldn't check a request/, 'error logged');
};

subtest 'test mode' => sub {
	refused(run(jsonrpc('127.0.0.1', $nomad, 'pause')), 'this computer, while test mode is off');

	local $Slim::Utils::Prefs::values{testMode} = 1;

	ok(ran(run(jsonrpc('127.0.0.1', $nomad, 'pause'))), 'this computer, while test mode is on');
	ok(ran(run(jsonrpc('::ffff:127.0.0.1', $nomad, 'pause'))), '... over IPv6');
	refused(run(jsonrpc($laptop, $nomad, 'pause')), 'another device, while test mode is on');
};

subtest 'commands' => sub {
	ok($dispatched{"nomad $_"}, "nomad $_") for qw(takeover copy send);
	refused(run(jsonrpc($laptop, $nomad, 'nomad takeover', params => { player => $kitchen->id })), 'another device moving music into Nomad');
	refused(run(jsonrpc($laptop, $nomad, 'nomad send', params => { player => $kitchen->id })), 'another device sending Nomad\'s music away');
};

subtest 'version' => sub {
	my $request = Slim::Control::Request->new;
	$dispatched{'nomad version ?'}->[3]->($request);
	is($request->{results}{_version}, '0.2.0', 'reported');
	is($request->{results}{_test_mode}, 0, 'test mode reported');
	is($request->{status}, 'done', 'done');
};

done_testing();
