use ExtUtils::MakeMaker;

WriteMakefile(
	NAME                => 'DBD::Wire10',
	VERSION_FROM        => 'lib/DBD/Wire10.pm',
	PREREQ_PM           => {
		DBI              => 0.0,
		Net::Wire10      => 0.0,
	},
);
