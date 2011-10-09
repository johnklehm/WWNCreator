#!/usr/bin/env perl
# wwncreator.pl
# The Wine World News xml editor/creator.
#
# Copyright 2010 Zachary Goldberg
# Copyright 2011 C John Klehm
# Licensed under the AGPL version 3
#
use strict;
use warnings;
use feature qw(switch say state);
use autodie;

use Date::Manip;
use HTML::Entities;
use File::Copy;

use MailingListAnalyzer;
use BugzillaAnalyzer;
use AppDBAnalyzer;
use SugarXML qw(createDoc addNode addNodeCDATA prependNode);

# Default to UTF8
#
binmode STDIN,  ':utf8';
binmode STDOUT, ':utf8';
binmode STDERR, ':utf8';

# issue defaults
my $DEFAULT_AUTHOR     = "John Klehm";
my $DEFAULT_AUTHOR_URL = "http://wiki.winehq.org/JohnKlehm";
my $DEFAULT_GOAL       = "spread the Wine news.";

# script config
my $BASE_ROOT    = "wwn-creator";
my $BASE_URL     = "http://klehm.net/$BASE_ROOT";
my $BASE_PATH    = "/var/www/localhost/drupal/$BASE_ROOT";
my $DOWNLOAD_DIR = "$BASE_PATH/download";

# winehq config
my $WINEHQCONF = {
    wwnDir => '/var/www/localhost/drupal/winehq/wwn/en',
    url    => 'http://klehm.net/winehq',
    archiveURI => 'http://www.winehq.org/pipermail/wine-devel',
    appdbDumpURI   => 'ftp://ftp.winehq.org/pub/wine',
    appdbDumpPrefix => 'wine-appdb-'
};

# db config
my $DBCONF  = {
    name => 'wwn_appdb_stats',
    host => 'localhost',
    user => 'DBUSER',
    pw   => 'DBPASSWORD'
};

# FIXME indented xml output that would make compatible patches with old issues
# libxml tries to indent kind of but screws up sometimes.
#  probably need to run the completed xml through
# another library to get something human readable consistently
my $xmlFormatting = 1;

my $dateToday = ParseDate("today"); 
my $yearMonDayStr = UnixDate($dateToday, '%Y%m%d');
my $blurbFileName = $yearMonDayStr . "01.xml";

# template for issue name
my $xmlTempIssueFQN  = "$DOWNLOAD_DIR/wn$yearMonDayStr" . "_XXX.xml";
my $xmlBlurbFQN = "$DOWNLOAD_DIR/$blurbFileName";

state $br = "<br />";

############
### MAIN ###
############

my %FORM = parse_env();

given ($FORM{'a'}) {
    when ('new')      { header(); new_wwn();                footer(); }
    when ('create')   { header(); create_wwn(); edit_wwn(); footer(); }
    when ('save')     { header(); save_wwn();   edit_wwn(); footer(); }
    when ('stats')    { header(); stats_wwn();  edit_wwn(); footer(); }
    when ('edit')     { header();               edit_wwn(); footer(); }
    when ('view')     { view_wwn(); }
    default           { header(); choose_wwn();             footer(); }
}

################
### END MAIN ###
################


##
# Header stuff
# Mime type, all opening html etc
#
sub header {

print "Content-Type: application/xhtml+xml; charset=utf-8\n\n";

print qq~<?xml version="1.0" encoding="utf-8" ?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">
<head> 
<title>WWN Creator</title>
<style type="text/css">/*<![CDATA[*/
    body {
        text-align: center;
    }

    h1 a {
        text-decoration: none;
        color: black;
    }

    ul.undec li {
        list-style-type: none;
    }

    hr.long {
        width: 550px;
    }
/*]]>*/</style>
</head>
<body>
    <h1><a href="wwncreator.pl">World Wine News Creator</a></h1>
    <div id="main">
~;

}

##
# Footer stuff
# Should close everything opened in the header
#
sub footer {

print qq~
    </div>
</body>
</html>
~;

}

##
# Get the path name for this issue number
#
sub getIssuePath {
    my ($issueNum) = @_;

    my $path = '';

    my @files =  do {
        opendir(my $dh, $WINEHQCONF->{'wwnDir'});
        readdir($dh);
    };
    foreach my $file (@files) {
        if ($file  =~ /_(\d{3})\.xml/) {
            my $foundIssueNum = $1;

            if ($foundIssueNum == $issueNum) {
                $path = "$WINEHQCONF->{'wwnDir'}/$file";
            }
        }
    }

    return $path;
}


