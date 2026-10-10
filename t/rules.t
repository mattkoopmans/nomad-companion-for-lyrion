use strict;
use warnings;

use FindBin;
use Test::More;

BEGIN {
	require "$FindBin::Bin/../NomadCompanion/Rules.pm";
	Plugins::NomadCompanion::Rules->import(qw(isNomad isPhoneAddress changesPlayer namedPlayers requestName));
}

# Stand-ins for Lyrion's request and player objects. Lyrion splits a request
# line into the verbs found in its dispatch table and the parameters after
# them, e.g. "favorites playlist play" is verbs "favorites playlist" with
# _method "play". The flags below copy each request's dispatch entry.

package FakeRequest {
	sub new { my ($class, %args) = @_; bless { params => {}, %args }, $class }
	sub getRequestString { join ' ', @{ $_[0]{verbs} } }
	sub getRequest { $_[0]{verbs}[ $_[1] ] }
	sub getParam { $_[0]{params}{ $_[1] } }
	sub query { $_[0]{query} }
	sub needClient { $_[0]{needClient} }
}

package FakeClient {
	sub new { my ($class, %args) = @_; bless {%args}, $class }
	sub modelName { $_[0]{modelName} }
	sub ip { $_[0]{ip} }
}

sub command { FakeRequest->new(verbs => [ split ' ', shift ], params => {@_}, query => 0, needClient => 1) }
sub serverCommand { FakeRequest->new(verbs => [ split ' ', shift ], params => {@_}, query => 0, needClient => 0) }
sub query { FakeRequest->new(verbs => [ split ' ', shift ], params => {@_}, query => 1, needClient => 1) }

subtest 'other devices cannot change the player' => sub {
	my %changes = (
		'play, pause and stop' => [ command('play'), command('pause', _newvalue => 1), command('stop'), command('mode play') ],
		'skipping and jumping' => [ command('playlist jump', _index => '+1'), command('playlist index', _index => 3) ],
		'seeking'              => [ command('time', _newvalue => 90), command('gototime', _newvalue => 90) ],
		'queue edits'          => [
			command('playlist add', _item => 'file:///a.flac'), command('playlist clear'),
			command('playlist move', _fromindex => 1, _toindex => 2), command('playlist shuffle', _newvalue => 1),
			command('playlist repeat', _newvalue => 2), command('playlistcontrol', cmd => 'load', album_id => 7),
		],
		'volume and mute'      => [ command('mixer volume', _newvalue => '+5'), command('mixer muting', _newvalue => 1) ],
		'syncing'              => [ command('sync', '_indexid-' => 'aa:bb:cc:dd:ee:ff') ],
		'remote buttons'       => [ command('button', _buttoncode => 'jump_fwd'), command('ir', _ircode => '7689a05f') ],
		'player settings'      => [ command('power', _newvalue => 0), command('sleep', _newvalue => 600),
		                            command('name', _newvalue => 'Kitchen'), command('playerpref', _prefname => 'transitionType'),
		                            command('alarm', _cmd => 'add'), command('client forget') ],
		'plugins'              => [ command('randomplay', _mode => 'tracks'), command('walkwithme'),
		                            command('material-skin-client', _cmd => 'sort-queue') ],
		'menu play actions'    => [ query('favorites playlist', _method => 'play'), query('browselibrary playlist', _method => 'add'),
		                            query('tidal_browse playlist', _method => 'insert') ],
		'sleep at track end'   => [ query('jiveendoftracksleep') ],
	);

	for my $what (sort keys %changes) {
		ok(changesPlayer($_), "$what: " . requestName($_)) for @{ $changes{$what} };
	}
};

subtest 'other devices can still read from the player' => sub {
	my @reads = (
		query('status', _index => 0, _quantity => 50), query('playlist index'), query('mixer volume'), query('time'),
		query('playlist playlistsinfo'), query('playerpref', _prefname => 'volume'),
		query('favorites items'), query('tidal items'), query('menu'),
		command('playlist save', _title => 'Copy of Nomad'),
		command('material-skin-client', _cmd => 'init'), command('material-skin-client', _cmd => 'get-alarm'),
	);

	ok(!changesPlayer($_), requestName($_)) for @reads;
};

subtest 'server-wide commands are not player control' => sub {
	my @server = (
		serverCommand('favorites add'), serverCommand('playlists delete'), serverCommand('pref', _prefname => 'language'),
		serverCommand('rescan'), serverCommand('material-skin', _cmd => 'transferqueue'),
	);

	ok(!changesPlayer($_), requestName($_)) for @server;
};

subtest 'players named in parameters' => sub {
	my $nomad = '02:00:00:00:00:01';
	my $other = '00:04:20:12:34:56';

	is_deeply([ namedPlayers(command('sync', '_indexid-' => $nomad)) ], [$nomad], 'sync with a player');
	is_deeply([ namedPlayers(command('sync', '_indexid-' => '-')) ], [], 'unsync');
	is_deeply([ namedPlayers(serverCommand('disconnect', _playerid => $nomad, _from => '10.0.0.2')) ], [$nomad], 'disconnect');
	is_deeply(
		[ namedPlayers(serverCommand('material-skin', _cmd => 'transferqueue', from => $nomad, to => $other, mode => 'move')) ],
		[ $other, $nomad ], 'moving a queue changes both players'
	);
	is_deeply(
		[ namedPlayers(serverCommand('material-skin', _cmd => 'transferqueue', from => $nomad, to => $other, mode => 'copy')) ],
		[$other], 'copying a queue only changes the destination'
	);
	is_deeply([ namedPlayers(command('play')) ], [], 'most requests name no player');
};

subtest 'recognising Nomad and its phone' => sub {
	my $nomad = FakeClient->new(modelName => 'Nomad', ip => '100.64.0.7');

	ok(isNomad($nomad), 'Nomad player');
	ok(!isNomad(FakeClient->new(modelName => 'Squeezebox Touch')), 'other player');
	ok(!isNomad(FakeClient->new()), 'player without a model name');
	ok(!isNomad(undef), 'no player');

	ok(isPhoneAddress($nomad, '100.64.0.7'), 'same address');
	ok(isPhoneAddress($nomad, '::ffff:100.64.0.7'), 'same address mapped into IPv6');
	ok(!isPhoneAddress($nomad, '192.168.0.20'), 'another device');
	ok(!isPhoneAddress($nomad, undef), 'no address');
};

done_testing();
