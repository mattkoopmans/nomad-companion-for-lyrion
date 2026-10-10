package Plugins::NomadCompanion::Hooks;

# Steps into Lyrion's own functions where it offers plugins no other way in.

use strict;

use Exporter qw(import);

our @EXPORT_OK = qw(wrap);

# Replaces function $name with $wrapper, which is passed the original
# function first. Returns false, changing nothing, if $name doesn't exist.
sub wrap {
	my ($name, $wrapper) = @_;

	no strict 'refs';
	no warnings 'redefine';

	return 0 unless defined &$name;

	my $original = \&$name;

	*$name = sub { $wrapper->($original, @_) };

	return 1;
}

1;
