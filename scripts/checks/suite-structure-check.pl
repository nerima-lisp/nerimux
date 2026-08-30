#!/usr/bin/env perl
# Every (it ...) belongs to a (describe ...).
#
# A test registered outside its suite still runs, so nothing about the result
# says anything is wrong. What it breaks is the shape of the tree: cl-weave's
# root gains a child that is a test case where every other child is a suite,
# and code that walks the root meets a type it does not expect.
#
# attention-tests.lisp had one closing paren too many after its second test,
# which ended the DESCRIBE and put the third test on the root. It had been that
# way through every green run.
#
# Also reports a file whose parens do not balance overall, which is the same
# mistake caught one step earlier.
use strict;
use warnings;
binmode(STDOUT, ":encoding(UTF-8)");

my $root = shift // '.';
chdir $root or die "cannot chdir $root: $!";

my @files;
for my $dir ('tests', 'packages') {
    next unless -d $dir;
    open(my $find, '-|', 'find', $dir, '-name', '*.lisp') or die $!;
    while (my $l = <$find>) { chomp $l; push @files, $l }
    close $find;
}
@files = grep { !m{/pty/} && !m{/e2e/} } @files;
unless (@files) { print "NO TEST FILES SCANNED\n"; exit 2 }

my @problems;
for my $f (@files) {
    open(my $fh, '<:encoding(UTF-8)', $f) or next;
    my ($depth, $in_string, $ln) = (0, 0, 0);
    while (my $line = <$fh>) {
        $ln++;
        # Strip strings, comments and character literals so only structural
        # parens are counted -- the same lexing the other checks here need.
        my $code = '';
        my @ch = split //, $line;
        for (my $i = 0; $i < @ch; $i++) {
            my $c = $ch[$i];
            if ($in_string) {
                if ($c eq "\\") { $i++; next }
                $in_string = 0 if $c eq '"';
                next;
            }
            if ($c eq '"') { $in_string = 1; next }
            if ($c eq ';') { last }
            if ($c eq '#' && ($ch[$i+1] // '') eq "\\") { $i += 2; next }
            $code .= $c;
        }
        push @problems, "$f:$ln  (it ...) is not inside a describe"
            if $line =~ /^\s*\((?:it|it-each)\s/ && $depth == 0;
        $depth += ($code =~ tr/(//);
        $depth -= ($code =~ tr/)//);
    }
    close $fh;
    push @problems, "$f  parens do not balance (ends at depth $depth)"
        if $depth != 0;
}

printf "test files scanned: %d\n", scalar(@files);
if (@problems) {
    print "STRUCTURAL PROBLEMS:\n";
    print "  $_\n" for @problems;
    exit 1;
}
print "EVERY TEST IS INSIDE A SUITE\n";
exit 0;
