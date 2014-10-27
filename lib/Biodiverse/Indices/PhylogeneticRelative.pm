package Biodiverse::Indices::PhylogeneticRelative;

use strict;
use warnings;
use List::Util qw /sum/;

use Carp;

my $metadata_class = 'Biodiverse::Metadata::Indices';

sub get_metadata_calc_phylo_rpd1 {

    my %metadata = (
        description     => 'Relative Phylogenetic Diversity (RPD).  '
                         . 'The ratio of the tree\'s PD to a null model of '
                         . 'PD evenly distributed across terminals and where '
                         . 'ancestral nodes are collapsed to zero length.',
        name            => 'Relative Phylogenetic Diversity, type 1',
        reference       => 'Mishler et al. (2014) http://dx.doi.org/10.1038/ncomms5473',
        type            => 'Phylogenetic Indices (relative)',
        pre_calc        => [qw /calc_pd calc_labels_on_tree/],
        required_args   => ['tree_ref'],
        uses_nbr_lists  => 1,
        indices         => {
            PHYLO_RPD1      => {
                description => 'RPD1',
            },
            PHYLO_RPD_NULL1 => {
                description => 'Null model score used as the denominator in the RPD1 calculations',
            },
            PHYLO_RPD_DIFF1 => {
                description => 'How much more or less PD is there than expected, in original tree units.',
                formula     => ['= tree\_length \times (PD\_P - PHYLO\_RPD\_NULL1)'],
            }
        },
    );

    return $metadata_class->new(\%metadata);
}

sub calc_phylo_rpd1 {
    my $self = shift;
    my %args = @_;

    my $tree = $args{tree_ref};
    my $total_tree_length = $tree->get_total_tree_length;

    my $pd_p_score = $args{PD_P};
    my $pd_score   = $args{PD_P};
    my $label_hash = $args{PHYLO_LABELS_ON_TREE};
    my $richness   = scalar keys %$label_hash;

    my %results;
    {
        no warnings qw /numeric uninitialized/;

        #  Null is the number of terminals in the sample divided
        #  by the number of terminals on the tree, since the null
        #  is a rake/star tree with no internals
        my $n    = $tree->get_terminal_element_count;  #  should this be a pre_calc_global?  The value is cached, though.
        my $null = eval {$richness / $n};
        my $phylo_rpd1 = eval {$pd_p_score / $null};

        $results{PHYLO_RPD1}      = $phylo_rpd1;
        $results{PHYLO_RPD_NULL1} = $null;
        $results{PHYLO_RPD_DIFF1} = $total_tree_length * ($pd_p_score - $null);
    }

    return wantarray ? %results : \%results;
}



sub get_metadata_calc_phylo_rpe1 {

    my %metadata = (
        description     => 'Relative Phylogenetic Endemism (RPE).  '
                         . 'The ratio of the tree\'s PE to a null model of '
                         . 'PD evenly distributed across terminals, '
                         . 'but with the same range per terminal and where '
                         . 'ancestral nodes are of zero length (as per RPD1).',
        name            => 'Relative Phylogenetic Endemism, type 1',
        reference       => 'Mishler et al. (2014) http://dx.doi.org/10.1038/ncomms5473',
        type            => 'Phylogenetic Indices (relative)',
        pre_calc        => [qw /calc_pe calc_endemism_whole_lists calc_labels_on_trimmed_tree/],
        pre_calc_global => ['get_trimmed_tree'],
        uses_nbr_lists  => 1,
        indices         => {
            PHYLO_RPE1           => {
                description => 'Relative Phylogenetic Endemism score',
            },
            PHYLO_RPE_NULL1        => {
                description => 'Null score used as the denominator in the RPE calculations',
            },
            PHYLO_RPE_DIFF1 => {
                description => 'How much more or less PE is there than expected, in original tree units.',
                formula     => ['= tree\_length \times (PE\_WE\_P - PHYLO\_RPE\_NULL1)'],
            }
        },
    );

    return $metadata_class->new(\%metadata);
}

