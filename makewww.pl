#!/usr/bin/env perl
# makewwn.pl
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
my $BASE_PATH    = "/var/www/klehm.net/htdocs/$BASE_ROOT";
my $DOWNLOAD_DIR = "$BASE_PATH/download";

# winehq config
my $WINEHQCONF = {
    wwnDir => '/var/www/klehm.net/htdocs/winehq/wwn/en',
    url    => 'http://klehm.net/winehq',
    archiveURI => 'http://www.winehq.org/pipermail/wine-devel',
    appdbDumpURI   => 'ftp://ftp.winehq.org/pub/wine',
    appdbDumpPrefix => 'wine-appdb-'
};

# db config
my $DBCONF  = {
    name => 'appdb',
    host => 'localhost',
    user => 'USER',
    pw   => 'PASSWORD'
};

# FIXME indented xml output
# libxml tries to indent kind of but screws up sometimes.
#  probably need to run the completed xml through
# another library to get something human readable consistently
my $xmlFormatting = 1;

# FIXME: Should be based on dateTo
my $dateToday = &ParseDate("today"); 
my $yearMonDayStr = &UnixDate($dateToday, '%Y%m%d');
my $blurbFileName = $yearMonDayStr . "01.xml";

# template for issue name
my $xmlTempIssueFQN  = "$DOWNLOAD_DIR/wn$yearMonDayStr" . "_XXX.xml";
my $xmlBlurbFQN = "$DOWNLOAD_DIR/$blurbFileName";

############
### MAIN ###
############

print "Content-Type: text/html\n\n";

state $br = "<br />";
print qq~
    <html>
    <head> 
    <title>WWN Creator by Zachary Goldberg</title>
    </head>
    <body>
        <center>
        <h1><a href="makewwn.pl"><font color="black" style="text-decoration: none;">World Wine Newsletter Creator</font></a></h1>
        $br
~;

my %FORM = &parse_form();

given ($FORM{'a'}) {
    when ('new')      { new_wwn(); }
    when ('create')   { create_wwn(); edit_wwn(); }
    when ('save')     { save_wwn();   edit_wwn(); }
    when ('stat_gen') { stat_gen();   edit_wwn(); }
    when ('viewDemo') { make_demo(); }
    default           { choose_wwn(); }
} 

################
### END MAIN ###
################


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
sub make_demo {
    my $issueNum = $FORM{'curIssueNum'};

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

    #TODO: Server side redirect, gotta clean up the output in makewwn a bit first though.
    # print "Location:$WINECONF->{'url'}/wwn/$issueNum\n\n"; 
    print qq~<a href="$WINEHQCONF->{'url'}/?issue=$issueNum">Demo Site</a>~;
}


##
# Genereate statistics for the covered time period.
#
sub stat_gen {
    # FIXME: Validate form
    my $dateFrom = $FORM{'dateFrom'};
    my $dateTo = $FORM{'dateTo'};
    my $curIssueNum = $FORM{'curIssueNum'};

    $xmlTempIssueFQN =~ s/XXX/$curIssueNum/;

    # load the xml file for this issue or die
    unless (-e $xmlTempIssueFQN) {
        die "Missing $xmlTempIssueFQN\n";
    }
    my $doc = XML::LibXML->load_xml(location => $xmlTempIssueFQN); 
    my $root = $doc->getDocumentElement();

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

    my $lastMonth = &DateCalc($dateToday, "- 1month");
    
    my $dateTo = &UnixDate($dateToday, "%Y-%m-%d %H:%M:%S");
    my $dateFrom = &UnixDate($lastMonth, "%Y-%m-%d %H:%M:%S");

    print qq~
        <form action="makewwn.pl?a=create" method="post">
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
     ~;
}


