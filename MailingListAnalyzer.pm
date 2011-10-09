#
# MailingListAnalyzer.pm
# Downloads mailmain archives that fall into a given date range and 
# records statistics.
#
# Copyright 2011 C John Klehm
# Licensed under the AGPL version 3
#
package MailingListAnalyzer;
use strict;
use warnings;
use feature qw(switch say state);
use autodie;

use File::Fetch;
use Archive::Extract;
use Encode 'decode';
use Date::Manip;
use POSIX 'floor';

use SugarXML qw(createDoc addNode);


##
# Read in a given mailing list archive file and track the following:
# * Number of messages per user
# * Size of all messages per user
# * Total number of messages in date range
# * Total size of all messages in date range
#
# FIXME: The last message body is likely not captured accurately
#        Since we look for the next messages From line to signify
#        The end of the message.  I'm not sure how to work around
#        this though :S perhaps. \z matches EOF???
#        Even givent his caveat we're much more careful now than
#        the bash script
# 
# This is a sample header (START END):
# START
# From mstefani at redhat.com  Thu Jun 10 06:14:19 2010
# From: mstefani at redhat.com (Michael Stefaniuc)
# Date: Thu, 10 Jun 2010 13:14:19 +0200
# Subject: winefile: Update English resource for AUS, NZ and UK
# In-Reply-To: <4C104B64.9010009@o2.co.uk>
# References: <4C104B64.9010009@o2.co.uk>
# Message-ID: <4C10C90B.2040500@redhat.com>
# ....BODY....
# END
#
my $_parseArchive = sub {
    my ($self, $fileName, $monthName) = @_;

    # From: mstefani at redhat.com (Michael Stefaniuc)
    # $1 = email address
    state $authorFlag = '^From: +?(.+?)\n';

    # nothing stored
    state $bodyFlag = '^Message-ID: <.*?>\n';

    # From line at start of new message with date ex:
    # From mstefani at redhat.com  Thu Jun 10 06:14:19 2010
    # From julliard at winehq.org  Sun May  9 12:23:00 2010
    # nothing stored
    state $dayOfWeekRE = '(?:Sun|Mon|Tue|Wed|Thu|Fri|Sat)';
    # Jun 10
    # May  9
    # nothing stored
    my $monthStampRE = "$monthName {1,2}\\d{1,2}";
    # 06:14:19 2010
    # 12:23:00 2010
    # nothing stored
    state $timeStampRE = '\d{2}:\d{2}:\d{2} \d{4}'; 
    # All together
    my $dateFlag = "$dayOfWeekRE ($monthStampRE $timeStampRE)\n";

    #end of message.  wish there was something better :S
    state $endFlag = "\n\nFrom ";

    # $1 = date
    # $2 = email address
    # $3 = message body
    my $messageRE = "$dateFlag$authorFlag.*?$bodyFlag(.*?)$endFlag";

    # slurp the file into a string
    my $archive = do {
        local $/ = undef;
        open(my $fh, '<:utf8', $fileName);
        <$fh>;
    };

    # track each message in the stats data
    while ($archive =~ m/$messageRE/smg) {
        my $date = &ParseDate($1);
        my $from = $2;
        my $body = $3;

        # if within desired date range
        if ((&Date_Cmp($date, $self->{_dateFrom}) > -1) and
            ((&Date_Cmp($date, $self->{_dateTo})  <  1) )) {

            my $author = &decode('MIME-Header', $from);
            my $bodySizeInKB = (length($body) * $self->{_bytesPerChar}) / 1024;

            ++$self->{_listStats}->{totalMessages};
            $self->{_listStats}->{totalSize} += $bodySizeInKB;

            #FIXME: Add handling of aliases

            # saw this author before
            if (exists($self->{_authorStats}->{$author})) {

                ++$self->{_authorStats}->{$author}->{posts};
                $self->{_authorStats}->{$author}->{size} += $bodySizeInKB;
                
                if ($self->{_authorStats}->{$author}->{posts} == 2) {
                    ++$self->{_listStats}->{totalRepeatAuthors};
                }

            # a new author
            } else {
                ++$self->{_listStats}->{totalAuthors}; 

                $self->{_authorStats}->{$author} = {
                    posts => 1,
                    size => $bodySizeInKB                   
                };
            }
        }
    }
};


