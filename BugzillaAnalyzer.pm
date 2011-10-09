# BugzillaAnalyzer.pm
#
# Downloads a generated csv file from bugzilla tracks statistics
# based on the given dates.
#
# Copyright 2011 C John Klehm
# Licensed under the AGPL version 3
#
package BugzillaAnalyzer;

use strict;
use warnings;
use feature qw(switch say state);
use autodie;

use File::Fetch;
use Date::Manip;

use SugarXML qw(createDocCDATA);


##
# Returns the URI for the desired bugzilla stats.
#
my $_getReportURI = sub {
    my ($date) = @_;

    # generated by messing around with the bugzilla reporting tool.
    my $uri = qq~http://bugs.winehq.org/report.cgi?bug_file_loc=&bug_file_loc_type=allwordssubstr&bug_id=&bug_status=UNCONFIRMED&bug_status=NEW&bug_status=ASSIGNED&bug_status=REOPENED&bug_status=RESOLVED&bug_status=CLOSED&bugidtype=include&chfieldfrom=&chfieldto=~;
    $uri .= qq~$date~;
    $uri .= qq~&chfieldvalue=&email1=&email2=&emailassigned_to1=1&emailassigned_to2=1&emailcc2=1&emailreporter2=1&emailtype1=substring&emailtype2=substring&field0-0-0=%255BBug%2Bcreation%255D&keywords=&keywords_type=allwords&long_desc=&long_desc_type=substring&short_desc=&short_desc_type=allwordssubstr&status_whiteboard=&status_whiteboard_type=allwordssubstr&type0-0-0=noop&value0-0-0=&votes=&x_axis_field=&y_axis_field=bug_status&z_axis_field=&width=600&height=350&action=wrap&ctype=csv&format=table~;

    return $uri;
};

##
# Downloads the bugzilla stats and then returns contents as an array.
#
my $_fetchStats = sub {
    my ($fileName, $date, $dlDir) = @_;

    # Download the bugzilla stats for this date if we need to.
    unless (-e $fileName) {
        my $ff = File::Fetch->new(uri => $_getReportURI->($date));
        my $where = $ff->fetch(to => $dlDir) or die $ff->error; 
        rename($where, $fileName);
    }

    # slurp file contents into a string
    my $bugsStatsData = do {
        local $/ = undef;
        open(my $fh, '<:utf8', $fileName) or die "Could not open $fileName.\n";
        <$fh>;
    };

    return split(/\n/, $bugsStatsData);
};

##
# Cleans up and organizes the stats into a hash.
# 
# "CLOSED",18000 becomes
# $self->{'_issueStart'}{'CLOSED'} == 18000;
# 
my $_analyze = sub {
    my ($self) = @_;

    my $dlDir = $self->{'_downloadDir'};

    # Compute the file names we need
    my $dateBugsFrom = &ParseDate($self->{'_dateFrom'});
    my $fromBugsTimeStamp = &UnixDate($dateBugsFrom, '%Y%m%d');
    my $fromBugsStatsFQN = "$dlDir/bugzilla-stats-$fromBugsTimeStamp.csv";

    my $dateBugsTo = &ParseDate($self->{'_dateTo'});
    my $toBugsTimeStamp = &UnixDate($dateBugsTo, '%Y%m%d');
    my $toBugsStatsFQN = "$dlDir/bugzilla-stats-$toBugsTimeStamp.csv";

    # grab the stats data from the server
    my @dataTo = $_fetchStats->($toBugsStatsFQN, $toBugsTimeStamp, $dlDir);
    my @dataFrom = $_fetchStats->($fromBugsStatsFQN, $fromBugsTimeStamp, $dlDir);

    # drop the first line of the data since it's just headings
    shift @dataTo;
    shift @dataFrom;

    # parse the csv string
    # csv "CLOSED",18000 becomes
    # $self->{'_issueStart'}{'CLOSED'} == 18000;
    # matches CLOSED and 1800
    my $csvLineRE = '"(\w+)",(\d+)$';
    foreach my $line (@dataTo) {
       $line =~ /$csvLineRE/ or die "Bad CSV file format\n";
        my $category = $1;
        my $numBugs  = $2;

        $self->{'_issueEnd'}{$category} = $numBugs;
    }
    foreach my $line (@dataFrom) {
       $line =~ /$csvLineRE/ or die "Bad CSV file format.\n";
        my $category = $1;
        my $numBugs  = $2;

        $self->{'_issueStart'}{$category} = $numBugs;
    }

    # Check for missing categories
    foreach my $curCat (@{$self->{'_categoriesAll'}}) {

        # if the data is missing a category we assume that means it was zero
        if (not exists($self->{'_issueEnd'}{$curCat})) {
            $self->{'_issueEnd'}{$curCat} = 0;
        }

        if (not exists($self->{'_issueStart'}{$curCat})) {
            $self->{'_issueStart'}{$curCat} = 0;
        }
    }

    # Record totals and net changes
    foreach my $curCat (@{$self->{'_categoriesAll'}}) {
        my $endIssueCatVal = $self->{'_issueEnd'}{$curCat};
        my $startIssueCatVal = $self->{'_issueStart'}{$curCat};

        # track the category totals
        $self->{'_issueStart'}{'total'} += $startIssueCatVal;
        $self->{'_issueEnd'}{'total'}   += $endIssueCatVal;

        # category net changes
        $self->{'_netChange'}{$curCat} = $endIssueCatVal - $startIssueCatVal; 
    }
    
    # Record total open
    foreach my $curCat (@{$self->{'_categoriesOpen'}}) {
        my $endIssueCatVal = $self->{'_issueEnd'}{$curCat};
        my $startIssueCatVal = $self->{'_issueStart'}{$curCat};

        $self->{'_issueEnd'}{'totalOpen'}   += $endIssueCatVal;
        $self->{'_issueStart'}{'totalOpen'} += $startIssueCatVal;
    }

    # net change total open and net change total
    $self->{'_netChange'}{'total'} = $self->{'_issueEnd'}{'total'} - $self->{'_issueStart'}{'total'};
    $self->{'_netChange'}{'totalOpen'} = $self->{'_issueEnd'}{'totalOpen'} - $self->{'_issueStart'}{'totalOpen'};
};


