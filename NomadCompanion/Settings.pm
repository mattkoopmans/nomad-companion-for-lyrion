package Plugins::NomadCompanion::Settings;

use strict;

use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.nomadcompanion');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_NOMADCOMPANION');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/NomadCompanion/settings/basic.html');
}

sub prefs {
	return ($prefs, qw(testMode));
}

1;