##
# Clean out the temporary xml files
#
sub clearTempXMLFiles {
    my @files =  do {
        opendir(my $dh, $DOWNLOAD_DIR);
        readdir($dh);
    };
    foreach my $file (@files) {
        if ($file  =~ /\.xml/) {
            unlink("$DOWNLOAD_DIR/$file");
        }
    }
}


##
# Delete the old issue file and pop in our fresh one.
#
sub view_wwn {
    # guarantee form values are reasonable
    my $issueNum = forceInt($FORM{'curIssueNum'});

    $xmlTempIssueFQN =~ s/XXX/$issueNum/;
    my $xmlWineHQIssueFQN = "$WINEHQCONF->{'wwnDir'}/wn$yearMonDayStr" . "_$issueNum.xml";

    # find the old issue file and delete it
    my $path = getIssuePath($issueNum);
    if ($path ne '') {
        unlink($path);
    }

    #place the new issue xml file we made into the winehq site
    move($xmlTempIssueFQN, $xmlWineHQIssueFQN);

    #make sure we can read it on the web
    chmod(0664, $xmlWineHQIssueFQN);

    # redirect to our freshly minted issue
    print "Location:$WINEHQCONF->{'url'}/wwn/$issueNum\n\n"; 
}


##
# Genereate statistics for the covered time period.
#
sub stats_wwn {
    # guarantee form values are reasonable
    my $curIssueNum = forceInt($FORM{'curIssueNum'});

    $xmlTempIssueFQN =~ s/XXX/$curIssueNum/;

    # load the xml file for this issue or die
    unless (-e $xmlTempIssueFQN) {
        die "Missing $xmlTempIssueFQN\n";
    }
    my $doc = XML::LibXML->load_xml(location => $xmlTempIssueFQN); 
    my $root = $doc->getDocumentElement();

    # grab the date range of this issue
    my $issueElement = ($doc->getElementsByTagName('issue'))[0]; 
    my $dateFrom = forceDate($issueElement->getAttribute('dateFrom'));
    my $dateTo = forceDate($issueElement->getAttribute('date'));

    my $ba = new BugzillaAnalyzer($dateFrom, $dateTo, $DOWNLOAD_DIR); 
    my $bugStatsDoc = $ba->toXML();

    my $aa = new AppDBAnalyzer($dateFrom, $dateTo, $DOWNLOAD_DIR, $DBCONF, $WINEHQCONF);
    my $appStatsDoc = $aa->toXML();

    # slip the bugzilla stats xml into our issue document
    $root->appendChild($bugStatsDoc->getDocumentElement());

    # slip the appdb stats xml into our issue document
    $root->appendChild($appStatsDoc->getDocumentElement());

    # update the xml issue file
    $doc->toFile($xmlTempIssueFQN, $xmlFormatting);
}


##
# Presents date inputs that control the generation of this issues
# must call this to generate the issue skeleton
#
sub new_wwn {
    my $highIssueNum = 0;

    # find the latest issue number
    my @files =  do {
        opendir(my $dh, $WINEHQCONF->{'wwnDir'});
        readdir($dh);
    };
    foreach my $file (@files) {
        if ($file  =~ /_(\d{3})\.xml/) {
            my $foundIssueNum = $1;

            if ($foundIssueNum > $highIssueNum) {
                $highIssueNum = $foundIssueNum;
            }
        }
    }

    my $nextIssueNum = $highIssueNum + 1;

    state $inputWidth = 50;

    my $lastMonth = DateCalc($dateToday, "- 1month");
    
    my $dateTo = UnixDate($dateToday, "%Y-%m-%d %H:%M:%S");
    my $dateFrom = UnixDate($lastMonth, "%Y-%m-%d %H:%M:%S");

    print qq~
        <form action="wwncreator.pl?a=create" method="post">
        <div>
        Author Name:$br
        <input name="name" value="$DEFAULT_AUTHOR" size="$inputWidth" />$br
        Author URL:$br
        <input name="authorURI" value="$DEFAULT_AUTHOR_URL" size="$inputWidth" />$br
        This Issue:$br
        <input name="curIssueNum" value="$nextIssueNum" />$br
        From Date:$br
        <input name="dateFrom" value="$dateFrom" />$br
        To Date:$br
        <input name="dateTo" value="$dateTo" />$br
        Main Goal (<i>Include ending punctuation</i>) is to:$br
        <input name="goal" value="$DEFAULT_GOAL" size="$inputWidth" />$br
        $br
        <input type="submit" value="Generate skeleton WWN" />
        </div>
        </form>
     ~;
}


