# AppDBAnalyzer.pm
#
# Generates statistics about the appdb for a given date range.
#
# Copyright 2010 Zachary Goldberg
# Copyright 2011 C John Klehm
# Licensed under the AGPL version 3
#
package AppDBAnalyzer;

use strict;
use warnings;
use feature qw(switch say state);
use autodie;

use DateTime::Format::Strptime; # for speed
use Date::Manip; # for ease
use File::Fetch;
use Archive::Extract;
use DBI;

use SugarXML qw(createDocCDATA);

##
# Returns the rank of an apps rating. Lower is better.
#
my $_ratingValue = sub {
    my $rating = shift;

    given ($rating) {
        when (/Platinum/) { return 1; }
        when (/Gold/) {     return 2; }
        when (/Silver/) {   return 3; }
        when (/Bronze/) {   return 4; }
        default {           return 5; }
    }
};


##
# Process the sql result into a string.
#
my $_process = sub {
    my $qu = $_[0];
    my $apps = {};

    while (my $row = $qu->fetchrow_hashref) {
        my $name = $_ratingValue->($row->{"Trating"}) . $row->{"appName"} . " " . $row->{"versionName"};
        my $arrayref = $apps->{$name};

        unless ($arrayref) {
            $arrayref = [];
        }

        push(@$arrayref, $row);
        $apps->{$name} = $arrayref;
    }

    return $apps;
};


##
# Returns the sql query for the maintainer app ratings.
#
my $_maintainerQuery = sub {
    my ($dateFrom, $dateTo) = @_;

    return qq~
        SELECT 
            R.testedRating as "Rrating",
            T.testedRating as "Trating",
            T.versionId as "Tversion",
            R.versionId as "Rversion",
            T.testedDate as "Tdate",
            R.testedDate as "Rdate",
            R.testingId as "RtId",
            T.testingId as "TtId",
            A.versionName as "versionName",
            R.testedRelease as "Rwine",
            T.testedRelease as "Twine",
            F.appName as "appName" 
        FROM 
            testResults T,testResults R,appVersion A, appFamily F, appMaintainers M
        WHERE 
            T.testedDate > "$dateFrom"
            AND T.testedDate < "$dateTo"
            AND R.versionId = T.versionId
            AND R.testedDate < T.testedDate
            AND A.versionId = T.versionID
            AND F.appId = A.appId
            AND R.state = "accepted"
            AND T.state = "accepted"
            AND M.appID = A.appId
            AND M.userId = T.submitterId
            AND T.testedRelease > R.testedRelease
        ORDER BY 
            T.testedDate
    ~;
};


##
# Syncs the appdb with the winehq daily sql dump.
#
my $_updateAppDB = sub {
    my ($self) = @_;
    my $dlDir = $self->{'_downloadDir'};
    my $dumpURI = $self->{'_appdbDumpURI'};
    my $dumpPrefix = $self->{'_appdbDumpPrefix'};
    my $dbName = $self->{'_dbName'};
    my $dbUser = $self->{'_dbUser'};
    my $dbPw = $self->{'_dbPw'};
    my $dbHost = $self->{'_dbHost'};

    # winehq updates the sql tarballs at a given time
    # so we have to grab the previous days if it's before that time.
    my $dateToday = ParseDate('now');
    my $dateAppDBUpdate = Date_SetTime($dateToday, 6, 21, 0);
    my $dateAppDB = $dateToday;

    if (Date_Cmp($dateToday, $dateAppDBUpdate) < 1) {
        $dateAppDB = ParseDate('yesterday');
    } 

    # Compute the file names for everything we need
    my $appDBTimeStamp = &UnixDate($dateAppDB, '%Y%m%d');
    my $appDBFileName = "$dumpPrefix$appDBTimeStamp.tar.gz"; 
    my $appDBFQN = "$dlDir/$appDBFileName";
    my $unzippedAppDBFQN = "$dlDir/appdb.sql";
    my $appDBURI = "$dumpURI/$appDBFileName";

    # Download the appdb sql dump if needed
    unless (-e $appDBFQN) {
        say "Downloading $appDBURI";
        my $ff = File::Fetch->new(uri => $appDBURI);
        $ff->fetch(to => $dlDir) or die $ff->error;

        my $ae = Archive::Extract->new(archive => $appDBFQN);
        $ae->extract(to => $dlDir) or die $ae->error; 

        # Insert the appdb dump into the database
        # FIXME: Not sure if there is a clean way to do this with DBI so we dirty ourselves
        #       with a shellout for now.
        print STDERR `mysql -u $dbUser -p$dbPw -h $dbHost $dbName < $unzippedAppDBFQN`;

        unlink $unzippedAppDBFQN;
    }
};


