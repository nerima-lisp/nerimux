#!/usr/bin/env perl
# Internal-helper call check: does every %NAME call have a %NAME definition, and
# does it pass a number of arguments that definition accepts?
#
# This is the cheapest approximation of "it compiles" available without a
# compiler. It deliberately checks ONLY names beginning with `%`, the
# convention this codebase uses for internal helpers, because that restriction
# is what makes it sound: a `%name` is always defined in this tree. It is never
# a Common Lisp symbol, never inherited from a sibling library, and never a
# locally bound variable. So an unresolved `%name` call is a real defect rather
# than a gap in the checker's knowledge.
#
# What it will not see: calls through APPLY or FUNCALL, names built with
# INTERN or by a macro, and anything a macro generates. Those are the same
# blind spots the rest of scripts/checks/ has.
use strict;
use warnings;
binmode(STDOUT, ":encoding(UTF-8)");

my $root = shift // '.';
chdir $root or die "cannot chdir $root: $!";

my @files;
for my $dir ('src', 't') {
    next unless -d $dir;
    open(my $find, '-|', 'find', $dir, '-name', '*.lisp') or die $!;
    while (my $l = <$find>) { chomp $l; push @files, $l }
    close $find;
}
unless (@files) { print "NO FILES SCANNED\n"; exit 2 }