##
# creates the sections.xml file for this issue
# creates the YYYYMMDD_XX.xml for this issue
#
sub save_wwn {
    # guarantee form values are reasonable
    my $issueNum = forceInt($FORM{'curIssueNum'});
    my $count = forceInt($FORM{'count'});

    $xmlTempIssueFQN =~ s/XXX/$issueNum/;

    # load the xml file for this issue or die
    unless (-e $xmlTempIssueFQN) {
        die "Missing $xmlTempIssueFQN\n";
    }
    my $doc = XML::LibXML->load_xml(location => $xmlTempIssueFQN); 
    my $root = $doc->getDocumentElement();

    # get rid of the old sections
    my @sections = $doc->getElementsByTagName('section');
    foreach my $section (@sections) {
        $root->removeChild($section);
    }

    # add the new sections from the form
    my @titles;
    foreach my $c (0 .. $count) {
        if (length($FORM{"content$c"}) < 5 && length($FORM{"title$c"}) < 3) {
            next;
        }

        my $title = $FORM{"title$c"};
        push(@titles, $title);
        my $subject = $FORM{"subject$c"};
        my $archive = $FORM{"archive$c"};
        my $posts = $FORM{"posts$c"};
        my $topic = $FORM{"topic$c"};
        my $content = $FORM{"content$c"};

        # windows to unix line endings
        $content =~ s/\r\n/\n/g;
        #use proper Br
        $content =~ s/<br>/$br/ig;
        #Turn links into real links
        $content =~ s#[\n\r ](http:\/\/.*?)[ <\n\r]# <a href="$1">$1<\/a> #ig;

        my $section = addNodeCDATA($doc, $root, 'section', $content,
            title   => $title,
            subject => $subject,
            archive => $archive,
            posts   => $posts
        );

        prependNode($doc, $section, 'topic', $topic);
    }

    # update the xml issue file
    $doc->toFile($xmlTempIssueFQN, $xmlFormatting);

    print qq~
        <h3>Updated $xmlTempIssueFQN</h3>
    ~;

    # assume if the file doesn't exist then we are editing an old issue and dont need a blurb.
    if (-e $xmlBlurbFQN) {
        # FIXME: Blurb xml file needs to be handled as xml.
        my $index = "<ul>\n";
        foreach my $aTitle (@titles) {
            $index .= qq~<li><a href="$WINEHQCONF->{'url'}/wwn/$issueNum#$aTitle">$aTitle</a></li>\n~;
        }

        $index .= "</ul>\n";

        my $data = do {
            local $/ = undef;
            open(my $fh, '<:utf8', $xmlBlurbFQN);
            <$fh>;
        };

        $data =~ s/\<\!--MAINLINKS--\>.*\<\!--ENDMAINLINKS--\>/\<\!--MAINLINKS--\>$index\<\!--ENDMAINLINKS--\>/;

        do {
            open(my $fh, '>:utf8', $xmlBlurbFQN);
            print $fh $data;
        };

        print qq~
            <h3>Updated $xmlBlurbFQN</h3>
        ~;
    }
}


##
# Creates a news blurb with issue outline.
# FIXME Use xml lib for creating xml.
#
sub createBlurb {
    my ($newsDate, $curIssueNum) = @_;

    my $newsXML = qq~
        <news>
            <date>$newsDate</date>
            <title>World Wine News Issue $curIssueNum</title>
            <body>
                <a href="wwn/$curIssueNum">WWN Issue $curIssueNum</a> was released today.
                <!--MAINLINKS--> <!--ENDMAINLINKS-->
            </body>
        </news>
    ~;

    do {
        open(my $fh, '>:utf8', $xmlBlurbFQN);
        print $fh $newsXML;
    };
}


