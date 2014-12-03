package Biodiverse::Matrix;

#  package to handle matrices for Biodiverse objects
#  these are not matrices in the proper sense of the word, but are actually hash tables to provide easier linking
#  they are also double indexed - "by pair" and "by value by pair".

use strict;
use warnings;
use 5.010;

our $VERSION = '0.99_006';

use English ( -no_match_vars );

use Carp;
#use Data::Dumper;
use Scalar::Util qw /looks_like_number blessed/;
use List::Util qw /min max sum/;
#use File::BOM qw /:subs/;

use Biodiverse::Progress;

my $EMPTY_STRING = q{};

#  access the miscellaneous functions as methods
use parent qw /Biodiverse::Common Biodiverse::Matrix::Base/; 

sub new {
    my $class = shift;
    my %args = @_;
    
    my $self = bless {}, $class;
    

    # try to load from a file if the file arg is given
    my $file_loaded;
    $file_loaded = $self->load_file (@_) if defined $args{file};
    return $file_loaded if defined $file_loaded;


    my %PARAMS = (
        OUTPFX               => 'BIODIVERSE',
        OUTSUFFIX            => 'bms',
        OUTSUFFIX_YAML       => 'bmy',
        TYPE                 => undef,
        QUOTES               => q{'},
        JOIN_CHAR            => q{:},  #  used for labels
        ELEMENT_COLUMNS      => [1,2],  #  default columns in input file to define the names (eg genus,species).  Should not be used as a list here.
        PARAM_CHANGE_WARN    => undef,
        CACHE_MATRIX_AS_TREE => 1,
        VAL_INDEX_PRECISION  => '%.2g',  #  %g keeps 0 as 0.  %f does not.
    );

    $self->set_params (%PARAMS, %args);  #  load the defaults, with the rest of the args as params
    $self->set_default_params;  #  and any user overrides
    
    $self->{BYELEMENT} = undef;  #  values indexed by elements
    $self->{BYVALUE}   = undef;  #  elements indexed by value

    $self->set_param (NAME => $args{name}) if defined $args{name};

    warn "[MATRIX] WARNING: Matrix name not specified\n"
        if ! defined $self->get_param('NAME');

    return $self;
}

sub rename {
    my $self = shift;
    my %args = @_;
    
    my $name = $args{new_name};
    if (not defined $name) {
        croak "[Matrix] Argument 'new_name' not defined\n";
    }

    #  first tell the basedata object - No, leave that to the basedata object
    #my $bd = $self->get_param ('BASEDATA_REF');
    #$bd->rename_output (object => $self, new_name => $name);

    # and now change ourselves   
    $self->set_param (NAME => $name);
    
}


sub clone {
    my $self = shift;
    return $self->_duplicate (@_);
}

#  avoid needless cloning of the basedata, but don't create the parameter if it is not already there
sub _duplicate {
    my $self = shift;
    my %args = @_;

    say '[MATRIX] Duplicating matrix ' . $self->get_param('NAME');

    my $bd;
    my $exists = $self->exists_param('BASEDATA_REF');
    if ($exists) {
        $bd = $self->get_param('BASEDATA_REF');
        $self->set_param(BASEDATA_REF => undef);
    }

    my $params = eval {
        $self->SUPER::clone(data => $self->{PARAMS});
    };

    my $clone_ref = blessed ($self)->new(%$params);

    my $elements = $self->get_elements_ref;

    my $c_elements_ref = $clone_ref->get_elements_ref;
    %$c_elements_ref = %$elements;

    #  should add methods to access these
    my $byelement = $self->{BYELEMENT};
    my $byvalue   = $self->{BYVALUE};

    my (%c_byelement, %c_byvalue);
    keys %c_byelement = keys %$byelement;  #  pre-allocate the buckets - the pay-off is for many-key hashes
    keys %c_byvalue   = keys %$byvalue;

    my $progress;
    if (scalar keys %$byelement > 500) {
        $progress = Biodiverse::Progress->new(text => 'Cloning matrix ' . $self->get_param('NAME'));
    }


    foreach my $key (keys %$byelement) {
        my $hashref = $byelement->{$key};
        my %c_hash;
        keys %c_hash = keys %$hashref;  #  pre-allocate the buckets
        %c_hash = %$hashref;
        $c_byelement{$key} = \%c_hash;
    }

    $clone_ref->{BYELEMENT} = \%c_byelement;

    my $i = 0;
    my $to_do = scalar keys %$byvalue;
    my $target_text = "Target is $to_do value index keys";

    foreach my $val_key (keys %$byvalue) {
        my $val_hashref = $byvalue->{$val_key};
        my %c_val_hash;
        keys %c_val_hash = keys %$val_hashref;  #  pre-allocate the buckets

        if ($progress) {
            $i++;
            $progress->update ($target_text, $i / $to_do);
        }

        foreach my $e_key (keys %$val_hashref) {
            my $hashref = $val_hashref->{$e_key};
            my %c_hash;
            keys %c_hash = keys %$hashref;  #  pre-allocate the buckets
            %c_hash = %$hashref;
            $c_val_hash{$e_key} = \%c_hash;
        }

        $c_byvalue{$val_key} = \%c_val_hash;
    }

    $clone_ref->{BYVALUE} = \%c_byvalue;

    if ($progress) {
        $progress->destroy();
    };

    if ($EVAL_ERROR) {
        if ($exists) {
            $self->set_param(BASEDATA_REF => $bd);  #  put it back if needed
        }
        croak $EVAL_ERROR;
    }

    if ($exists) {
        $self->set_param(BASEDATA_REF => $bd);
        $clone_ref->set_param(BASEDATA_REF => $bd);
    }

    return $clone_ref;
}

sub delete_value_index {
    my $self = shift;

    undef $self->{BYVALUE};
    delete $self->{BYVALUE};

    return $self;
}

sub rebuild_value_index {
    my $self = shift;
    
    #$self->delete_value_index;
    $self->{BYVALUE} = {};
    
    my @elements = $self->get_elements_as_array;
    
    EL1:
    foreach my $el1 (@elements) {
        EL2:
        foreach my $el2 (@elements) {
            #  we want pairs in their stored order
            next EL2
              if 1 != $self->element_pair_exists(element1 => $el1, element2 => $el2);

            my $val = $self->get_value (element1 => $el1, element2 => $el2);

            my $index_val = $self->get_value_index_key (value => $val);

            $self->{BYVALUE}{$index_val}{$el1}{$el2}++;
        }
    }

    return $self;
}

sub get_value_index_key {
    my $self = shift;
    my %args = @_;
    
    my $val = $args{value};
    
    return 'undef' if !defined $val;

    if (my $prec = $self->get_param ('VAL_INDEX_PRECISION')) {
        $val = sprintf $prec, $val;
    }

    return $val;
}

#  need to flesh this out - total number of elements, symmetry, summary stats etc
sub _describe {
    my $self = shift;
    
    my @description = (
        'TYPE: ' . blessed $self,
    );
    
    my @keys = qw /
        NAME
        JOIN_CHAR
        QUOTES
    /;

    foreach my $key (@keys) {
        my $desc = $self->get_param ($key);
        if ((ref $desc) =~ /ARRAY/) {
            $desc = join q{, }, @$desc;
        }
        push @description, "$key: $desc";
    }

    push @description,  'Element count: ' . $self->get_element_count,;

    push @description, 'Max value: ' . $self->get_max_value;
    push @description, 'Min value: ' . $self->get_min_value;
    push @description, 'Symmetric: ' . ($self->is_symmetric ? 'yes' : 'no');
    
    my $description = join "\n", @description;
    
    return wantarray ? @description : $description;
}


#  convert this matrix to a tree by clustering 
sub to_tree {
    my $self = shift;
    my %args = @_;
    $args{linkage_function} = $args{linkage_function} || 'link_average';
    
    if ($self->get_param ('AS_TREE')) {  #  don't recalculate 
        return $self->get_param ('AS_TREE');
    }
    
    my $tree = Biodiverse::Cluster->new;
    $tree->set_param (
        'NAME' => ($args{name}
        || $self->get_param ('NAME') . "_AS_TREE"
        )
    );
    
    eval {
        $tree->cluster (
            %args,
            #  need to work on a clone, as it is a destructive approach
            cluster_matrix => $self->clone, 
        );
    };
    croak $EVAL_ERROR if $EVAL_ERROR;
    
    $self->set_param (AS_TREE => $tree);
    
    return $tree;
}



my $ludicrously_extreme_pos_val = 10 ** 20;
my $ludicrously_extreme_neg_val = -$ludicrously_extreme_pos_val;

sub get_min_value {
    my $self = shift;

    my $val_hash = $self->{BYVALUE};
    my $min_key  = min keys %$val_hash;

    #  Special case the zeroes - only valid for index precisions using %.g
    #  Useful for cluster analyses with many zero values due to identical assemblages
    return 0 if $min_key eq 0;

    my $min = $ludicrously_extreme_pos_val;

    my $element_hash = $val_hash->{$min_key};
    while (my ($el1, $hash_ref) = each %$element_hash) {
        foreach my $el2 (keys %$hash_ref) {
            my $val = $self->get_defined_value_aa ($el1, $el2);
            $min = min ($min, $val);
        }
    }

    return $min;
}

sub get_max_value {
    my $self = shift;

    my $val_hash = $self->{BYVALUE};    
    my $max_key  = max keys %$val_hash;
    my $max      = $ludicrously_extreme_neg_val;

    my $element_hash = $val_hash->{$max_key};
    while (my ($el1, $hash_ref) = each %$element_hash) {
        foreach my $el2 (keys %$hash_ref) {
            #my $val = $self->get_value (element1 => $el1, element2 => $el2, pair_exists => 1);
            my $val = $self->get_defined_value_aa ($el1, $el2);
            $max = max ($max, $val);
        }
    }

    return $max;
}

#  crude summary stats.
#  Not using Biodiverse::Statistics due to memory issues
#  with large matrices and calculation of percentiles.
sub get_summary_stats {
    my $self = shift;
    
    my $n = $self->get_element_pair_count;
    my ($sumx, $sumx_sqr);
    my @percentile_targets = qw /2.5 5 95 97.5/;
    my @percentile_target_counts;
    foreach my $pct (@percentile_targets) {
        push @percentile_target_counts, $n * $pct / 100;  #  should floor it?
    }
    my %percentile_hash;

    my $count;

    my $values_hash = $self->{BYVALUE};
    BY_VALUE:
    foreach my $value (sort numerically keys %$values_hash) {
        my $hash = $values_hash->{$value};
        my $sub_count = scalar keys %$hash;
        $sumx += $value * $sub_count;
        $sumx_sqr += ($value ** 2) * $sub_count;
        $count += $sub_count;

        FIND_PCTL:
        foreach my $target (@percentile_target_counts) {
            last FIND_PCTL if $count < $target;
            my $percentile = shift @percentile_targets;
            $percentile_hash{$percentile} = $value;
            shift @percentile_target_counts;
        }
    }
    
    my $max = $self->get_max_value;
    my $min = $self->get_min_value;

    my %stats = (
        MAX => $self->get_max_value,
        MIN => $self->get_min_value,
        MEAN   => $sumx / $n,
        #SD     => undef,
        PCT025 => defined $percentile_hash{'2.5'}  ? $percentile_hash{'2.5'}  : $min,
        PCT975 => defined $percentile_hash{'97.5'} ? $percentile_hash{'97.5'} : $max,
        PCT05  => defined $percentile_hash{'5'}    ? $percentile_hash{'5'}    : $min,
        PCT95  => defined $percentile_hash{'95'}   ? $percentile_hash{'95'}   : $max,
    );
    
    return wantarray ? %stats : \%stats;
}

sub add_element {  #  add an element pair to the object
    my $self = shift;
    my %args = @_;
    
    my $element1 = $args{element1};
    croak "Element1 not specified in call to add_element\n"
        if ! defined $element1;

    my $element2 = $args{element2};
    croak "Element2 not specified in call to add_element\n"
        if ! defined $element2;

    my $val = $args{value};
    if (! defined $val && ! $self->get_param('ALLOW_UNDEF')) {
        warn "[Matrix] add_element Warning: Value not defined and "
            . "ALLOW_UNDEF not set, not adding row $element1 col $element2.\n";
        return;
    }

    my $index_val = $self->get_value_index_key (value => $val);

    $self->{BYELEMENT}{$element1}{$element2} = $val;
    $self->{BYVALUE}{$index_val}{$element1}{$element2}++;
    $self->{ELEMENTS}{$element1}++;  #  cache the component elements to save searching through the other lists later
    $self->{ELEMENTS}{$element2}++;  #  also keeps a count of the elements
    
    return;
}

#  should be called delete_element_pair, but need to find where it's used first
sub delete_element {
    my $self = shift;
    my %args = @_;

    my $exists = $self->element_pair_exists (@_)
      || return 0;

    croak "element1 and/or element2 not defined\n"
        if ! (defined $args{element1} && defined $args{element2});

    my ($element1, $element2) = $exists == 1
        ? @args{'element1', 'element2'}
        : @args{'element2', 'element1'};

    my $value = $self->get_value (
        element1    => $element1,
        element2    => $element2,
        pair_exists => 1,
    );

    #  save some repeated dereferencing below
    my $val_index   = $self->{BYVALUE};
    my $el_ref      = $self->{ELEMENTS};
    my $by_el_index = $self->{BYELEMENT};

    #  now we get to the cleanup, including the containing hashes if they are now empty
    #  all the undef - delete pairs are to ensure they get deleted properly
    #  the hash ref must be empty (undef) or it won't be deleted
    #  autovivification of $self->{BYELEMENT}{$element1} is avoided by $exists above
    delete $by_el_index->{$element1}{$element2};
    if (scalar keys %{$by_el_index->{$element1}} == 0) {
        delete $by_el_index->{$element1}
            // warn "ISSUES BYELEMENT $element1 $element2\n";
    }

    my $index_val = $self->get_value_index_key (value => $value);
    if (!$val_index->{$index_val}) {
        $self->rebuild_value_index;  #  a bit underhanded, but this ensures we upgrade old matrices
    }
    

    delete $val_index->{$index_val}{$element1}{$element2};
    if (!scalar keys %{$val_index->{$index_val}{$element1}}) {
        delete $val_index->{$index_val}{$element1};
        if (!scalar keys %{$val_index->{$index_val}}) {
            delete $val_index->{$index_val}
                // warn "ISSUES BYVALUE $index_val $value $element1 $element2\n";
        }
    }
    #  Decrement the ELEMENTS counts, deleting entry if now zero
    #  as there are no more entries with this element
    $el_ref->{$element1}--;
    if (!$el_ref->{$element1}) {
        delete $el_ref->{$element1}
            // warn "ISSUES $element1\n";
    }
    $el_ref->{$element2}--;
    if (!$el_ref->{$element2}) {
        delete $el_ref->{$element2}
            // warn "ISSUES $element2\n";
    }

    #return ($self->element_pair_exists(@_)) ? undef : 1;  #  for debug
    return 1;  # return success if we get this far
}


sub is_symmetric {  #  check if the matrix is symmetric (each element has an equal number of entries)
    my $self = shift;
    
    my $prev_count = undef;
    foreach my $count (values %{$self->{ELEMENTS}}) {
        if (defined $prev_count) {
            return if $count != $prev_count;
        }
        $prev_count = $count;
    }
    return 1;  #  if we get this far then it is symmetric
}



sub get_elements {
    my $self = shift;

    return if ! exists $self->{ELEMENTS};
    return if (scalar keys %{$self->{ELEMENTS}}) == 0;

    return wantarray ? %{$self->{ELEMENTS}} : $self->{ELEMENTS};
}

sub get_elements_ref {
    my $self = shift;

    return $self->{ELEMENTS} // do {$self->{ELEMENTS} = {}};
}

sub get_elements_as_array {
    my $self = shift;
    return wantarray
        ? keys %{$self->{ELEMENTS}}
        : [keys %{$self->{ELEMENTS}}];
}

sub get_element_count {
    my $self = shift;
    return 0 if ! exists $self->{ELEMENTS};
    return scalar keys %{$self->{ELEMENTS}};
}

#sub get_element_pair_count {
#    my $self = shift;
#
#    #my $count = 0;
#    #for my $value (values %{$self->{ELEMENTS}}) {
#    #    $count += $value;
#    #}
#    my $count = sum values %{$self->{ELEMENTS}};
#    $count /= 2;  #  correct for double counting
#    #  IS THIS CORRECTION VALID?  We can have symmetric and non-symmetric matrices, so a:b and b:a
#    #  It depends on how they are tracked, though.  
#
#    return $count;
#}

sub get_element_pairs_with_value {
    my $self = shift;
    my %args = @_;

    my $val = $args{value};
    #my $val_key = $val;
    #if (my $prec = $self->get_param('VAL_INDEX_PRECISION')) {
    #    $val_key = sprintf $prec, $val;
    #}
    my $val_key = $self->get_value_index_key (value => $val);

    my %results;

    my $val_hash = $self->{BYVALUE};
    my $element_hash = $val_hash->{$val_key};

    while (my ($el1, $hash_ref) = each %$element_hash) {
        foreach my $el2 (keys %$hash_ref) {
            my $value = $self->get_defined_value (element1 => $el1, element2 => $el2);
            next if $val ne $value;  #  stringification implicitly uses %.15f precision
            $results{$el1}{$el2}++;
        }
    }

    return wantarray ? %results : \%results;    
}

sub get_element_values {  #  get all values associated with one element
    my $self = shift;
    my %args = @_;
    
    croak "element not specified (matrix)\n"  if ! defined $args{element};
    croak "matrix element does not exist\n" if ! $self->element_is_in_matrix (element => $args{element});

    my @elements = $self->get_elements_as_array;
    
    my %values;
    foreach my $el (@elements) {
        if ($self->element_pair_exists (element1 => $el, element2 => $args{element})) {
            $values{$el} = $self->get_value (element1 => $el, element2 => $args{element});
        }
    }
    
    return wantarray ? %values : \%values;    
}

sub delete_all_elements {
    my $self = shift;

    no autovivification;

    $self->{BYVALUE}   = undef;
    $self->{BYELEMENT} = undef;
    $self->{ELEMENTS}  = undef;

    return;
}




sub numerically {$a <=> $b};

1;


__END__

=head1 NAME

Biodiverse::Matrix - Methods to build, access and control matrix data
for a Biodiverse project.

=head1 SYNOPSIS

  use Biodiverse::Matrix;

=head1 DESCRIPTION

Store a matrix of values (normally dissimilarity) in the Biodiverse
internal format. 

=head2 Assumptions

Assumes C<Biodiverse::Common> is in the @ISA list.

Almost all methods in the Biodiverse library use {keyword => value} pairs as a policy.
This means some of the methods may appear to contain unnecessary arguments,
but it makes everything else more consistent.

List methods return a list in list context, and a reference to that list
in scalar context.

=head1 Methods

These assume you have declared an object called $self of a type that
inherits these methods, normally:

=over 4

=item  $self = Biodiverse::Matrix->new;

=back



=over 5

=item $self = Biodiverse::Matrix->new (%params);

Create a new matrices object.

Optionally pass a hash of parameters to be set.

If %params contains an item 'file_xml' then it attempts to open the file
referred to and returns that as an object if successful
(see C<Biodiverse::Common::load_xml_file>).

=item $self->add_element('element1' => $element1, 'element2' => $element2, 'value' => $value);

Adds an element pair and their value to the object.

=item $self->delete_element ('element1' => $element1, 'element2' => $element2);

Deletes an element pair and their value from the matrix.

=item $self->element_pair_exists ('element1' => $element1, 'element2' => $element2);

Returns 1 if the pair exists in the specified order, 2 if they exist but are
transposed, and 0 if they do not exist.  The values 1 and 2 allow the
other methods to refer to the appropriate internal data structure
and would normally be treated as the same by standard users.

=item $self->get_element_count;

Returns a count of the number of elements along one side of the matrix.
This is not the count of the total number of entries, but this could
be calculated if one assumes it is symmetric, does not contain
diagonal elements and so forth.

=item $self->get_elements;

Returns a hash of the unique elements indexed in the matrix.

=item $self->get_elements_as_array;

Returns an array of the unique elements indexed in the matrix.

=item $self->get_elements_with_value('value' => $value);

Returns a hash of element pairs in the matrix that have the specified
value.

=item $self->get_min_value;

Returns the minimum value in the matrix.

=item $self->get_max_value;

Returns the maximum value in the matrix.

=item $self->get_value ('element1' => $element1, 'element2' => $element2);

Returns the value for element pair [$element1, $element2].

=item $self->load_data;

Import data from a file.  Assumes data are symmetric amongst other things.

Really messy.  Needs cleaning up. 

=back

=head1 REPORTING ERRORS

I read my email frequently, so use that.  It should be pretty stable, though.

=head1 AUTHOR

Shawn Laffan

Shawn.Laffan@unsw.edu.au


=head1 COPYRIGHT

Copyright (c) 2006 Shawn Laffan. All rights reserved.  This
program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 REVISION HISTORY

=over 5

=item Version 0.09

May 2006.  Source libraries developed to the point where they can be
distributed.

=back

=cut