##
# Takes two dates and compares them.
#
# returns true if first is greater than the second
# false if first is less than or equal to the second
#
my $_compareDates = sub {
    my ($first, $second) = @_;
    my $isFirstGreater = 0;

    state $parser = DateTime::Format::Strptime->new(pattern => '%Y-%m-%d %H:%M:%S');

    my $firstDT = $parser->parse_datetime($first);
    my $secondDT = $parser->parse_datetime($second);

    # compare returns 1 for greater, 0 for equal and -1 for less
    if (DateTime->compare($firstDT, $secondDT) == 1) {
        $isFirstGreater = 1;
    }

    return $isFirstGreater;
};


##
# Returns the numeric value of an apps ranking.
# Higher is better.
#
my $_numC = sub {
    my ($c) = @_;

    given ($c) {
        when ('Garbage') {  return 0; }
        when ('Bronze') {   return 1; }
        when ('Silver') {   return 2; }
        when ('Gold') {     return 3; }
        when ('Platinum') { return 4; }
    }
};


##
# Formats the difference of two numbers in html.
#
my $_getDiff = sub {
    my ($old, $new, $chng) = @_;

    $old = $_numC->($old);
    $new = $_numC->($new);

    my $d = $new - $old;
    $chng += $d;

    my $color = '#000000';
    my $sign = '+';

    if ($d < 0) {
        $sign = '';
        $color = "#990000";
    }

    return (qq~<div style="color: $color;">$sign$d</div>~, $chng);
};


##
# returns true if first is newer than the second
# false if first is older or equal to the second
#
# There are 2 version formats for wine:
# 1) YYYYMMDD
# 2) 1.2.34-rc5
#
# As of the date of writing this function 20110304
# YYYYMMDD versions are always older than
# the 1.2.34-rc5 versions.
#
# After the 2nd period there can be either 1 or 2 digits
# The -rc is signifies sub verions of the 1.2.34
my $_compareWineVer = sub {
    my ($first, $second) = @_;
    my $firstIsPeriodType = 0;
    my $secondIsPeriodType = 0; 

    if ($first =~ /./) {
        $firstIsPeriodType = 1;
    }

    if ($second =~ /./) {
        $secondIsPeriodType = 1;
    }

    # if both versions are the 1.2.34-rc5 type
    if ($firstIsPeriodType and $secondIsPeriodType) {
        # in the example 1.2.34-rc5
        # $1 = 1    Master
        # $2 = 2    Major
        # $3 = 34   Minor 
        # max digits per version type
        my $masterMaxLen = 2;
        my $majorMaxLen = 1;
        my $minorMaxLen = 2;
        my $periodVerRE =   '(\d{1,' . $masterMaxLen . '})' . '\.' .
                            '(\d{1,' . $majorMaxLen  . '})' . '\.' .
                            '(\d{1,' . $minorMaxLen  . '})';

        #grabs the one or two digits from the -rc
        # example 1.2.34-rc5
        # $1 = 5
        #max rc digits
        my $rcMaxLen = 2;
        my $rcRE = '-rc(\d{1,' . $rcMaxLen . '})'; 

        $first =~ /$periodVerRE/;
        my $firstMaster = $1;
        my $firstMajor = $2;
        my $firstMinor = $3;
        my $firstRC = 0; 
        if ($first =~ /$rcRE/) {
            $firstRC = $1;
        }

        $second =~ /$periodVerRE/;
        my $secondMaster = $1;
        my $secondMajor = $2;
        my $secondMinor = $3;
        my $secondRC = 0; 
        if ($second =~ /$rcRE/) {
            $secondRC = $1;
        }

        my $firstAsNum = sprintf(
            "%0${masterMaxLen}d" . "%0${majorMaxLen}d" . "%0${minorMaxLen}d" . "%0${rcMaxLen}d",
            $firstMaster, $firstMajor, $firstMinor, $firstRC);
        my $secondAsNum = sprintf(
            "%0${masterMaxLen}d" . "%0${majorMaxLen}d" . "%0${minorMaxLen}d" . "%0${rcMaxLen}d",
            $secondMaster, $secondMajor, $secondMinor, $secondRC);

        #printf STDERR "first as num: $firstAsNum, second as num: $secondAsNum\n";

        return $firstAsNum > $secondAsNum;
    # second is not due to first if case
    } elsif ($firstIsPeriodType) {
        #period type is always newer
        return 1;
    # first is not due to first if case
    } elsif ($secondIsPeriodType) {
        #period type is always newer
        return 0;
    }

    # both are YYYYMMDD type if we get here
    return $first > $second;
};