##
# Creates the initial xml skeleton. Cleans up any left overs from previous runs.
# Calls the MailingListAnalyzer for the list stats.
#
sub create_wwn {
    unless ($FORM{'curIssueNum'}) {
	# FIXME html output and return
        die "No WWN number given.\n";
    }

    # guarantee form values are reasonable
    my $curIssueNum = forceInt($FORM{'curIssueNum'});
    my $dateFrom = forceDate($FORM{'dateFrom'});
    my $dateTo = forceDate($FORM{'dateTo'});

    # these can be whatever 
    my $authorName = $FORM{'name'};
    my $authorURI = $FORM{'authorURI'};
    my $mainGoal = $FORM{'goal'};
   
    $xmlTempIssueFQN =~ s/XXX/$curIssueNum/;

    my $ending = ending($curIssueNum);
    my $newsDate = UnixDate($dateTo, '%B %E, %Y');
    my $dateFromShort = UnixDate($dateFrom, '%Y/%m/%d');
    my $dateToShort = UnixDate($dateTo, '%Y/%m/%d');

    my $mla = new MailingListAnalyzer($dateFrom, $dateTo, "$WINEHQCONF->{'archiveURI'}", $DOWNLOAD_DIR);
    my $mailStatsDoc = $mla->toXML();

    my ($doc, $root) = createDoc('1.0', 'UTF-8', 'kc', '');
    addNode($doc, $root, 'title', 'Wine Traffic');
    addNode($doc, $root, 'author', $authorName, 
        contact => $authorURI);
    addNode($doc, $root, 'issue', '',
        num => $curIssueNum,
        date => $dateToShort,
        dateFrom => $dateFromShort);
    addNodeCDATA($doc, $root, 'intro', qq~
            <p>
            This is the $curIssueNum$ending issue of the World Wine News publication. This issue covers
            activity from $dateFromShort to $dateToShort.
            </p>
            <p>
            Its main goal is to $mainGoal It also serves to inform you of what's going on around Wine.
            Wine is an open source implementation of the Windows API on top of X and Unix.  Think of it as a
            Windows compatibility layer.  Wine does not require Microsoft Windows, as it is a completely
            alternative implementation consisting of 100% Microsoft-free code, but it can optionally use
            native system DLLs if they are available.  You can find more info at
            <a href="http://www.winehq.org">www.winehq.org</a>.
            </p>~);

    #'# stupid syntax highlighting

    # slip the mailing list stats xml into our issue document
    $root->appendChild($mailStatsDoc->getDocumentElement());

    # clear out any old junk from a half made issue
    clearTempXMLFiles();

    # update the xml issue file
    $doc->toFile($xmlTempIssueFQN, $xmlFormatting);

    # create the skeleton of a news blurb for front page
    createBlurb($newsDate, $curIssueNum);
}


##
# parses the xml file that exists for this issue and populates the form for editing
# provides a new section form at the bottom
#
sub edit_wwn {
    unless ($FORM{'curIssueNum'}) {
	# FIXME html output and return
        die "No WWN number given.\n";
    }

    # guarantee form values are reasonable
    my $issueNum = forceInt($FORM{'curIssueNum'});

    $xmlTempIssueFQN =~ s/XXX/$issueNum/;

    # load the xml file for this issue or die
    unless (-e $xmlTempIssueFQN) {
        copy(getIssuePath($issueNum), $xmlTempIssueFQN);
    }
    say "Using $xmlTempIssueFQN<br />";
    my $doc = XML::LibXML->load_xml(location => $xmlTempIssueFQN); 
    my $root = $doc->getDocumentElement();

    # grab the date range of this issue
    my $issueElement = ($doc->getElementsByTagName('issue'))[0]; 
    my $dateFrom = forceDate($issueElement->getAttribute('dateFrom'));
    my $dateTo = forceDate($issueElement->getAttribute('date'));

    #populate the form with existing sections for editing
    my $sectionHTML = '';
    my $c = 0;
    my @sections = $doc->getElementsByTagName('section');
    foreach my $sec (@sections){
        my $title = $sec->getAttribute('title');
        my $subject = $sec->getAttribute('subject');
        my $archive = $sec->getAttribute('archive');
        my $posts = $sec->getAttribute('posts');
        my $topic = ($sec->getChildrenByTagName('topic'))[0]->textContent();

        # old issues were faux xml so we try and detect it here
        my $content = '';
        # yay real xml
        my @cdataChildren = $sec->getChildrenByTagName('#cdata-section');
        if ($#cdataChildren >= 0) {
            $content = ($sec->getChildrenByTagName('#cdata-section'))[0]->textContent();

        # this else could be removed if all issues were patched on winehq
        # to be real xml
        # faux xml
        } else {
            my $topicNode = ($sec->getChildrenByTagName('topic'))[0];

            $sec->removeChild($topicNode);

            #$content = $sec->textContent();
            foreach my $node ($sec->childNodes()) {
                $content .= $node->toString();
            }
        }

        $sectionHTML .= qq~
            <hr class="long" />
            Title:$br
            <input name="title$c" value="$title" size="80" />$br
            Subject: $br 
            <input name="subject$c" value="$subject" size="80" />$br
            Archive URL:$br
            <input name="archive$c" value="$archive" size="80" />$br
            Posts:$br
            <input name="posts$c" value="$posts" size="80" />$br
            Topic:$br
            <input name="topic$c" value="$topic" size="80" />$br
            Content:$br
            <textarea rows="25" cols="150" name="content$c"><![CDATA[$content]]></textarea>$br
         ~;

         ++$c;
    }

    # links to generate stats to display wwn on demo site
    print qq~
        <a href="wwncreator.pl?a=view&amp;curIssueNum=$issueNum">Save to winehq and view</a>.$br$br
        <a href="wwncreator.pl?a=stats&amp;curIssueNum=$issueNum">Generate Stats</a>
        (About 26MB download avg 4 min wait on a bad day)
        <hr class="long" />

        <form action="wwncreator.pl?a=save&amp;curIssueNum=$issueNum" method="post">
        <div>
        <input type="submit" value="Save and Add new section area" />
    ~;

    #existing sections inputs
    print $sectionHTML;

    # new section inputs
    print qq~
        <hr class="long" />
        New Section:$br
        Title:$br
        <input name="title$c" size="80" />$br
        Subject: $br 
        <input name="subject$c" size="80" />$br
        Archive URL:$br
        <input name="archive$c" size="80" />$br
        Posts:$br
        <input name="posts$c" size="80" />$br
        Topic:$br
        <input name="topic$c" size="80" />$br
        Content:$br
        <textarea rows="25" cols="150" name="content$c"></textarea>$br
        <input type="hidden" name="count" value="$c" />$br
        <input type="submit" value="Save and Add new section area" />
        </div>
        </form>
    ~;
}


