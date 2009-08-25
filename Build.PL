use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
	module_name             => 'DBD::Wire10',
	license                 => 'perl',
	dist_version_from       => 'lib/DBD/Wire10.pm',
	build_requires => {
		'Test::More'         => 0.0,
	},
	requires => {
		'DBI'                => 0.0,
		'Net::Wire10'        => 1.03,
	},
	create_makefile_pl => 'traditional',
);

$builder->create_build_script();
