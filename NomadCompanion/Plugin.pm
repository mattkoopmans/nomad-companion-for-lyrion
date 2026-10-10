package Plugins::NomadCompanion::Plugin;

# Server side of Nomad Player: lets only the phone running Nomad control its
# player. Plugins::NomadCompanion::Rules defines what counts as control.

use strict;
use base qw(Slim::Plugin::Base);

use Slim::Control::Request;

use Plugins::NomadCompanion::Rules;

sub initPlugin {
	my $class = shift;

	# "nomad version ?" tells the app that the plugin is installed, and which
	# version, for its settings screen.
	#                                                              |requires Client
	#                                                              |  |is a Query
	#                                                              |  |  |has Tags
	#                                                              |  |  |  |Function to call
	#                                                              C  Q  T  F
	Slim::Control::Request::addDispatch(['nomad', 'version', '?'], [0, 1, 0, \&versionQuery]);
}

sub versionQuery {
	my $request = shift;

	if ($request->isNotQuery([['nomad'], ['version']])) {
		$request->setStatusBadDispatch();
		return;
	}

	$request->addResult('_version', __PACKAGE__->_pluginDataFor('version'));
	$request->setStatusDone();
}

1;