sub calc_phylo_rpe1 {
    my $self = shift;
    my %args = @_;

    my $tree = $args{trimmed_tree};
    my $total_tree_length = $tree->get_total_tree_length;

    my $pe_p_score = $args{PE_WE_P};
    my $pe_score   = $args{PE_WE};

    #  get the WE score for the set of terminal nodes in this neighbour set
    my $we;
    my $label_hash = $args{PHYLO_LABELS_ON_TRIMMED_TREE};
    my $weights    = $args{ENDW_WTLIST};

    foreach my $label (keys %$label_hash) {
        next if ! exists $weights->{$label};  #  This should not happen.  Maybe should croak instead?
        #next if ! $tree->node_is_in_tree(node => $label);  #  list has already been filtered to trimmed tree
        $we += $weights->{$label};
    }

    my %results;
    {
        no warnings qw /numeric uninitialized/;

        #  should this be a pre_calc_global?  The value is cached, though.
        my $n = $tree->get_terminal_element_count;

        my $null       = eval {$we / $n};
        my $phylo_rpe1 = eval {$pe_p_score / $null};

        $results{PHYLO_RPE1}      = $phylo_rpe1;
        $results{PHYLO_RPE_NULL1} = $null;
        $results{PHYLO_RPE_DIFF1} = $total_tree_length * ($pe_p_score - $null);
    }

    return wantarray ? %results : \%results;
}

sub get_metadata_calc_phylo_rpd2 {

    my %metadata = (
        description     => 'Relative Phylogenetic Diversity (RPD), type 2.  '
                         . 'The ratio of the tree\'s PD to a null model of '
                         . 'PD evenly distributed across all nodes '
                         . '(all branches are of equal length).',
        name            => 'Relative Phylogenetic Diversity, type 2',
        reference       => 'Mishler et al. (2014) http://dx.doi.org/10.1038/ncomms5473',
        type            => 'Phylogenetic Indices (relative)',
        pre_calc        => [qw /calc_pd calc_pd_node_list/],
        pre_calc_global => ['get_tree_with_equalised_branch_lengths'],  #  should just use node counts in the original tree
        required_args   => ['tree_ref'],
        uses_nbr_lists  => 1,
        indices         => {
            PHYLO_RPD2      => {
                description => 'RPD2',
            },
            PHYLO_RPD_NULL2 => {
                description => 'Null model score used as the denominator in the RPD2 calculations',
            },
            PHYLO_RPD_DIFF2 => {
                description => 'How much more or less PD is there than expected, in original tree units.',
                formula     => ['= tree\_length \times (PD\_P - PHYLO\_RPD\_NULL2)'],
            }
        },
    );

    return $metadata_class->new(\%metadata);
}

sub calc_phylo_rpd2 {
    my $self = shift;
    my %args = @_;

    my $orig_tree_ref = $args{tree_ref};
    my $orig_total_tree_length = $orig_tree_ref->get_total_tree_length;
    my $null_tree_ref = $args{TREE_REF_EQUALISED_BRANCHES};
    my $null_total_tree_length = $null_tree_ref->get_total_tree_length;

    my $pd_p_score     = $args{PD_P};
    my $pd_score       = $args{PD};
    my $included_nodes = $args{PD_INCLUDED_NODE_LIST};  #  stores branch lengths

    #  Allow for zero length nodes, as we keep them as zero.
    #  The grep in scalar context is a fast way of counting the number of non-zero branches.
    #  %$included_nodes is for the original tree
    my $pd_score_eq_branch_lengths = grep {$_} values %$included_nodes;

    my %results;
    {
        no warnings qw /numeric uninitialized/;

        #my $n    = $tree_ref->get_terminal_element_count;
        my $null = eval {$pd_score_eq_branch_lengths / $null_total_tree_length};
        my $phylo_rpd2 = eval {$pd_p_score / $null};

        $results{PHYLO_RPD2}      = $phylo_rpd2;
        $results{PHYLO_RPD_NULL2} = $null;
        $results{PHYLO_RPD_DIFF2} = eval {$orig_total_tree_length * ($pd_p_score - $null)};
    }

    return wantarray ? %results : \%results;
}



sub get_metadata_calc_phylo_rpe2 {

    my %metadata = (
        description     => 'Relative Phylogenetic Endemism (RPE).  '
                         . 'The ratio of the tree\'s PE to a null model where '
                         . 'PE is calculated using a tree where all branches '
                         . 'are of equal length.',
        name            => 'Relative Phylogenetic Endemism, type 2',
        reference       => 'Mishler et al. (2014) http://dx.doi.org/10.1038/ncomms5473',
        type            => 'Phylogenetic Indices (relative)',
        pre_calc        => [qw /calc_pe calc_pe_lists/],
        pre_calc_global => [qw /get_trimmed_tree get_trimmed_tree_with_equalised_branch_lengths/],
        uses_nbr_lists  => 1,
        indices         => {
            PHYLO_RPE2       => {
                description => 'Relative Phylogenetic Endemism score, type 2',
            },
            PHYLO_RPE_NULL2  => {
                description => 'Null score used as the denominator in the RPE2 calculations',
            },
            PHYLO_RPE_DIFF2  => {
                description => 'How much more or less PE is there than expected, in original tree units.',
                formula     => ['= tree\_length \times (PE\_WE\_P - PHYLO\_RPE\_NULL1)'],
            }
        },
    );

    return $metadata_class->new(\%metadata);
}

