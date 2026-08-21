#!/usr/bin/env perl
# Cross-package reference check.
#
# A single-colon reference (PKG:SYM) to a symbol PKG does not export is a
# READ-time error: the file cannot even be read, let alone compiled. The
# structure check cannot see it, because it reads with *READ-SUPPRESS* bound to
# T precisely so that no package needs to exist.
#
# This closes that gap without loading anything: collect every (:export ...)
# list from the defpackage forms in src/bootstrap/package*.lisp, then check
# every PKG:SYM reference in src/ and t/ against them.
#
# Double-colon (PKG::SYM) is deliberately NOT checked — it reaches internals on
# purpose and is legal regardless of the export list.
use strict;
use warnings;
binmode(STDOUT, ":encoding(UTF-8)");

my $root = shift // '.';
chdir $root or die "cannot chdir $root: $!";

# ---- collect export lists -------------------------------------------------
my %exports;          # package name (lc) => { symbol (lc) => 1 }
my @pkgfiles = glob("src/bootstrap/package*.lisp");
for my $f (@pkgfiles) {
    open(my $fh, '<:encoding(UTF-8)', $f) or die "$f: $!";
    my $text = do { local $/; <$fh> };
    close $fh;
    # Split on defpackage; each chunk after the first belongs to one package.
    my @chunks = split /\(defpackage\s+/, $text;
    shift @chunks;
    for my $c (@chunks) {
        next unless $c =~ /^#?:?([A-Za-z0-9\/\-\*\+]+)/;
        my $pkg = lc $1;
        # Everything up to the next defpackage is this package's form.
        # Grab all #:NAME tokens that appear after an (:export marker.
        if ($c =~ /\(:export(.*)$/s) {
            my $tail = $1;
            while ($tail =~ /#:([^\s\)\(]+)/g) {
                $exports{$pkg}{lc $1} = 1;
            }
        }
    }
}

unless (keys %exports) {
    print "NO EXPORT LISTS PARSED — the parser is wrong, not the tree\n";
    exit 2;
}

# ---- scan references ------------------------------------------------------
my @bad;
my $refs = 0;
my @files;
for my $dir ('src', 't') {
    next unless -d $dir;
    open(my $find, '-|', 'find', $dir, '-name', '*.lisp') or die $!;
    while (my $l = <$find>) { chomp $l; push @files, $l }
    close $find;
}

for my $f (@files) {
    next if $f =~ m{^src/bootstrap/package};   # the declarations themselves
    open(my $fh, '<:encoding(UTF-8)', $f) or next;
    my $ln = 0;
    my $in_string = 0;   # docstrings span lines; a mention inside one is prose
    while (my $line = <$fh>) {
        $ln++;
        my $code = '';
        # Walk the line character by character so a string that opened on an
        # earlier line keeps swallowing text until its closing quote. Stripping
        # per line instead reports every symbol named in a docstring.
        my @ch = split //, $line;
        for (my $i = 0; $i < @ch; $i++) {
            my $c = $ch[$i];
            if ($in_string) {
                if ($c eq "\\") { $i++; next }
                $in_string = 0 if $c eq '"';
                next;
            }
            if ($c eq '"') { $in_string = 1; next }
            if ($c eq ';') { last }                     # comment to end of line
            if ($c eq '#' && ($ch[$i+1] // '') eq "\\") { $i += 2; next }  # #\x
            $code .= $c;
        }
        next unless length $code;
        # PKG:SYM where PKG starts with nerimux/ and the colon is not doubled.
        while ($code =~ m{(nerimux(?:/[a-z0-9\-]+)*)(::?)([A-Za-z0-9\-\*\+%<>=/!?&_~\^]+)}gi) {
            my ($pkg, $colon, $sym) = (lc $1, $2, lc $3);
            next if $colon eq '::';            # internal access is legal
            $refs++;
            next unless exists $exports{$pkg}; # unknown package: reported below
            next if $exports{$pkg}{$sym};
            push @bad, "$f:$ln  $pkg:$sym";
        }
        while ($code =~ m{(nerimux(?:/[a-z0-9\-]+)*):(?!:)}gi) {
            my $pkg = lc $1;
            push @bad, "$f:$ln  no such package: $pkg" unless exists $exports{$pkg};
        }
    }
    close $fh;
}

my %seen; @bad = grep { !$seen{$_}++ } @bad;

printf "packages: %d   single-colon references checked: %d\n",
       scalar(keys %exports), $refs;
if (@bad) {
    print "UNEXPORTED OR UNKNOWN (read-time errors):\n";
    print "  $_\n" for @bad;
    exit 1;
}
print "EVERY SINGLE-COLON REFERENCE RESOLVES\n";
exit 0;