# ---- strip comments and strings, tracking multi-line strings ---------------
sub code_of {
    my ($path) = @_;
    open(my $fh, '<:encoding(UTF-8)', $path) or return ();
    my (@lines, $in_string);
    $in_string = 0;
    while (my $line = <$fh>) {
        my $code = '';
        my @ch = split //, $line;
        for (my $i = 0; $i < @ch; $i++) {
            my $c = $ch[$i];
            if ($in_string) {
                if ($c eq "\\") { $i++; next }
                $in_string = 0 if $c eq '"';
                next;                       # body contributes nothing
            }
            # A string is one token, so it must leave one non-space character
            # behind. Blanking it instead loses an argument, and every call
            # taking a string then reads as one argument short.
            if ($c eq '"') { $in_string = 1; $code .= '~'; next }
            if ($c eq ';') { last }
            # #\( and #\) are character literals, not delimiters -- also one
            # token each.
            if ($c eq '#' && ($ch[$i+1] // '') eq "\\") { $i += 2; $code .= '~'; next }
            $code .= $c;
        }
        push @lines, $code;
    }
    close $fh;
    return @lines;
}

my %code;              # path => [lines of code]
$code{$_} = [ code_of($_) ] for @files;

# ---- collect definitions and their arity ----------------------------------
# min = required count, max = undef when &rest/&key/&body makes it unbounded.
my (%def, %where);
for my $f (@files) {
    my $text = join("\n", @{$code{$f}});

    # defstruct-generated names. A BOA constructor could be arity-checked, but
    # every one here is a keyword constructor, so accept any argument count.
    $def{lc $1} //= { min => 0, max => undef }
        while $text =~ /\(:constructor\s+(%[^\s\(\)]+)/gs;
    # Slot accessors: NAME- by default, or whatever (:conc-name ...) says.
    my @conc;
    push @conc, lc $1 while $text =~ /\(:conc-name\s+(%[^\s\(\)]+)/gs;
    push @conc, lc($1) . '-' while $text =~ /\(defstruct\s+\(?\s*(%[^\s\(\)]+)/gs;
    $def{"conc-prefix:$_"} = { min => 1, max => 1 } for @conc;

    # Names a table macro defines. Anything in operator position inside a
    # (define-... ) form is treated as defined with an unknown lambda list --
    # the macro decides it, and this checker cannot read the macro.
    while ($text =~ /\((define-[a-z0-9-]+)\b/gs) {
        my $start = pos($text) - length($1) - 1;
        my ($depth, $i, $len) = (0, $start, length($text));
        while ($i < $len) {
            my $c = substr($text, $i, 1);
            $depth++ if $c eq '(';
            if ($c eq ')') { $depth--; last if $depth == 0 }
            $i++;
        }
        my $body = substr($text, $start, $i - $start + 1);
        # Any %name inside, in operator position or bare: a table macro can
        # splice the name into a DEFUN it builds, where it appears as a lone
        # symbol rather than at the head of a form.
        $def{lc $1} //= { min => 0, max => undef }
            while $body =~ /(?:\(|\s)(%[^\s\(\)]+)/gs;
    }

    while ($text =~ /\((?:defun|defmacro)\s+(%[^\s\(\)]+)\s*\(/gs) {
        my $name = lc $1;
        # Walk the lambda list to its matching paren so nested defaults such as
        # &optional (rows 24) do not truncate it.
        my $lp = pos($text) - 1;
        my ($depth, $i, $len) = (0, $lp, length($text));
        while ($i < $len) {
            my $c = substr($text, $i, 1);
            $depth++ if $c eq '(';
            if ($c eq ')') { $depth--; last if $depth == 0 }
            $i++;
        }
        my $args = substr($text, $lp + 1, $i - $lp - 1);
        $args =~ s/\([^\)]*\)/X/g;   # (name default) counts as one parameter
        my @tok = grep { length } split /\s+/, $args;
        my ($min, $max, $seen_marker) = (0, 0, 0);
        for my $t (@tok) {
            if ($t =~ /^&/) {
                $seen_marker = 1;
                $max = undef if $t =~ /^&(rest|key|body|allow-other-keys)$/i;
                next;
            }
            if (!$seen_marker) { $min++; $max++ if defined $max }
            else               { $max++ if defined $max }
        }
        # A later definition of the same name wins; record the widest arity so a
        # conditionally redefined helper is not reported on the narrower one.
        if (exists $def{$name}) {
            my $p = $def{$name};
            $p->{min} = $min if $min < $p->{min};
            $p->{max} = undef if !defined $max;
            $p->{max} = $max if defined $p->{max} && defined $max && $max > $p->{max};
        } else {
            $def{$name} = { min => $min, max => $max };
            $where{$name} = $f;
        }
    }
    # Names introduced locally still count as defined for this check.
    while ($text =~ /\((?:flet|labels|macrolet)\s*\(\s*\((%[^\s\(\)]+)/gs) {
        my $n = lc $1;
        $def{$n} //= { min => 0, max => undef };
    }
}

# ---- collect call sites ---------------------------------------------------
# Count arguments by walking the form, so nested calls do not confuse the count.
my (@undefined, @arity);
for my $f (@files) {
    my @lines = @{$code{$f}};
    my $text  = join("\n", @lines);
    # Offset -> line number, for reporting.
    my @line_at;
    { my $off = 0; my $ln = 1;
      for my $l (@lines) { $line_at[$off + $_] = $ln for (0 .. length($l)); $off += length($l) + 1; $ln++ } }

    while ($text =~ /\((%[^\s\(\)]+)/g) {
        my $name  = lc $1;
        my $start = pos($text) - length($1) - 1;
        my $line  = $line_at[$start] // 0;

        # Skip the definition site itself.
        my $before = substr($text, ($start >= 40 ? $start - 40 : 0), ($start >= 40 ? 40 : $start));
        next if $before =~ /\((?:defun|defmacro|flet|labels|macrolet|function|quote)\s+$/i;
        next if $before =~ /#'\s*$/;
        # A binding position, not a call: (let ((%x ...))) and friends put the
        # name at the head of a form that is a binding pair.
        next if $before =~ /\((?:let\*?|multiple-value-bind|destructuring-bind|do\*?|symbol-macrolet)\s*\(\s*$/i;
        # (defstruct (%name (:constructor ...))) -- the name, not a call.
        next if $before =~ /\(defstruct\s+$/i;
        next if $before =~ /\(\s*$/ && $before =~ /\((?:let\*?|symbol-macrolet)\s*\(/i;

        unless (exists $def{$name}) {
            # A defstruct accessor, if some (:conc-name %p-) covers this name.
            my $accessor;
            for my $k (keys %def) {
                next unless $k =~ /^conc-prefix:(.+)$/;
                if (index($name, $1) == 0) { $accessor = 1; last }
            }
            next if $accessor;
            push @undefined, "$f:$line  $name";
            next;
        }

        # Walk to the closing paren, counting top-level arguments.
        my $depth = 0; my $args = 0; my $in_arg = 0;
        my $i = $start;
        my $len = length($text);
        my $ok = 0;
        while ($i < $len) {
            my $c = substr($text, $i, 1);
            if ($c eq '(') {
                $depth++;
                if ($depth == 2 && !$in_arg) { $args++; $in_arg = 1 }
            } elsif ($c eq ')') {
                $depth--;
                if ($depth == 1) { $in_arg = 0 }
                if ($depth == 0) { $ok = 1; last }
            } elsif ($depth == 1) {
                if ($c =~ /\s/) { $in_arg = 0 }
                elsif (!$in_arg) {
                    # The operator itself is not an argument.
                    $args++ if $i > $start + length($name);
                    $in_arg = 1;
                }
            }
            $i++;
        }
        next unless $ok;   # unterminated in this file's stripped text

        my $d = $def{$name};
        if ($args < $d->{min} || (defined $d->{max} && $args > $d->{max})) {
            my $accepts = defined $d->{max}
                ? ($d->{min} == $d->{max} ? $d->{min} : "$d->{min}-$d->{max}")
                : "$d->{min}+";
            push @arity, "$f:$line  $name got $args, accepts $accepts"
                       . " (defined $where{$name})";
        }
    }
}

my %seen;
@undefined = grep { !$seen{$_}++ } @undefined;
@arity     = grep { !$seen{$_}++ } @arity;

printf "internal helpers defined: %d   call sites checked in %d files\n",
       scalar(keys %def), scalar(@files);
if (@undefined) {
    print "CALLS WITH NO DEFINITION:\n";
    print "  $_\n" for @undefined;
}
if (@arity) {
    print "ARGUMENT COUNT MISMATCHES:\n";
    print "  $_\n" for @arity;
}
if (@undefined || @arity) { exit 1 }
print "EVERY % HELPER CALL RESOLVES, WITH AN ACCEPTABLE ARGUMENT COUNT\n";
exit 0;