sub calc_phylo_rpe2 {
    my $self = shift;
    my %args = @_;

    my $orig_tree_ref = $args{trimmed_tree};
    my $orig_total_tree_length = $orig_tree_ref->get_total_tree_length;

    my $null_tree_ref = $args{TREE_REF_EQUALISED_BRANCHES_TRIMMED};
    my $null_total_tree_length = $null_tree_ref->get_total_tree_length;

    my $pe_p_score = $args{PE_WE_P};
    my $pe_score   = $args{PE_WE};

    #  Get the PE score assuming equal branch lengths
    #  This is simply the sum of the local ranges for each node.  
    my $node_ranges_local  = $args{PE_LOCAL_RANGELIST};
    my $node_ranges_global = $args{PE_RANGELIST};
    my $pe_null;

    my %results;
    {
        foreach my $node (keys %$node_ranges_global) {
            my $node_ref = $null_tree_ref->get_node_ref(node => $node);
            $pe_null += $node_ref->get_length
                      * $node_ranges_local->{$node}
                      / $node_ranges_global->{$node};
        }

        no warnings qw /numeric uninitialized/;

        my $null       = eval {$pe_null / $null_total_tree_length};  #  equiv to PE_WE_P for the equalised tree
        my $phylo_rpe2 = eval {$pe_p_score / $null};

        $results{PHYLO_RPE2}      = $phylo_rpe2;
        $results{PHYLO_RPE_NULL2} = $null;
        $results{PHYLO_RPE_DIFF2} = eval {$orig_total_tree_length * ($pe_p_score - $null)};
    }

    return wantarray ? %results : \%results;
}

sub get_metadata_calc_labels_on_trimmed_tree {
    my $self = shift;

    my %metadata = (
        description     => 'Create a hash of the labels that are on the trimmed tree',
        name            => 'Labels on trimmed tree',
        indices         => {
            PHYLO_LABELS_ON_TRIMMED_TREE => {
                description => 'A hash of labels that are found on the tree after it has been trimmed to match the basedata, across both neighbour sets',
                type        => 'list',
            },  #  should poss also do nbr sets 1 and 2
        },
        type            => 'Phylogenetic Indices (relative)',  #  keeps it clear of the other indices in the GUI
        pre_calc_global => [qw /get_trimmed_tree get_labels_not_on_trimmed_tree/],
        pre_calc        => ['calc_abc'],
        uses_nbr_lists  => 1,  #  how many lists it must have
    );

    return $metadata_class->new(\%metadata);
}

sub calc_labels_on_trimmed_tree {
    my $self = shift;
    my %args = @_;
    
    my %labels = %{$args{label_hash_all}};
    my $not_on_tree = $args{labels_not_on_trimmed_tree};
    delete @labels{keys %$not_on_tree};

    my %results = (PHYLO_LABELS_ON_TRIMMED_TREE => \%labels);
    
    return wantarray ? %results : \%results;
}


sub get_metadata_calc_labels_not_on_trimmed_tree {
    my $self = shift;

    my %metadata = (
        description     => 'Create a hash of the labels that are not on the trimmed tree',
        name            => 'Labels not on trimmed tree',
        indices         => {
            PHYLO_LABELS_NOT_ON_TRIMMED_TREE => {
                description => 'A hash of labels that are not found on the tree after it has been trimmed to the basedata, across both neighbour sets',
                type        => 'list',
            },  #  should poss also do nbr sets 1 and 2
            PHYLO_LABELS_NOT_ON_TRIMMED_TREE_N => {
                description => 'Number of labels not on the trimmed tree',
                
            },
            PHYLO_LABELS_NOT_ON_TRIMMED_TREE_P => {
                description => 'Proportion of labels not on the trimmed tree',
                
            },
        },
        type            => 'Phylogenetic Indices (relative)',  #  keeps it clear of the other indices in the GUI
        pre_calc_global => [qw /get_labels_not_on_trimmed_tree/],
        pre_calc        => ['calc_abc'],
        uses_nbr_lists  => 1,  #  how many lists it must have
    );

    return $metadata_class->new(\%metadata);
}

