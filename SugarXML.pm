# SugarXML.pm
# Syntactic sugar for LibXML.
#
# Copyright 2011 C John Klehm
# Licensed under the AGPL version 3
#
package SugarXML;

use strict;
use warnings;
use autodie;


our $VERSION = '1.00';
use base 'Exporter';
our @EXPORT = qw(createDoc createDocCDATA addNode addNodeCDATA prependNode prependNodeCDATA);

use XML::LibXML;


##
# Creates the xml document and root element
#
# $encoding The character encoding of the xml document.
# $version  The xml version of the document.
# $rootName The name of the root element.
# $rootData The data to place in the root element as #text.
# 
# Usage:    my ($doc, $root) = createDoc('1.0', 'UTF-8', 'RootName', 'RootData', 
#               attribName1 => '2010/10', 
#               atrrib2 => 12
#           );
# You can also add the root data later with this:
# $root->appendText('RootData');
#
sub createDoc {
    my ($version, $encoding, $rootName, $rootData, %attributes) = @_;

    my $doc = XML::LibXML::Document->new($version, $encoding);
    my $root = $doc->createElement($rootName);
    $root->appendText($rootData);
    $doc->setDocumentElement($root);

    # add atributes
    while (my ($key, $keyValue) = each(%attributes)) {
        $root->setAttribute($key, $keyValue);
    }

    return ($doc, $root);
}


##
# Creates the xml document and root element
# Use the cdata version when you want to embed html in your xml
#
# $encoding The character encoding of the xml document.
# $version  The xml version of the document.
# $rootName The name of the root element.
# $rootData The data to place in the root element as cdata.
# 
# Usage:    my ($doc, $root) = createDoc('1.0', 'UTF-8', 'RootName', 'RootData', 
#               attribName1 => '2010/10', 
#               atrrib2 => 12
#           );
# You can also add the root data later with this:
# $root->appendText('RootData');
#
sub createDocCDATA {
    my ($version, $encoding, $rootName, $rootData, %attributes) = @_;

    my $doc = XML::LibXML::Document->new($version, $encoding);
    my $root = $doc->createElement($rootName);
    my $cdata = $doc->createCDATASection($rootData);
    $root->appendChild($cdata);
    $doc->setDocumentElement($root);

    # add atributes
    while (my ($key, $keyValue) = each(%attributes)) {
        $root->setAttribute($key, $keyValue);
    }

    return ($doc, $root);
}


##
# Adds a node to a parent element.
#
# $doc          The owning document.
# $parent       The parent element of this node.
# $nodeName     The name of this node.
# $nodeData     The data to place in this node as text.
# %attributes   The attributes of this node.
# return        The created node.
#
# Usage: addNode($doc, $parent, 'NodeName', 'This is a node.', attribName1 => '2010/10', atrrib2 => 12);
#
sub addNode {
    my ($doc, $parent, $nodeName, $nodeData, %attributes) = @_;

    my $el = $doc->createElement($nodeName);
    $el->appendText($nodeData);

    # add attributes
    while (my ($key, $keyValue) = each(%attributes)) {
        $el->setAttribute($key, $keyValue);
    }

    $parent->appendChild($el);

    return $el;
}


##
# Adds a node to a parent element.
# Use the cdata version when you want to embed html in xml.
#
# $doc          The owning document.
# $parent       The parent element of this node.
# $nodeName     The name of this node.
# $nodeData     The data to place in this node as CDATA.
# %attributes   The attributes of this node.
# return        The created node.
#
# Usage: addNode($doc, $parent, 'NodeName', 'This is a node.', attribName1 => '2010/10', atrrib2 => 12);
#
sub addNodeCDATA {
    my ($doc, $parent, $nodeName, $nodeData, %attributes) = @_;

    my $cdata = $doc->createCDATASection($nodeData);
    my $el = $doc->createElement($nodeName);
    $el->appendChild($cdata);

    # add attributes
    while (my ($key, $keyValue) = each(%attributes)) {
        $el->setAttribute($key, $keyValue);
    }

    $parent->appendChild($el);

    return $el;
}


##
# Same style as the others but insetad of appending to the parent it prepends.
#
sub prependNode {
    my ($doc, $parent, $nodeName, $nodeData, %attributes) = @_;

    my $el = $doc->createElement($nodeName);
    $el->appendText($nodeData);

    # add attributes
    while (my ($key, $keyValue) = each(%attributes)) {
        $el->setAttribute($key, $keyValue);
    }

    $parent->insertBefore($el, $parent->firstChild());

    return $el;   
}


##
# Same style as the others but instead of appending to the parent it prepends.
#
sub prependNodeCDATA {
    my ($doc, $parent, $nodeName, $nodeData, %attributes) = @_;

    my $cdata = $doc->createCDATASection($nodeData);
    my $el = $doc->createElement($nodeName);
    $el->appendChild($cdata);

    # add attributes
    while (my ($key, $keyValue) = each(%attributes)) {
        $el->setAttribute($key, $keyValue);
    }

    $parent->insertBefore($el, $parent->firstChild());    

    return $el;
}


1;