##
# Creates an html table displaying app statistics.
#
my $_toChart = sub {
    my ($apps, $doneAlready) = @_;

    my $change = 0;
    my $out = '';

    foreach my $app (sort keys %{$apps}) {
        my $minDate = '1900-01-01 00:00:00';
        my $maxDate = $minDate;
        my $badDate = '0000-00-00 00:00:00';
        my ($oldrating, $newrating, $oldr, $newr);
        my ($oldcolor,$newcolor,$diff,$appname);

        foreach my $tuple ( @{$apps->{$app}} ) {
            my $Rdate = $tuple->{'Rdate'};

            #fix up weird db data
            if ($Rdate eq $badDate) {
                $Rdate = $minDate;
            }

            #debug
            #printf(STDERR "First date: $Rdate, Second date: $maxDate\n");

            if ($_compareDates->($Rdate, $maxDate)) {
                $maxDate   = $tuple->{"Rdate"};
                $oldrating = $tuple->{"Rrating"} . " (" . $tuple->{"Rwine"} . ")";
                $newrating = $tuple->{"Trating"} . " (" . $tuple->{"Twine"} . ")";
                $oldr      = $tuple->{"Rrating"};
                $newr      = $tuple->{"Trating"};
                $appname   = $tuple->{"appName"} . " " . $tuple->{"versionName"};
            }
        }

        my $Twine = $apps->{$app}->[0]->{"Twine"};
        my $Rwine = $apps->{$app}->[0]->{"Rwine"}; 

        if (!$doneAlready->{$app} &&
            $oldr ne $newr &&
            $_compareWineVer->($Twine, $Rwine)) {

            $doneAlready->{$app} = 1;
            $oldcolor = lc($oldr) . "bg.gif";
            $newcolor = lc($newr) . "bg.gif";
            $oldrating =~ s/\.\)/\)/;
            $newrating =~ s/\.\)/\)/;
            ($diff, $change) = $_getDiff->($oldr, $newr, $change);

            if (length($app) > 50) {
                $appname = substr($app, 0, 50) . "...";
            }

            $appname =~ s/\&/\&amp;/g;

            $out .= qq~
                <tr>
                    <td>
                        <a href="http://appdb.winehq.org/objectManager.php?sClass=version&amp;iId=$apps->{$app}->[0]->{"Tversion"}">$appname</a>
                    </td>
                    <td background="{\$root}/images/wwn_$oldcolor">$oldrating</td>
                    <td background="{\$root}/images/wwn_$newcolor">$newrating</td>
                    <td align="center">$diff</td>
                </tr>
            ~;
        }
    }

    my $color = "#000000";
    my $sign  = "+";

    if ($change < 0) {
        $sign = '';
        $color = "#990000";
    }

    $change = qq~<div style="color: $color;">$sign$change</div>~;

    $out .= qq~
            <tr>
                <td colspan="3">Total Change</td>
                <td align="center">$change</td>
            </tr>
        </table>
    ~;

    return $out;
};



##
# Returns the sql query for the user app ratings.
#
my $_userQuery = sub {
    my ($dateFrom, $dateTo) = @_;

    return qq~
        SELECT 
            R.testedRating as "Rrating",
            T.testedRating as "Trating",
            T.versionId as "Tversion",
            R.versionId as "Rversion",
            T.testedDate as "Tdate",
            R.testedDate as "Rdate",
            R.testingId as "RtId",
            T.testingId as "TtId",
            A.versionName as "versionName",
            R.testedRelease as "Rwine",
            T.testedRelease as "Twine",
            F.appName as "appName" 
        FROM
            testResults T,testResults R,appVersion A, appFamily F
        WHERE 
            T.testedDate > "$dateFrom"
            AND T.testedDate < "$dateTo"
            AND R.versionId = T.versionId
            AND R.testedDate < T.testedDate
            AND A.versionId = T.versionID
            AND F.appId = A.appId
            AND R.state = "accepted"
            AND T.state = "accepted"
            AND T.testedRelease > R.testedRelease
        ORDER BY 
            T.testedDate
    ~;
};