##
# Download the mailing list archives that fall inside the given date range.
# Then create statistics by parsing each file.
#
my $_analyze = sub {
    my ($self) = @_;

    my $dateFrom = ParseDate($self->{'_dateFrom'});
    my $dateTo   = ParseDate($self->{'_dateTo'});

    for (my $dateIter = $dateFrom; &Date_Cmp($dateIter, $dateTo) < 1;
        $dateIter = &DateCalc($dateIter, "+ 1month")) {

        my $nameRoot = &UnixDate($dateIter, '%Y-%B');
        my $monthNameAbrv = &UnixDate($dateIter, '%b');

        my $fileName = "$nameRoot.txt.gz";

        my $dlDir = $self->{'_downloadDir'};
        my $downloadURI = "$self->{'_archiveRootURI'}/$fileName";
        my $fileLocalFQN = "$dlDir/$fileName";
        my $unzippedLocalFQN = "$dlDir/$nameRoot.txt";
        

        unless (-e $fileLocalFQN) {
            say "Downloading $downloadURI<br />";
            my $ff = File::Fetch->new(uri => $downloadURI);

            unless ($ff->fetch(to => $dlDir)) {
                say $ff->error;
                die $ff->error;
            }

        } else {
            say "Using cached $fileLocalFQN<br />";
        }

        my $ae = Archive::Extract->new(archive => $fileLocalFQN);
        my $ok = $ae->extract(to => $self->{'_downloadDir'}) or die $ae->error;

        $_parseArchive->($self, $unzippedLocalFQN, $monthNameAbrv);

        # delete the unzipped version to save disk space, keep compressed copy to save bandwidth
        unlink($unzippedLocalFQN) or say(STDERR "Could not delete: $unzippedLocalFQN");
    }
};


##
# Constructor
#
# class Inheriting from
# dFrom The earlier(lower) of the two date bounds.
# dTo   The later(upper) of the two date bounds.
# archRoot The base URI of where the archives will be downloaded from.
# dlDir The directory to store downloaded files.
#
sub new {
    my ($class, $dFrom, $dTo, $archRoot, $dlDir) = @_;

    my $self = {
        _dateFrom => $dFrom,
        _dateTo   => $dTo,
        _archiveRootURI => $archRoot,
        _downloadDir    => $dlDir,
        _bytesPerChar   => 1,
        _listStats => {
            totalMessages => 0,
            totalSize     => 0,
            totalAuthors  => 0,
            totalRepeatAuthors => 0
        },
        _authorStats => {
            # $authorEmail => {
            #        posts => 0,
            #        size  => 0
            # }
        }
    };
    bless($self, $class);

    $_analyze->($self);

    return $self;        
}


##
# Should give the stats xml structure
#
# <stats posts="1" size="1" contrib="1" multiples="1" lastweek="1">\n
#   <person posts="1" size="1" who="john@smith.com"/>\n
# </stats>\n
#
sub toXML {
    my ($self) = @_;

    my $totalPosts = $self->{_listStats}->{totalMessages};
    my $size = floor($self->{_listStats}->{totalSize});
    my $contrib = $self->{_listStats}->{totalAuthors};
    my $multiples = $self->{_listStats}->{totalRepeatAuthors};
    #FIXME: last week
    my $lastweek = 0;


    my ($doc, $root) = createDoc('1.0', 'UTF-8', 'stats', '',
        posts       => $totalPosts,
        size        => $size,
        contrib     => $contrib,
        multiples   => $multiples,
        lastweek    => $lastweek
    );

    my $aStats = $self->{_authorStats};
    for my $who (sort keys %{$self->{_authorStats}}) {

        my $posts = $aStats->{$who}->{posts};
        my $size = floor($aStats->{$who}->{size});

        addNode($doc, $root, 'person', '',
            posts => $posts,
            size  => $size,
            who   => $who
        );
    }

    return $doc;
}

1;