##
# creates the sections.xml file for this issue
# creates the YYYYMMDD_XX.xml for this issue
#
sub save_wwn {
    my $issueNum = $FORM{'curIssueNum'};
    my $count = $FORM{'count'};

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
# TODO Use xml lib for creating xml.
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
    # TODO: Validate form
    unless ($FORM{'curIssueNum'}) {
        die "No WWN number given.\n";
    }

    my $authorName = $FORM{'name'};
    my $authorURI = $FORM{'authorURI'};
    my $curIssueNum = $FORM{'curIssueNum'};
    my $mainGoal = $FORM{'goal'};
    my $dateFrom = $FORM{'dateFrom'};
    my $dateTo = $FORM{'dateTo'};
    
    $xmlTempIssueFQN =~ s/XXX/$curIssueNum/;

    my $ending = ending($curIssueNum);
    my $newsDate = &UnixDate($dateTo, '%B %E, %Y');
    my $dateFromShort = &UnixDate($dateFrom, '%Y/%m/%d');
    my $dateToShort = &UnixDate($dateTo, '%Y/%m/%d');

    my $mla = new MailingListAnalyzer($dateFrom, $dateTo, "$WINEHQCONF->{'archiveURI'}", $DOWNLOAD_DIR);
    my $mailStatsDoc = $mla->toXML();

    my ($doc, $root) = createDoc('1.0', 'UTF-8', 'kc', '');
    addNode($doc, $root, 'title', 'Wine World News');
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
    #FIXME: Validate form
    unless ($FORM{'curIssueNum'}) {
        die "No WWN number given.\n";
    }

    my $dateFrom = $FORM{'dateFrom'};
    my $dateTo = $FORM{'dateTo'};
    my $issueNum = $FORM{'curIssueNum'}; 

    $xmlTempIssueFQN =~ s/XXX/$issueNum/;

    # load the xml file for this issue or die
    unless (-e $xmlTempIssueFQN) {
        copy(getIssuePath($issueNum), $xmlTempIssueFQN);
    }
    say $xmlTempIssueFQN;
    my $doc = XML::LibXML->load_xml(location => $xmlTempIssueFQN); 
    my $root = $doc->getDocumentElement();

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
            <hr width="550" color="black" />
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
            <textarea rows="25" cols="150" name="content$c">$content</textarea>$br
         ~;

         ++$c;
    }

    # links to generate stats to display wwn on demo site
    print qq~
        <a href="makewwn.pl?a=viewDemo&curIssueNum=$issueNum">View this WWN On Demo Site</a>$br$br
        <a href="makewwn.pl?a=stat_gen&curIssueNum=$issueNum&dateTo=$dateTo&dateFrom=$dateFrom">Generate Stats</a>
        <hr width="550" color="black" />

        <form action="makewwn.pl?a=save&curIssueNum=$issueNum&dateTo=$dateTo&dateFrom=$dateFrom" method="post">
        <input type="submit" value="Save and Add new section area" />
    ~;

    #existing sections inputs
    print $sectionHTML;

    # new section inputs
    print qq~
        <hr width="550" color="black" />
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
    ~;
}


##
# display a link for each issue that can be edited
#
sub choose_wwn {
    print qq~<a href="makewwn.pl?a=new">Make new WWN</a>$br~;

    my @issueFileNames;
    do {
        opendir(my $dir, $WINEHQCONF->{'wwnDir'});
        @issueFileNames = readdir($dir);
    };

    # get rid of . and .. directories
    @issueFileNames = grep( !/^\.*$/, @issueFileNames);

    foreach my $issueFileName (reverse(sort(@issueFileNames))) {
        $issueFileName =~ /_(\d{1,3})\.xml/;
        my $issueNum = $1;

        print qq~
            <a href="makewwn.pl?a=edit&curIssueNum=$issueNum">$issueNum</a>
            (<a href="$WINEHQCONF->{'url'}/?issue=$issueNum">View</a>)$br
        ~;
    }
}


##
# translates any url encoded characters back to ascii
# e.g. %20 to space
#
sub parse_form {
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