##
# Checks for the chagne in application status as set by app mainainers
# and users.
#
my $_analyze = sub {
    my ($self) = @_;
    my $dbName = $self->{'_dbName'};
    my $dbUser = $self->{'_dbUser'};
    my $dbPw = $self->{'_dbPw'};
    my $dbHost = $self->{'_dbHost'};


    # syn with the latest sql dump
    $_updateAppDB->($self);

    my $dsn = "DBI:mysql:$dbName;$dbHost";
    my $dbh = DBI->connect($dsn, $dbUser, $dbPw);

    # Get the app changes by maintainers
    my $query = $_maintainerQuery->($self->{'_dateFrom'}, $self->{'_dateTo'});
    my $qu = $dbh->prepare($query);
    $qu->execute();
    $self->{'_maintApps'} = $_process->($qu);

    # Get the app changes by users
    $query = $_userQuery->($self->{'_dateFrom'}, $self->{'_dateTo'});
    $qu = $dbh->prepare($query);
    $qu->execute();
    $self->{'_userApps'} = $_process->($qu);
};


##
# Constructor
#
# $class    inheriting from.
# $dFrom    The earlier of the date bounds.
# $dTo      The later of the date bounds.
#
sub new {
    my ($class, $dFrom, $dTo, $dlDir, $dbConf, $winehqConf) = @_;

    my $self = {
        _dateFrom       => $dFrom,
        _dateTo         => $dTo,
        _downloadDir    => $dlDir,
        _dbName         => "$dbConf->{'name'}",
        _dbHost         => "$dbConf->{'host'}",
        _dbUser         => "$dbConf->{'user'}",
        _dbPw           => "$dbConf->{'pw'}",
        _appdbDumpURI   => "$winehqConf->{'appdbDumpURI'}",
        _appdbDumpPrefix => "$winehqConf->{'appdbDumpPrefix'}",
        _maintApps      => '',
        _userApps       => '',
        _doneAlready    => {}
    };
    bless($self, $class);

    $_analyze->($self);

    return $self;
}


##
# Returns the appdb stats xml section
#
# FIXME: We really should wrap the stats data in xml and handle
#       the transformation into html on the winehq side of
#       things.
#
sub toXML {
    my ($self) = @_;

    my $data = qq~
        <center><b>AppDB Application Status Changes</b></center>
        <p>
        <i>*Disclaimer: These lists of changes are automatically  generated by information entered into the AppDB.
        These results are subject to the opinions of the users submitting application reviews.  
        The Wine community does not guarantee that even though an application may be upgraded to 'Gold'
        or 'Platinum' in this list, that you will have the same experience and would provide a similar rating.</i>
        </p>
        <div align="center">
        <b><u>Updates by App Maintainers</u></b><br /><br />
        <table width="80%" border="1" bordercolor="#222222" cellspacing="0" cellpadding="3">
            <tr>
                <td><b>Application</b></td>
                <td width="140"><b>Old Status/Version</b></td>
                <td width="140"><b>New Status/Version</b></td>   
                <td width="20" align="center"><b>Change</b></td>
            </tr>
    ~;

    $data .= $_toChart->($self->{'_maintApps'}, $self->{'_doneAlready'});

    $data .= qq~  
        <br />
        <b><u> Updates by the Public </u></b><br />
        <br />
        <table width="80%" border="1" bordercolor="#222222" cellspacing="0" cellpadding="3">
            <tr>
                <td><b>Application</b></td>
                <td width="140"><b>Old Status/Version</b></td>
                <td width="140"><b>New Status/Version</b></td>
                <td width="20"><b>Change</b></td>
           </tr>
    ~;

    $data .= $_toChart->($self->{'_userApps'}, $self->{'_doneAlready'});

    $data .= '</div>';

    my ($doc, $root) = createDocCDATA('1.0', 'UTF-8', 'section', $data,
        title   => 'AppDB Status Changes',
        subject => 'AppDB',
        archive => 'http://appdb.winehq.org',
        posts   => 0
    );

    $root->appendTextChild('topic', 'AppDB');

    return $doc;
}


1;
