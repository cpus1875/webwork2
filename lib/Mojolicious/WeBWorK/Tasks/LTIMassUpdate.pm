###############################################################################
# WeBWorK Online Homework Delivery System
# Copyright &copy; 2000-2023 The WeBWorK Project, https://github.com/openwebwork
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of either: (a) the GNU General Public License as published by the
# Free Software Foundation; either version 2, or (at your option) any later
# version, or (b) the "Artistic License" which comes with this package.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See either the GNU General Public License or the
# Artistic License for more details.
################################################################################

package Mojolicious::WeBWorK::Tasks::LTIMassUpdate;
use Mojo::Base 'Minion::Job', -signatures;

use WeBWorK::Authen::LTIAdvanced::SubmitGrade;
use WeBWorK::Authen::LTIAdvantage::SubmitGrade;
use WeBWorK::CourseEnvironment;
use WeBWorK::DB;

# Perform a mass update of grades via LTI.
sub run ($job, $userID = '', $setID = '') {
	# Establish a lock guard that only allows 1 job at a time (technically more than one could run at a time if a job
	# takes more than an hour to complete).  As soon as a job completes (or fails) the lock is released and a new job
	# can start.  New jobs retry every minute until they can acquire their own lock.
	return $job->retry({ delay => 60 }) unless my $guard = $job->minion->guard('lti_mass_update', 3600);

	my $courseID = $job->info->{notes}{courseID};
	return $job->fail('The course id was not passed when this job was enqueued.') unless $courseID;

	my $ce = eval { WeBWorK::CourseEnvironment->new({ courseName => $courseID }) };
	return $job->fail('Could not construct course environment.') unless $ce;

	$job->{language_handle} = WeBWorK::Localize::getLoc($ce->{language} || 'en');

	my $db = WeBWorK::DB->new($ce->{dbLayout});
	return $job->fail($job->maketext('Could not obtain database connection.')) unless $db;

	# Pass a fake controller object that will work for the grader.
	my $grader =
		$ce->{LTIVersion} eq 'v1p1'
		? WeBWorK::Authen::LTIAdvanced::SubmitGrade->new({ ce => $ce, db => $db, app => $job->app }, 1)
		: WeBWorK::Authen::LTIAdvantage::SubmitGrade->new({ ce => $ce, db => $db, app => $job->app }, 1);

	# Determine what needs to be updated.
	my %updateUsers;
	if ($setID && $userID && $ce->{LTIGradeMode} eq 'homework') {
		$updateUsers{$userID} = [$setID];
	} elsif ($setID && $ce->{LTIGradeMode} eq 'homework') {
		%updateUsers = map { $_ => [$setID] } $db->listSetUsers($setID);
	} else {
		if ($ce->{LTIGradeMode} eq 'course') {
			%updateUsers = map { $_ => 'update_course_grade' } ($userID || $db->listUsers);
		} elsif ($ce->{LTIGradeMode} eq 'homework') {
			%updateUsers = map { $_ => [ $db->listUserSets($_) ] } ($userID || $db->listUsers);
		}
	}

	# Minion does not support asynchronous jobs.  At least if you want notification of job completion.  So call the
	# Mojolicious::Promise wait method instead.
	for my $user (keys %updateUsers) {
		if (ref($updateUsers{$user}) eq 'ARRAY') {
			for my $set (@{ $updateUsers{$user} }) {
				$grader->submit_set_grade($user, $set)->wait;
			}
		} elsif ($updateUsers{$user} eq 'update_course_grade') {
			$grader->submit_course_grade($user)->wait;
		}
	}

	if ($setID && $userID && $ce->{LTIGradeMode} eq 'homework') {
		return $job->finish($job->maketext('Updated grades via LTI for user [_1] and set [_2].', $userID, $setID));
	} elsif ($setID && $ce->{LTIGradeMode} eq 'homework') {
		return $job->finish($job->maketext('Updated grades via LTI all users assigned to set [_1].', $setID));
	} elsif ($userID) {
		return $job->finish($job->maketext('Updated grades via LTI of all sets assigned to user [_1].', $userID));
	} else {
		return $job->finish($job->maketext('Updated grades via LTI for all sets and users.'));
	}
}

sub maketext ($job, @args) {
	return &{ $job->{language_handle} }(@args);
}

1;