##
# display a link for each issue that can be edited
#
sub choose_wwn {
    my $out = '';
    my @issueFileNames;
    do {
        opendir(my $dir, $WINEHQCONF->{'wwnDir'});
        @issueFileNames = readdir($dir);
    };

    # get rid of . and .. directories
    @issueFileNames = grep( !/^\.*$/, @issueFileNames);

    $out .= qq~
        <ul class="undec">
            <li><a href="wwncreator.pl?a=new">Make new WWN</a></li>
    ~;

    foreach my $issueFileName (reverse(sort(@issueFileNames))) {
        $issueFileName =~ /_(\d{1,3})\.xml/;
        my $issueNum = $1;

        $out .= qq~
            <li><a href="wwncreator.pl?a=edit&amp;curIssueNum=$issueNum">$issueNum</a>
            (<a href="$WINEHQCONF->{'url'}/?issue=$issueNum">View</a>)</li>
        ~;
    }

    $out .= qq~
        </ul> 
    ~;

    print $out;
}


##
# translates any url encoded characters back to ascii
# e.g. %20 to space
#
sub parse_env {
    my $buffer = '';
    my %form;

    if (exists($ENV{CONTENT_LENGTH})) {
        read(STDIN, $buffer, $ENV{CONTENT_LENGTH});
    }

    $buffer .= "&" . $ENV{QUERY_STRING};
    my @pairs = split( /&/, $buffer);

    foreach my $pair (@pairs) {
        my ($name, $value) = split( /=/, $pair);

        if (defined($name) and defined($value)) {
            $value =~ tr/+/ /;
            $value =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
            $form{$name} = $value;
        }
    }

    return %form;
}


##
# gives the proper ending for a number. st rd nd for 1st 2nd etc. 
#
sub ending {
    my ($num) = @_;

    my @endings = ('th', 'st', 'nd', 'rd');

    $num %= 10;

    if ($num > 3) {
        $num = 0;
    }

    # debug
    #print(STDERR "Called ending: num: $num value: " . $endings[$num] . "\n");

    return $endings[$num];
}


##
# Forces the input to be returned as an int
#
sub forceInt {
    my ($input) = @_;

    my $int = int($input || 0);

    return $int;
}

##
# Forces the input to be returned as a date
# FIXME: We don't store the time stamp in the xml
#        So basically a specific hour/min won't work as a constraint.
#        Need to store it in the date attribute of issue element
#        in the wwn file.
#
sub forceDate {
    my ($input) = @_;

    my $date = '1900-01-01 00:00:00';

    # 1900-01-01 00:00:00
    if ($input =~ /(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})/) {
        $date = $1;
    # 1900/01/01
    } elsif ($input =~ /(\d{4})\/(\d{2})\/(\d{2})/) {
	$date = "$1-$2-$3 " . '00:00:00'; 
    }

    return $date;
}