##
# Constructor
#
# class Inheriting from
# dFrom The earlier (lower) of the two date bounds.
# dTo   The later (upper) of the two date bounds.
# dlDir The directory to store downloaded files.
#
sub new {
    my ($class, $dFrom, $dTo, $dlDir) = @_;

    my $self = {
        _dateFrom => $dFrom,
        _dateTo   => $dTo,
        _downloadDir => $dlDir,
        _categoriesOther => ['RESOLVED', 'CLOSED'],
        _categoriesOpen  => ['UNCONFIRMED', 'NEW', 'ASSIGNED', 'REOPENED'],
        _categoriesAll   => [],
        _issueStart => {
            # $categoryName => $numBugs
            totalOpen       => 0,
            total           => 0
        },
        _issueEnd => {
            # $categoryName => $numBugs
            totalOpen       => 0,
            total           => 0
        },
        _netChange => {
            # $categoryName => $netBugs
            totalOpen       => 0,
            total           => 0
        }
    };
    bless($self, $class);
    push(@{$self->{'_categoriesAll'}}, @{$self->{'_categoriesOpen'}});
    push(@{$self->{'_categoriesAll'}}, @{$self->{'_categoriesOther'}});

    $_analyze->($self);

    return $self;
}


##
# Gives the stats xml structure.
#
# TODO: Really should pass the stats back in xml not html and then handle
# the handle the transform on the winehq side of things.
# 
# <section>
#   <topic></topic>
#   <table>All my html stat stuff</table>
# </section>
#
sub toXML {
    my ($self) = @_;

    # Add '+' in front of positive net values.
    while (my ($key, $value) = each %{$self->{'_netChange'}}) {
        if ($value > 0) {
            $self->{'_netChange'}{$key} = sprintf('%+d', $value); 
        }
    }

    my $data = qq~
        <center><b>Bugzilla Changes:</b></center>
        <p align="center">
            <table border="1" bordercolor="#222222" cellspacing="0" cellpadding="3">
                <tr>
                    <th align="center"><b>Category</b></td>
                    <th align="center"><b>Total Bugs Last Issue</b></td>
                    <th align="center"><b>Total Bugs This Issue</b></td>
                    <th align="center"><b>Net Change</b></td>
                </tr>
    ~;

    foreach my $curCat (@{$self->{'_categoriesAll'}}) {
        $data .= qq~
                <tr>
                    <td>$curCat</td>
                    <td>$self->{'_issueStart'}{$curCat}</td>
                    <td>$self->{'_issueEnd'}{$curCat}</td>
                    <td>$self->{'_netChange'}{$curCat}</td>
                </tr>
        ~;
    }

    $data .= qq~
                <tr>
                    <td>TOTAL OPEN</td>
                    <td>$self->{'_issueStart'}{'totalOpen'}</td>
                    <td>$self->{'_issueEnd'}{'totalOpen'}</td>
                    <td>$self->{'_netChange'}{'totalOpen'}</td>
                </tr>
                <tr>
                    <td>TOTAL</td>
                    <td>$self->{'_issueStart'}{'total'}</td>
                    <td>$self->{'_issueEnd'}{'total'}</td>
                    <td>$self->{'_netChange'}{'total'}</td>
                </tr>
            </table>
        </p>
    ~;

    my ($doc, $root) = createDocCDATA('1.0', 'UTF-8', 'section', $data,
        title => 'Bugzilla Status Changes',
        subject => 'Bugzilla',
        archive => 'http://bugs.winehq.org',
        posts => '0'
    );
    
    $root->appendTextChild('topic', 'Bugzilla');

    return $doc;
}


1;