sub calc_labels_not_on_trimmed_tree {
    my $self = shift;
    my %args = @_;

    my $not_on_tree = $args{labels_not_on_trimmed_tree};

    my %labels1 = %{$args{label_hash_all}};
    my $richness = scalar keys %labels1;
    delete @labels1{keys %$not_on_tree};

    my %labels2 = %{$args{label_hash_all}};
    delete @labels2{keys %labels1};

    my $count_not_on_tree = scalar keys %labels2;
    my $p_not_on_tree;
    {
        no warnings 'numeric';
        $p_not_on_tree = eval { $count_not_on_tree / $richness } || 0;
    }

    my %results = (
        PHYLO_LABELS_NOT_ON_TRIMMED_TREE   => \%labels2,
        PHYLO_LABELS_NOT_ON_TRIMMED_TREE_N => $count_not_on_tree,
        PHYLO_LABELS_NOT_ON_TRIMMED_TREE_P => $p_not_on_tree,
    );

    return wantarray ? %results : \%results;
}

sub get_metadata_get_labels_not_on_trimmed_tree {
    my $self = shift;

    my %metadata = (
        name            => 'get_labels_not_on_trimmed_tree',
        description     => 'List of lables not on the trimmed tree',
        pre_calc_global => [qw /get_trimmed_tree/],
        indices => {
            labels_not_on_trimmed_tree => {
                description => 'List of labels not on the trimmed tree',
                type        => 'list',
            },
        },
    );

    return $metadata_class->new(\%metadata);
}

sub get_labels_not_on_trimmed_tree {
    my $self = shift;
    my %args = @_;                          

    my $bd   = $self->get_basedata_ref;
    my $tree = $args{trimmed_tree};
    
    my $labels = $bd->get_labels;
    
    my @not_in_tree = grep { !$tree->exists_node (name => $_) } @$labels;

    my %hash;
    @hash{@not_in_tree} = (1) x scalar @not_in_tree;

    my %results = (labels_not_on_trimmed_tree => \%hash);

    return wantarray ? %results : \%results;
}

sub get_metadata_get_tree_with_equalised_branch_lengths {
    my $self = shift;

    my %metadata = (
        name            => 'get_tree_with_equalised_branch_lengths',
        description     => 'Get a version of the tree where all non-zero length branches are of length 1',
        required_args   => ['tree_ref'],
        indices         => {
            TREE_REF_EQUALISED_BRANCHES => {
                description => 'Tree with equalised branch lengths',
            },
        },
    );

    return $metadata_class->new(\%metadata);
}

sub get_tree_with_equalised_branch_lengths {
    my $self = shift;
    my %args = @_;
    
    my $tree_ref = $args{tree_ref} // croak "missing tree_ref argument\n";

    #  should let the sub calculate the length, but everything is set up for 1 or 0 lengths
    my $new_tree = $tree_ref->clone_tree_with_equalised_branch_lengths (node_length => 1);

    my %results = (
        TREE_REF_EQUALISED_BRANCHES => $new_tree,
    );

    return wantarray ? %results : \%results;
}

sub get_metadata_get_trimmed_tree_with_equalised_branch_lengths {
    my $self = shift;

    my %metadata = (
        name            => 'get_trimmed_tree_with_equalised_branch_lengths',
        description     => 'Get a version of the trimmed tree where all non-zero length branches are of length 1',
        pre_calc_global => ['get_trimmed_tree'],
        indices         => {
            TREE_REF_EQUALISED_BRANCHES_TRIMMED => {
                description => 'Trimmed tree with equalised branch lengths',
            },
        },
    );

    return $metadata_class->new(\%metadata);
}

sub get_trimmed_tree_with_equalised_branch_lengths {
    my $self = shift;
    my %args = @_;

    my $tree_ref = $args{trimmed_tree} // croak "missing trimmed_tree argument\n";

    #  lengths will be non-zero, but not 1
    my $new_tree = $tree_ref->clone_tree_with_equalised_branch_lengths;

    my %results = (
        TREE_REF_EQUALISED_BRANCHES_TRIMMED => $new_tree,
    );

    return wantarray ? %results : \%results;
}



1;
