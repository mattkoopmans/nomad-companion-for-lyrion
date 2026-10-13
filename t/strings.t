use strict;
use warnings;
use utf8;

use FindBin;
use Test::More;

# Checks strings.txt: every string in each of Lyrion's main languages, with
# the parts that mustn't be translated kept as they are.

my @languages = qw(CS DA DE EN ES FI FR HU IT NL NO PL RU SV ZH_CN);

# Names stay the same in every language, so only English is needed.
my %englishOnly = map { $_ => 1 } qw(PLUGIN_NOMADCOMPANION);

# Text each translation must keep: placeholders, command values, the app's
# name and the app's own (English) button.
my %kept = (
	PLUGIN_NOMADCOMPANION_DESC            => ['Nomad LMS Player'],
	PLUGIN_NOMADCOMPANION_NOTHING_TO_PLAY => ['%s'],
	PLUGIN_NOMADCOMPANION_BAD_MODE        => ['"replace"', '"append"'],
	PLUGIN_NOMADCOMPANION_SCROBBLING      => ['Sign in to Last.fm', 'Last.fm', 'Nomad'],
	PLUGIN_NOMADCOMPANION_NAME            => ['Nomad', 'Lyrion'],
	PLUGIN_NOMADCOMPANION_AUDIO           => ['ReplayGain', 'Nomad'],
);

open my $file, '<:encoding(UTF-8)', "$FindBin::Bin/../NomadCompanion/strings.txt" or die $!;

my (%strings, $token);
while (my $line = <$file>) {
	chomp $line;
	next if $line eq '';

	if ($line =~ /^(\w+)$/) {
		$token = $1;
		fail("$token appears twice") if $strings{$token};
		$strings{$token} = {};
	}
	elsif ($line =~ /^\t(\w+)\t(.+)$/) {
		fail("$token has $1 twice") if exists $strings{$token}{$1};
		$strings{$token}{$1} = $2;
	}
	else {
		fail("can't read line: $line");
	}
}

for my $token (sort keys %strings) {
	my @expected = $englishOnly{$token} ? ('EN') : @languages;
	is_deeply([ sort keys %{ $strings{$token} } ], [ sort @expected ], "$token: languages");

	for my $text (@{ $kept{$token} || [] }) {
		my @missing = grep { index($strings{$token}{$_}, $text) < 0 } @expected;
		ok(!@missing, "$token: $text kept") or diag("missing in @missing");
	}

	my $placeholders = () = $strings{$token}{EN} =~ /%s/g;
	my @wrong = grep { (() = $strings{$token}{$_} =~ /%s/g) != $placeholders } @expected;
	ok(!@wrong, "$token: placeholders") or diag("wrong in @wrong");
}

done_testing();
