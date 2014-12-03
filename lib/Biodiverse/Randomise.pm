package Biodiverse::Randomise;

#  methods to randomise a BaseData subcomponent

use strict;
use warnings;
use 5.010;

use English ( -no_match_vars );

#use Devel::Symdump;
use Data::Dumper qw { Dumper };
use Carp;
use POSIX qw { ceil floor };
use Time::HiRes qw { gettimeofday tv_interval };
use Scalar::Util qw { blessed };
use List::Util qw /any all none minstr max/;
use List::MoreUtils qw /first_index/;
use List::BinarySearch::XS;  #  make sure we have the XS version available via PAR::Packer executables
use List::BinarySearch qw /binsearch  binsearch_pos/;
#eval {use Data::Structure::Util qw /has_circular_ref get_refs/}; #  hunting for circular refs
#use MRO::Compat;
use Class::Inspector;

require Biodiverse::BaseData;
use Biodiverse::Progress;

our $VERSION = '0.99_006';

my $EMPTY_STRING = q{};

require Biodiverse::Config;
my $progress_update_interval = $Biodiverse::Config::progress_update_interval;

use parent qw {Biodiverse::Common};

sub new {
    my $class = shift;
    my %args = @_;

    my $self = bless {}, $class;

    if (defined $args{file}) {
        my $file_loaded = $self->load_file (@_);
        return $file_loaded;
    }

    my %PARAMS = (  #  default parameters to load.  These will be overwritten as needed.
        OUTPFX              => 'BIODIVERSE_RANDOMISATION',  #  not really used anymore
        OUTSUFFIX           => 'brs',
        OUTSUFFIX_YAML      => 'bry',
        PARAM_CHANGE_WARN   => undef,
    );

    #  load the defaults, with the rest of the args as params
    my %args_for = (%PARAMS, %args);
    $self->set_params (%args_for);

    #  avoid memory leak probs with circular refs
    $self->weaken_basedata_ref;

    return $self;
}

sub _get_metadata_export {
    my $self = shift;

    #  need a list of export subs
    my %subs = $self->get_subs_with_prefix (prefix => 'export_');

    #  hunt through the other export subs and collate their metadata
    my @export_sub_params;
    my @formats;
    my %format_labels;  #  track sub names by format label
    #  avoid double counting of options, and list is specified below
    my %done = (
        list    => 1,
        format  => 1,
        file    => 1,
    );

    foreach my $sub (sort keys %subs) {
        my %sub_args = $self->get_args (sub => $sub);
        croak "Metadata item 'format' missing\n" if not defined $sub_args{format};

        my $params_array = $sub_args{parameters};
        foreach my $param_hash (@$params_array) {
            my $name = $param_hash->{name};
            if (!exists $done{$name}) {  #  does not allow mixed options and defaults etc - first in, best dressed
                push @export_sub_params, $param_hash;
                $done{$name} ++;
            }
        }

        push @formats, $sub_args{format};
        $format_labels{$sub_args{format}} = $sub; 
    }
    @formats = sort @formats;
    $self->move_to_front_of_list (list => \@formats, item => 'Delimited text');

    my %args = (
        parameters => [ {
                name => 'file',
                type => 'file',
            },
            {
                name        => 'format',
                label_text  => 'What to export',
                type        => 'choice',
                choices     => \@formats,
                default     => 0,
            },
            @export_sub_params,
        ],
        format_labels => \%format_labels,
    );

    return wantarray ? %args : \%args;
}

#  same as Basestruct method - refactor needed
sub get_metadata_export {
    my $self = shift;

    #  need a list of export subs
    my %subs = $self->get_subs_with_prefix (prefix => 'export_');

    my @formats;
    my %format_labels;  #  track sub names by format label

    #  loop through subs and get their metadata
    my %params_per_sub;

    LOOP_EXPORT_SUB:
    foreach my $sub (sort keys %subs) {
        my %sub_args = $self->get_args (sub => $sub);

        my $format = $sub_args{format};

        croak "Metadata item 'format' missing\n"
            if not defined $format;

        $format_labels{$format} = $sub;

        next LOOP_EXPORT_SUB
            if $sub_args{format} eq $EMPTY_STRING;

        $params_per_sub{$format} = $sub_args{parameters};

        my $params_array = $sub_args{parameters};

        push @formats, $format;
    }

    @formats = sort @formats;
    $self->move_to_front_of_list (
        list => \@formats,
        item => 'Initial PRNG state'
    );

    my %args = (
        parameters     => \%params_per_sub,
        format_choices => [{
                name        => 'format',
                label_text  => 'Format to use',
                type        => 'choice',
                choices     => \@formats,
                default     => 0
            },
        ],
        format_labels  => \%format_labels,
    ); 

    return wantarray ? %args : \%args;
}

sub export {
    my $self = shift;
    my %args = @_;

    #  get our own metadata...
    my %metadata = $self->get_args (sub => 'export');

    my $sub_to_use = $metadata{format_labels}{$args{format}} || croak "Argument 'format' not specified\n";

    eval {$self->$sub_to_use (%args)};
    croak $EVAL_ERROR if $EVAL_ERROR;

    return;
}

sub get_metadata_export_prng_init_state {
    my $self = shift;

    my %args = (
        format => 'Initial PRNG state',
        parameters => [{
                name       => 'file',
                type       => 'file'
            },
        ],
    );

    return wantarray ? %args : \%args;
}

sub export_prng_init_state {
    my $self = shift;
    my %args = @_;

    my $init_state = $self->get_param ('RAND_INIT_STATE');

    my $filename = $args{file};

    open (my $fh, '>', $filename) || croak "Unable to open $filename\n";
    print {$fh} Data::Dumper::Dumper ($init_state);
    $fh->close;

    print "[RANDOMISE] Dumped initial PRNG state to $filename\n";

    return;
}

sub get_metadata_export_prng_current_state {
    my $self = shift;

    my %args = (
        format => 'Current PRNG state',
        parameters => [{
                name       => 'file',
                type       => 'file'
            },
        ],
    );

    return wantarray ? %args : \%args;
}

sub export_prng_current_state {
    my $self = shift;
    my %args = @_;

    my $init_state = $self->get_param ('RAND_LAST_STATE');

    my $filename = $args{file};

    open (my $fh, '>', $filename) || croak "Unable to open $filename\n";
    print {$fh} Data::Dumper::Dumper ($init_state);
    $fh->close;

    print "[RANDOMISE] Dumped current PRNG state to $filename\n";

    return;
}

#  get a list of the all the publicly available randomisations.
sub get_randomisation_functions {
    my $self = shift || __PACKAGE__;

    my %analyses = $self->get_subs_with_prefix (
        prefix => 'rand_',
        class => __PACKAGE__,
    );
    
    return wantarray ? %analyses : \%analyses;
}

sub check_rand_function_is_valid {
    my $self = shift;
    my %args = @_;
    
    my $function = $args{function} // '';

    my %rand_functions = $self->get_randomisation_functions;

    my $valid = exists $rand_functions{$function};

    croak "Randomisation function $function is not one of "
          . join (', ', keys %rand_functions)
          . "\n"
      if !$valid;

    return 1;
}

#####################################################################
#
#  run the randomisation analysis for a set number of iterations,
#  comparing a set of spatial and tree objects in the basedata object

sub run_analysis {  #  flick them straight through
    my $self = shift;

    my $success = eval {$self->run_randomisation  (@_)};
    croak $EVAL_ERROR if $EVAL_ERROR;

    return $success;
}

sub run_randomisation {
    my $self = shift;
    my %args = @_;

    my $bd = $self->get_param ('BASEDATA_REF') || $args{basedata_ref};

    my $function = $self->get_param ('FUNCTION')
                   // $args{function}
                   // croak "Randomisation function not specified\n";
    $self->check_rand_function_is_valid (function => $function);

    delete $args{function};  #  don't want to pass unnecessary args on to the function
    $self->set_param (FUNCTION => $function);  #  store it

    my $iterations = $args{iterations} || 1;
    delete $args{iterations};

    my $max_iters = $args{max_iters};
    delete $args{max_iters};

    #print "\n\n\nMAXITERS IS $max_iters\n\n\n";

    #  load any predefined args - overriding user specified ones
    my $ref = $self->get_param ('ARGS');
    if (defined $ref) {
        %args = %$ref;
    }
    else {
        $self->set_param (ARGS => \%args);
    }

    my $rand_object = $self->initialise_rand (%args);

    #  get a list of refs for objects that are to be compared
    #  get the lot by default
    my @targets = defined $args{targets}
                ? @{$args{targets}}
                : ($bd->get_cluster_output_refs,
                   $bd->get_spatial_output_refs,
                   );
    delete $args{targets};

    #  loop through and get all the key/value pairs that are not refs.
    #  Assume these are arguments to the randomisation
    my $scalar_args = $EMPTY_STRING;
    foreach my $key (sort keys %args) {
        my $val = $args{$key};
        $val = 'undef' if not defined $val;
        if (not ref ($val)) {
            $scalar_args .= "$key=>$val,";
        }
    }
    $scalar_args =~ s/,$//;  #  remove any trailing comma
    #say "\n\n++++++++++++++++++++++++";
    #say '[RANDOMISE] Scalar arguments are ' . $scalar_args;
    #say "++++++++++++++++++++++++\n\n";

    my $results_list_name
        = $self->get_param ('NAME')
        || $args{results_list_name}
        || uc (
            $function   #  add the args to the list name
            . (length $scalar_args
                ? "_$scalar_args"
                : $EMPTY_STRING)
            );

    #  need to stop these being overridden by later calls
    my $randomise_group_props_by = $args{randomise_group_props_by} // 'no_change';
    my $randomise_trees_by       = $args{randomise_trees_by} // 'no_change';

    #  counts are stored on the outputs, as they can be different if
    #    an output is created after some randomisations have been run
    my $rand_iter_param_name = "RAND_ITER_$results_list_name";

    my $total_iterations = $self->get_param_as_ref ('TOTAL_ITERATIONS');
    if (! defined $total_iterations) {
        $self->set_param (TOTAL_ITERATIONS => 0);
        $total_iterations = $self->get_param_as_ref ('TOTAL_ITERATIONS');
    }

    my $return_success_code = 1;
    my @rand_bd_array;  #  populated if return_rand_bd_array is true
    
    my $progress_bar = Biodiverse::Progress->new(text => 'Randomisation');

    #  do stuff here
    ITERATION:
    foreach my $i (1 .. $iterations) {

        if ($max_iters && $$total_iterations >= $max_iters) {
            print "[RANDOMISE] Maximum iteration count reached: $max_iters\n";
            $return_success_code = 2;
            last ITERATION;
        }

        $$total_iterations++;

        print "[RANDOMISE] $results_list_name iteration $$total_iterations "
            . "($i of $iterations this run)\n";

        $progress_bar->update (
            "Randomisation iteration $i of $iterations this run",
            ($i / $iterations),
        );

        my $rand_bd = eval {
            $self->$function (
                %args,
                rand_object => $rand_object,
                rand_iter   => $$total_iterations,
            );
        };
        croak $EVAL_ERROR if $EVAL_ERROR || ! defined $rand_bd;

        $rand_bd->rename (
            name => $bd->get_param ('NAME') . '_' . $function . '_' . $$total_iterations,
        );

        $self->process_group_props (
            orig_bd  => $bd,
            rand_bd  => $rand_bd,
            function => $randomise_group_props_by,
            rand_object => $rand_object,
        );

        my %randomised_arg_object_cache;

        TARGET:
        foreach my $target (@targets) {
            my $rand_analysis;
            print "target: ", $target->get_param ('NAME') || $target, "\n";

            next TARGET if ! defined $target;
            if (! $target->can('run_analysis')) {
                #if (! $args{retain_outputs}) {
                #    $rand_bd->delete_output (output => $rand_analysis);
                #}
                next TARGET;
            }
            #  allow for older versions that did not flag this
            my $completed = $target->get_param ('COMPLETED') // 1;

            next TARGET if not $completed;  # skip this one, no analyses that worked

            my $rand_count
                = $i + ($target->get_param($rand_iter_param_name) || 0);

            my $name
                = $target->get_param ('NAME') . " Randomise $$total_iterations";
            my $progress_text
                = $target->get_param ('NAME') . "\nRandomise $$total_iterations";

            #  create a new object of the same class
            my %params = $target->get_params_hash;

            #  create the object and add it
            $rand_analysis = ref ($target)->new (
                %params,
                NAME => $name,
            );

            my $check = $rand_bd->add_output (
                #%params,
                name    => $name,
                object  => $rand_analysis,
            );

            #  ensure we use the same PRNG sequence and recreate cluster matrices
            #  HACK...
            my $rand_state = $target->get_param('RAND_INIT_STATE') || [];
            $rand_analysis->set_param(RAND_LAST_STATE => [@$rand_state]);
            my $is_tree_object = eval {$rand_analysis->is_tree_object};
            if ($is_tree_object) {
                $rand_analysis->delete_params (qw/ORIGINAL_MATRICES ORIGINAL_SHADOW_MATRIX/);
                eval {$rand_analysis->override_cached_spatial_calculations_arg};  #  override cluster calcs per node
                $rand_analysis->set_param(NO_ADD_MATRICES_TO_BASEDATA => 1);  #  Avoid adding cluster matrices
            }

            eval {
                $self->override_object_analysis_args (
                    %args,
                    randomised_arg_object_cache => \%randomised_arg_object_cache,
                    object      => $rand_analysis,
                    rand_object => $rand_object,
                    iteration   => $$total_iterations,
                );
            };
            croak $EVAL_ERROR if $EVAL_ERROR;

            eval {
                $rand_analysis->run_analysis (
                    progress_text   => $progress_text,
                    use_nbrs_from   => $target,
                );
            };
            croak $EVAL_ERROR if $EVAL_ERROR;

            eval {
                $target->compare (
                    comparison       => $rand_analysis,
                    result_list_name => $results_list_name,
                )
            };
            croak $EVAL_ERROR if $EVAL_ERROR;

            #  Does nothing if not a cluster type analysis
            eval {
                $self->compare_cluster_calcs_per_node (
                    orig_analysis  => $target,
                    rand_bd        => $rand_bd,
                    rand_iter      => $$total_iterations,
                    retain_outputs => $args{retain_outputs},
                    result_list_name => $results_list_name,
                );
            };
            croak $EVAL_ERROR if $EVAL_ERROR;

            #  and now remove this output to save a bit of memory
            #  unless we've been told to keep it
            #  (this has not been exposed to the GUI yet)
            if (! $args{retain_outputs}) {
                #$rand_bd->delete_output (output => $rand_analysis);
                $rand_bd->delete_all_outputs();
            }
        }

        #  this argument is not yet exposed to the GUI
        if ($args{save_rand_bd}) {
            print "[Randomise] Saving randomised basedata\n";
            $rand_bd->save;
        }
        if ($args{return_rand_bd_array}) {
            push @rand_bd_array, $rand_bd;
        }
        

        #  save incremental basedata file
        if (   defined $args{save_checkpoint}
            && $$total_iterations =~ /$args{save_checkpoint}$/
            ) {

            print "[Randomise] Saving incremental basedata\n";
            my $file_name = $bd->get_param ('NAME');
            $file_name .= '_' . $function . '_iter_' . $$total_iterations;
            eval {
                $bd->save (filename => $file_name);
            };
            croak $EVAL_ERROR if $EVAL_ERROR;
        }
    }

    #  now we're done, increment the randomisation counts
    foreach my $target (@targets) {
        my $count = $target->get_param ($rand_iter_param_name) || 0;
        $count += $iterations;
        $target->set_param ($rand_iter_param_name => $count);
        #eval {$target->clear_lists_across_elements_cache};
    }

    #  and keep a track of the randomisation state,
    #  even though we are storing the object
    #  this is just in case YAML will not work with MT::Auto
    $self->store_rand_state (rand_object => $rand_object);

    #  return the rand_bd's if told to
    return (wantarray ? @rand_bd_array : \@rand_bd_array)
      if $args{return_rand_bd_array};
    
    #  return 1 if successful and ran some iterations
    #  return 2 if successful but did not need to run anything
    return $return_success_code;
}

#  here is where we can hack into the args and override any trees etc
#  (but just trees for now)
sub override_object_analysis_args {
    my $self = shift;
    my %args = @_;

    my $object = $args{object};
    my $cache  = $args{randomised_arg_object_cache};
    my $iter   = $args{iteration};

    #  get a shallow clone
    my ($p_key, $new_analysis_args) = $self->get_analysis_args_from_object (
        object => $object,
    );

    my $made_changes;

    #  The following process could be generalised to handle any of the object types

    my $tree_shuffle_method = $args{randomise_trees_by} // q{};
    if ($tree_shuffle_method && $tree_shuffle_method !~ /^shuffle_/) {  #  add the shuffle prefix if needed
        $tree_shuffle_method = 'shuffle_' . $tree_shuffle_method;
    }

    my $tree_ref_used = $new_analysis_args->{tree_ref};

    if ($tree_ref_used && $tree_shuffle_method && $tree_shuffle_method !~ /no_change$/) {
        my $shuffled_tree = $cache->{$tree_ref_used};
        if (!$shuffled_tree) {  # shuffle and cache if we don't already have it
            $shuffled_tree = $tree_ref_used->clone;
            $shuffled_tree->$tree_shuffle_method (%args);
            $shuffled_tree->rename (
                new_name => $shuffled_tree->get_param ('NAME') . ' ' . $iter,
            );
            $cache->{$tree_ref_used} = $shuffled_tree;
        }
        $new_analysis_args->{tree_ref} = $shuffled_tree;
        $made_changes++;
    }

    return 1 if ! $made_changes;

    $object->set_param ($p_key => $new_analysis_args);

    return 1;
}

#  should be in Biodiverse::Common, or have a method per class  
sub get_analysis_args_from_object {
    my $self = shift;
    my %args = @_;
    
    my $object = $args{object};

    my $get_copy = $args{get_copy} // 1;

    my $analysis_args;
    my $p_key;
  ARGS_PARAM:
    for my $key (qw/ANALYSIS_ARGS SP_CALC_ARGS/) {
        $analysis_args = $object->get_param ($key);
        $p_key = $key;
        last ARGS_PARAM if defined $analysis_args;
    }

    my $return_hash = $get_copy ? {%$analysis_args} : $analysis_args;

    my @results = (
        $p_key,
        $return_hash,
    );

    return wantarray ? @results : \@results;
}

#  need to ensure we re-use the original nodes for the randomisation test
sub compare_cluster_calcs_per_node {
    my $self = shift;
    my %args = @_;

    my $orig_analysis = $args{orig_analysis};
    my $analysis_args = $orig_analysis->get_param ('ANALYSIS_ARGS');

    return if ! eval {$orig_analysis->is_tree_object};
    return if !defined $analysis_args->{spatial_calculations};

    my $bd      = $orig_analysis->get_basedata_ref;
    my $rand_bd = $args{rand_bd};

    #  Get a clone of the cluster tree and attach it to the randomised basedata
    #  Cloning via newick format clears all the params,
    #  so avoids lingering basedata refs and the like
    require Biodiverse::ReadNexus;
    
    my $read_nexus = Biodiverse::ReadNexus->new;
    $read_nexus->import_newick (data => $orig_analysis->to_newick);
    my @tree_array = $read_nexus->get_tree_array;
    my $clone = $tree_array[0];
    bless $clone, blessed ($orig_analysis);

    $clone->rename (new_name => $orig_analysis->get_param ('NAME') . ' rand sp_calc' . $args{rand_iter});
    my %clone_analysis_args = %$analysis_args;
    #$clone_analysis_args{spatial_calculations} = $args{spatial_calculations};
    if (exists $clone_analysis_args{basedata_ref}) {
        $clone_analysis_args{basedata_ref} = $rand_bd;  #  just in case
    }
    $clone->set_basedata_ref (BASEDATA_REF => $rand_bd);
    $clone->set_param (ANALYSIS_ARGS => \%clone_analysis_args);

    $clone->run_spatial_calculations (%clone_analysis_args);

    if ($args{retain_outputs}) {
        $rand_bd->add_output (object => $clone);
    }

    #  now we need to compare the orig and the rand
    my $result_list_name = $args{result_list_name};
    eval {
        $orig_analysis->compare (
            comparison       => $clone,
            result_list_name => $result_list_name,
            no_track_node_stats => 1,
        )
    };
    croak $EVAL_ERROR if $EVAL_ERROR;

    return $clone;
}


#####################################################################
#
#  a set of functions to return a randomised basedata object

sub get_metadata_rand_nochange {
    my $self = shift;
    
    my $group_props_parameters  = $self->get_group_prop_metadata;
    my $tree_shuffle_parameters = $self->get_tree_shuffle_metadata;

    my %args = (
        Description => 'No change - just a cloned data set',
        parameters  => [
            $group_props_parameters,
            $tree_shuffle_parameters,
        ],
    );

    return wantarray ? %args : \%args;
}

#  does not actually change anything - handy for cluster trees to try different selections
sub rand_nochange {
    my $self = shift;
    my %args = @_;

    say "[RANDOMISE] Running 'no change' randomisation";

    my $bd = $self->get_param ('BASEDATA_REF') || $args{basedata_ref};

    #  create a clone with no outputs
    my $new_bd = $bd->clone (no_outputs => 1);

    return $new_bd;
}

sub get_metadata_rand_csr_by_group {
    my $self = shift;

    my $group_props_parameters  = $self->get_group_prop_metadata;
    my $tree_shuffle_parameters = $self->get_tree_shuffle_metadata;


    my %args = (
        Description => 'Complete spatial randomisation by group (currently ignores labels without a group)',
        parameters  => [
            $group_props_parameters,
            $tree_shuffle_parameters,
        ],
    ); 

    return wantarray ? %args : \%args;
}

#  complete spatial randomness by group - just shuffles the subelement lists between elements
sub rand_csr_by_group {
    my $self = shift;
    my %args = @_;

    my $bd = $self->get_param ('BASEDATA_REF') || $args{basedata_ref};

    my $progress_bar = Biodiverse::Progress->new();

    my $rand = $args{rand_object};  #  can't store to all output formats and then recreate
    delete $args{rand_object};

    my $progress_text = "rand_csr_by_group: complete spatial randomisation\n";

    my $new_bd = blessed($bd)->new ($bd->get_params_hash);
    $new_bd->get_groups_ref->set_param ($bd->get_groups_ref->get_params_hash);
    $new_bd->get_labels_ref->set_param ($bd->get_labels_ref->get_params_hash);

    #  pre-assign the hash buckets to avoid rehashing larger structures
    $new_bd->set_group_hash_key_count (count => $bd->get_group_count);
    $new_bd->set_label_hash_key_count (count => $bd->get_label_count);

    my @orig_groups = sort $bd->get_groups;
    #  make sure shuffle does not work on the original data
    my $rand_order = $rand->shuffle ([@orig_groups]);

    say "[RANDOMISE] CSR Shuffling " . (scalar @orig_groups) . " groups";

    #print join ("\n", @candidates) . "\n";

    my $total_to_do = $#orig_groups;

    my $csv_object = $bd->get_csv_object (
        sep_char   => $self->get_param('JOIN_CHAR'),
        quote_char => $self->get_param('QUOTES'),
    );

    foreach my $i (0 .. $#orig_groups) {

        my $progress = $total_to_do <= 0 ? 0 : $i / $total_to_do;

        my $p_text
            = "$progress_text\n"
            . "Shuffling labels from\n"
            . "\t$orig_groups[$i]\n"
            . "to\n"
            . "\t$rand_order->[$i]\n"
            . "(element $i of $total_to_do)";

        $progress_bar->update (
            $p_text,
            $progress,
        );

        #  create the group (this allows for empty groups with no labels)
        $new_bd->add_element(
            group => $rand_order->[$i],
            csv_object => $csv_object,
        );

        #  get the labels from the original group and assign them to the random group
        my %tmp = $bd->get_labels_in_group_as_hash (group => $orig_groups[$i]);

        while (my ($label, $counts) = each %tmp) {
            $new_bd->add_element(
                label => $label,
                group => $rand_order->[$i],
                count => $counts,
                csv_object => $csv_object,
            );
        }
    }

    $bd->transfer_label_properties (
        %args,
        receiver => $new_bd,
    );

    return $new_bd;

}

sub get_metadata_rand_structured {
    my $self = shift;

    my $tooltip_mult =<<'END_TOOLTIP_MULT'
The target richness of each group in the randomised
basedata will be its original richness multiplied
by this value.
END_TOOLTIP_MULT
;

    my $tooltip_addn =<<'END_TOOLTIP_ADDN'
The target richness of each group in the randomised
basedata will be its original richness plus this value.

This is applied after the multiplier parameter so you have:
    target_richness = orig * multiplier + addition.
END_TOOLTIP_ADDN
;

    my $group_props_parameters  = $self->get_group_prop_metadata;
    my $tree_shuffle_parameters = $self->get_tree_shuffle_metadata;

    my %args = (
        parameters  => [ 
            {name       => 'richness_multiplier',
             type       => 'float',
             default    => 1,
             increment  => 1,
             tooltip    => $tooltip_mult,
             },
            {name       => 'richness_addition',
             type       => 'float',
             default    => 0,
             increment  => 1,
             tooltip    => $tooltip_addn,
             },
            $group_props_parameters,
            $tree_shuffle_parameters,
        ],
        Description => "Randomly allocate labels to groups,\n"
                       . 'but keep the richness the same or within '
                       . 'some multiplier factor.',
    );

    return wantarray ? %args : \%args;
}

#  randomly allocate labels to groups, but keep the richness the same or within some multiplier
sub rand_structured {
    my $self = shift;
    my %args = @_;

    my $start_time = [gettimeofday];

    my $bd = $self->get_param ('BASEDATA_REF')
            || $args{basedata_ref};

    my $progress_bar = Biodiverse::Progress->new();

    my $rand = $args{rand_object};  #  can't store to all output formats and then recreate
    delete $args{rand_object};

    #  need to get these from the ARGS param if available - should also croak if negative
    my $multiplier = $args{richness_multiplier} || 1;
    my $addition = $args{richness_addition} || 0;
    my $name = $self->get_param ('NAME');

    my $progress_text =<<"END_PROGRESS_TEXT"
$name
rand_structured:
\trichness multiplier = $multiplier,
\trichness addition = $addition
END_PROGRESS_TEXT
;

    my $new_bd = blessed($bd)->new ($bd->get_params_hash);
    $new_bd->get_groups_ref->set_param ($bd->get_groups_ref->get_params_hash);
    $new_bd->get_labels_ref->set_param ($bd->get_labels_ref->get_params_hash);
    my $new_bd_name = $new_bd->get_param ('NAME');
    $new_bd->rename (name => $new_bd_name . "_" . $name);

    #  pre-assign the hash buckets to avoid rehashing larger structures
    $new_bd->set_group_hash_key_count (count => $bd->get_group_count);
    $new_bd->set_label_hash_key_count (count => $bd->get_label_count);

    say '[RANDOMISE] Creating clone for destructive sampling';
    $progress_bar->update (
        "$progress_text\n"
        . "Creating clone for destructive sampling\n",
        0.1,
    );

    #  create a clone for destructive sampling
    #  clear out the outputs - we seem to get a memory leak otherwise
    my $cloned_bd = $bd->clone (no_outputs => 1);

    $progress_bar->reset;

    #  make sure we randomly select from the same set of groups each time
    my @sorted_groups = sort $bd->get_groups;
    #  make sure shuffle does not work on the original data
    my $rand_gp_order = $rand->shuffle ([@sorted_groups]);

    my @sorted_labels = sort $bd->get_labels;
    #  make sure shuffle does not work on the original data
    my $rand_label_order = $rand->shuffle ([@sorted_labels]);

    printf "[RANDOMISE] Richness Shuffling %s labels from %s groups\n",
       scalar @sorted_labels, scalar @sorted_groups;

    #  generate a hash with the target richness values
    my %target_richness;
    my $i = 0;
    my $total_to_do = scalar @sorted_groups;

    foreach my $group (@sorted_groups) {

        my $progress = $i / $total_to_do;

        $progress_bar->update (
            "$progress_text\n"
            . "Assigning richness targets\n"
            . int (100 * $i / $total_to_do)
            . '%',
              $progress,
        );

        #  round down - could make this an option
        $target_richness{$group} = floor (
            $bd->get_richness (
                element => $group
            )
            * $multiplier
            + $addition
        );
        $i++;
    }

    $progress_bar->reset;

    #  algorithm:
    #  pick a label at random and then scatter its occurrences across
    #  other groups that don't already contain it
    #  and which do not exceed the richness threshold factor
    #  (multiplied by the original richness)

    my @target_groups = $bd->get_groups;
    my %all_target_groups
        = $bd->array_to_hash_keys (list => \@target_groups);
    my %filled_groups;
    my %unfilled_groups = %target_richness;
    my %new_bd_richness;
    my $last_filled     = $EMPTY_STRING;
    $i = 0;
    $total_to_do = scalar @$rand_label_order;
    say "[RANDOMISE] Target is $total_to_do.  Running.";

    my $csv_object = $bd->get_csv_object (
        sep_char   => $self->get_param ('JOIN_CHAR'),
        quote_char => $self->get_param ('QUOTES'),
    );

    BY_LABEL:
    foreach my $label (@$rand_label_order) {

        my $progress = $i / $total_to_do;
        $progress_bar->update (
            "Allocating labels to groups\n"
            . "$progress_text\n"
            . "($i / $total_to_do)",
            $progress,
        );

        $i++;

        ###  get the new groups not containing this label
        ###  - no point aiming for those that have it already
        ###  call will croak if label does not exist, so default to a blank hash
        my $new_bd_has_label
            = eval {$new_bd->get_groups_with_label_as_hash (label => $label)}
            || {};

        #  cannot use $cloned_bd here, as it may not have the full set of groups yet
        my %target_groups = %all_target_groups;

        #  don't consider groups that are full or that already have this label
        if (scalar keys %$new_bd_has_label) {
            delete @target_groups{keys %$new_bd_has_label} ;
        }

        my $check  = scalar keys %target_groups;
        my $check2 = $check;
        if (scalar keys %filled_groups) {
            delete @target_groups{keys %filled_groups};
            $check = scalar keys %target_groups;
        }
        @target_groups = sort keys %target_groups;

        ###  get the remaining original groups containing the original label.  Make sure it's a copy
        my %tmp
            = $cloned_bd->get_groups_with_label_as_hash (label => $label);
        my $tmp_rand_order = $rand->shuffle ([keys %tmp]);

        BY_GROUP:
        foreach my $from_group (@$tmp_rand_order) {
            my $count = $tmp{$from_group};

            #  select a group at random to assign to
            my $j = int ($rand->rand (scalar @target_groups));
            my $to_group = $target_groups[$j];
            #  make sure we don't select this group again
            #  for this label this time round
            splice (@target_groups, $j, 1);

            #  drop out criterion, occurs when $richness_multiplier < 1
            last BY_GROUP if not defined $to_group;  

            warn "SELECTING GROUP THAT IS ALREADY FULL $to_group,"
                 . "$filled_groups{$to_group}, $target_richness{$to_group}, "
                 . "$check $check2 :: $i\n"
                    if defined $to_group and exists $filled_groups{$to_group};

            # assign this label to its new group
            $new_bd->add_element (
                label => $label,
                group => $to_group,
                count => $count,
                csv_object => $csv_object,
            );

            #  now delete it from the list of candidates
            $cloned_bd->delete_sub_element (
                label => $label,
                group => $from_group,
            );
            delete $tmp{$from_group};

            #  increment richness and then check if we've filled this group.
            my $richness = ++$new_bd_richness{$to_group};

            if ($richness >= $target_richness{$to_group}) {

                warn "ISSUES $to_group $richness > $target_richness{$to_group}\n"
                  if ($richness > $target_richness{$to_group});

                $filled_groups{$to_group} = $richness;
                delete $unfilled_groups{$to_group};
                $last_filled = $to_group;
            };

            #  move to next label if no more targets for this label
            last BY_GROUP if !scalar @target_groups;  
        }
    }


    my $target_label_count = $cloned_bd->get_label_count;
    my $target_group_count = $cloned_bd->get_group_count;

    my $format
        = "[RANDOMISE] \n"
          . "New: gps filled, gps unfilled. Old: labels to assign, gps not emptied\n"
          ."\t%d\t\t%d\t\t%d\t\t%d\n";

    printf $format,
           (scalar keys %filled_groups),
           (scalar keys %unfilled_groups),
           $target_label_count,
           $target_group_count;

    #  need to fill in the missing groups with empties
    if ($bd->get_group_count != $new_bd->get_group_count) {
        my %target_gps;
        @target_gps{$bd->get_groups} = ((undef) x $bd->get_group_count);
        delete @target_gps{$new_bd->get_groups};

        my $count = scalar keys %target_gps;
        print '[Randomise structured] '
              . "Creating $count empty groups in new basedata\n";

        foreach my $gp (keys %target_gps) {
            $new_bd->add_element (group => $gp, csv_object => $csv_object);
        }
    }

    $self->swap_to_reach_richness_targets (
        basedata_ref    => $bd,
        cloned_bd       => $cloned_bd,
        new_bd          => $new_bd,
        filled_groups   => \%filled_groups,
        unfilled_groups => \%unfilled_groups,
        rand_object     => $rand,
        target_richness => \%target_richness,
        progress_text   => $progress_text,
        progress_bar    => $progress_bar,
    );

    $bd->transfer_label_properties (
        %args,
        receiver => $new_bd
    );

    my $time_taken = sprintf "%d", tv_interval ($start_time);
    print "[RANDOMISE] Time taken for rand_structured: $time_taken seconds\n";

    #  we used to have a memory leak somewhere, but this doesn't hurt anyway.    
    $cloned_bd = undef;

    return $new_bd;
}

sub swap_to_reach_richness_targets {
    my $self = shift;
    my %args = @_;

    my $cloned_bd       = $args{cloned_bd};
    my $new_bd          = $args{new_bd};
    my %filled_groups   = %{$args{filled_groups}};
    my %unfilled_groups = %{$args{unfilled_groups}};
    my %target_richness = %{$args{target_richness}};
    my $rand            = $args{rand_object};
    my $progress_text   = $args{progress_text};
    my $progress_bar    = $args{progress_bar} // Biodiverse::Progress->new();

    my $bd = $self->get_param ('BASEDATA_REF')
             || $args{basedata_ref};
    

    my $csv_object = $bd->get_csv_object (
        sep_char   => $self->get_param ('JOIN_CHAR'),
        quote_char => $self->get_param ('QUOTES'),
    );

    #  and now we do some amazing cell swapping work to
    #  shunt labels in and out of groups until we're happy

    #  algorithm:
    #   Select an unassigned label.
    #   Find a group that does not contain it.
    #   Swap this label with one of the labels in the group if it is full.
    #   Repeat until we have no more to assign or all groups are full

    my $total_to_do =   (scalar keys %filled_groups)
                      + (scalar keys %unfilled_groups);

    if ($total_to_do) {
        print "[RANDOMISE] Swapping labels to reach richness targets\n";
    }

    my $swap_count = 0;
    my $last_filled = $EMPTY_STRING;
    
    #  Track the labels in the unfilled groups.
    #  This avoids collating them every iteration.
    my (%labels_in_unfilled_gps,
        %unfilled_gps_without_label,
        %unfilled_gps_without_label_by_gp,
    );
    foreach my $gp (keys %unfilled_groups) {
        my $list = $new_bd->get_labels_in_group_as_hash (group => $gp);
        foreach my $label ($bd->get_labels) {
            if (exists $list->{$label}) {
                $labels_in_unfilled_gps{$label}++;
            }
            else {
                $unfilled_gps_without_label{$label} //= [];
                $self->insert_into_sorted_list (
                    item => $gp,
                    list => $unfilled_gps_without_label{$label},
                );
                $unfilled_gps_without_label_by_gp{$gp}{$label}++;
            }
        }
    }

    #  Track which groups do and don't have labels to avoid repeated and
    # expensive method calls to get_groups_with(out)_label_as_hash
    my %groups_without_labels_a;       #  store sorted arrays
    my %cloned_bd_groups_with_label_a;

    #  keep going until we've reached the fill threshold for each group
  BY_UNFILLED_GP:
    while (scalar keys %unfilled_groups) {

    
#  debugging
#my %xx;
#foreach my $lb (keys %unfilled_gps_without_label) {
#    my $lref = $unfilled_gps_without_label{$lb};
#    foreach my $gp (@$lref) {
#        $xx{$gp}{$lb}++;
#    }
#}
#use Test::More;
#Test::More::is_deeply (\%xx, \%unfilled_gps_without_label_by_gp, 'match');


        my $target_label_count = $cloned_bd->get_label_count;
        my $target_group_count = $cloned_bd->get_group_count; 

        my $p = '%8d';
        my $fmt = "Total gps:\t\t\t$p\n"
                . "Unfilled groups:\t\t$p\n"
                . "Filled groups:\t\t$p\n"
                . "Labels to assign:\t\t$p\n"
                . "Old gps to empty:\t$p\n"
                . "Swap count:\t\t\t$p\n"
                . "Last group filled: %s\n";
        my $check_text
            = sprintf $fmt,
                $total_to_do,
                (scalar keys %unfilled_groups),
                (scalar keys %filled_groups),
                $target_label_count,
                $target_group_count,
                $swap_count,
                $last_filled;

        my $progress_i = scalar keys %filled_groups;
        my $progress = $progress_i / $total_to_do;
        $progress_bar->update (
            "Swapping labels to reach richness targets\n"
            . "$progress_text\n"
            . $check_text,
            $progress,
        );

        if ($target_label_count == 0) {
            #  we ran out of labels before richness criterion is met,
            #  eg if multiplier is >1.
            say "[Randomise structured] No more labels to assign";
            last BY_UNFILLED_GP;  
        }

        #  select an unassigned label and group pair
        my @labels = sort $cloned_bd->get_labels;
        my $i = int $rand->rand (scalar @labels);
        my $add_label = $labels[$i];
        
        
        my $from_groups_hash = $cloned_bd->get_groups_with_label_as_hash (
            label => $add_label,
        );
        my $from_cloned_groups_tmp_a = $cloned_bd_groups_with_label_a{$add_label};
        if (!$from_cloned_groups_tmp_a  || !scalar @$from_cloned_groups_tmp_a) {
            my $gps_tmp = $cloned_bd->get_groups_with_label_as_hash (label => $add_label);
            $from_cloned_groups_tmp_a = $cloned_bd_groups_with_label_a{$add_label} = [sort keys %$gps_tmp];
        };

        $i = int ($rand->rand (scalar @$from_cloned_groups_tmp_a));
        my $from_group = $from_cloned_groups_tmp_a->[$i];
        my $add_count  = $from_groups_hash->{$from_group};

        #  clear the pair out of cloned_self
        $cloned_bd->delete_sub_element (
            group => $from_group,
            label => $add_label,
        );
        $self->delete_from_sorted_list (item => $from_group, list => $from_cloned_groups_tmp_a);

        #  Now add this label to a group that does not already contain it.
        #  Ideally we want to find a group that has not yet
        #  hit its richness target, but that is unlikely so we don't look anymore.
        #  Instead we select one at random.
        #  This also avoids the overhead of sorting and
        #  shuffling lists many times.

        my $target_groups_tmp_a = $groups_without_labels_a{$add_label};
        if (!$target_groups_tmp_a || !scalar @$target_groups_tmp_a) {
            my $target_groups_tmp = $new_bd->get_groups_without_label_as_hash (label => $add_label);
            $target_groups_tmp_a  = $groups_without_labels_a{$add_label} = [sort keys %$target_groups_tmp];
        };
        #  cache maintains a sorted list, so no need to re-sort.  
        $i = int $rand->rand(scalar @$target_groups_tmp_a);
        my $target_group = $target_groups_tmp_a->[$i];

        my $target_gp_richness
          = $new_bd->get_richness (element => $target_group);

        #  If the target group is at its richness threshold then
        #  we must first remove one label.
        #  Get a list of labels in this group and select one to remove.
        #  Preferably remove one that can be put into the unfilled groups.
        #  (Should move this to its own sub).
        if ($target_gp_richness >= $target_richness{$target_group})  {
            #  candidates to swap out are ideally
            #  those not in the unfilled groups

            #  we will remove one of these labels
            my %loser_labels = $new_bd->get_labels_in_group_as_hash (
                group => $target_group,
            );
            my %loser_labels2 = %loser_labels;  #  keep a copy
            #  get those not in the unfilled groups
            delete @loser_labels{keys %labels_in_unfilled_gps};

            #  use the lot if all labels are in the unfilled groups
            my $loser_labels_hash_to_use = scalar keys %loser_labels
                                            ? \%loser_labels
                                            : \%loser_labels2;

            my $loser_labels_array
                = $rand->shuffle ([sort keys %$loser_labels_hash_to_use]);

            #  now we loop over the labels and choose the first one that
            #  can be placed in an unfilled group,
            #  otherwise just take the first one

            #  set some defaults
            my $remove_label  = $loser_labels_array->[0];
            my $removed_count = $loser_labels_hash_to_use->{$remove_label};
            my $swap_to_unfilled = 0;

          BY_LOSER_LABEL:
            foreach my $label (@$loser_labels_array) {
                #  Do we have any unfilled groups without this label?
                my $x = $unfilled_gps_without_label{$label} // [];

                next BY_LOSER_LABEL if !scalar @$x;

                $remove_label  = $label;
                $removed_count = $loser_labels_hash_to_use->{$remove_label};
                $swap_to_unfilled = 1;
                last BY_LOSER_LABEL;
            }

            #  Remove it from $target_group in new_bd
            $new_bd->delete_sub_element (
                label => $remove_label,
                group => $target_group,
            );
            #  track the removal only if the tracker hash includes $remove_label
            #  else it will get it next time it needs it
            if (exists $groups_without_labels_a{$remove_label}) {
                #  need to insert into $groups_without_labels_a in sort order
                $self->insert_into_sorted_list (
                    item => $target_group,
                    list => $groups_without_labels_a{$remove_label},
                );
            }
            #   unfilled_groups condition will never trigger in this if-branch
            if (exists $unfilled_groups{$target_group}) {  
                $unfilled_gps_without_label{$remove_label}{$target_group}++;  #  breakage if ever it
            }

            if (! $swap_to_unfilled) {
                #say ":: Swap to unfilled $remove_label";
                #  We can't swap it, so put it back into the
                #  unallocated lists.
                #  Use one of its old locations.
                #  (Just use the first one).
                my %old_groups
                    = $bd->get_groups_with_label_as_hash (
                        label => $remove_label,
                    );

                my @cloned_self_gps_with_label
                    = $cloned_bd->get_groups_with_label_as_hash (
                        label => $remove_label,
                    );

                #  make sure it does not add to an existing case
                delete @old_groups{@cloned_self_gps_with_label};
                my $old_gp = minstr keys %old_groups;
                $cloned_bd->add_element   (
                    label => $remove_label,
                    group => $old_gp,
                    count => $removed_count,
                    csv_object => $csv_object,
                );
                $self->insert_into_sorted_list ( #  update the tracker
                    item => $old_gp,
                    list => $cloned_bd_groups_with_label_a{$remove_label},
                );
            }
            else {
                #  get a list of unfilled candidates to move it to
                #  do this by removing those that have the label
                #  from the list of unfilled groups
                my $unfilled_tmp = $unfilled_gps_without_label{$remove_label} // [];

                croak "ISSUES WITH RETURN GROUPS\n"
                  if !scalar @$unfilled_tmp;

                #  and get one of them at random
                #$i = int $rand->rand (scalar keys %$unfilled_tmp);
                #my @tmp = sort keys %$unfilled_tmp;
                #my $return_gp = $tmp[$i];
                $i = int $rand->rand (scalar @$unfilled_tmp);
                my $return_gp = $unfilled_tmp->[$i];

                $new_bd->add_element   (
                    label => $remove_label,
                    group => $return_gp,
                    count => $removed_count,
                    csv_object => $csv_object,
                );

                my $new_richness = $new_bd->get_richness (
                    element => $return_gp,
                );

                warn "ISSUES WITH RETURN $return_gp\n"
                  if $new_richness > $target_richness{$return_gp};

                $labels_in_unfilled_gps{$remove_label}++;
                $self->delete_from_sorted_list (
                    item => $return_gp,
                    list => $unfilled_gps_without_label{$remove_label},
                );
                delete $unfilled_gps_without_label_by_gp{$return_gp}{$remove_label};
                if (my $aref = $groups_without_labels_a{$remove_label}) {
                    $self->delete_from_sorted_list (
                        item => $return_gp,
                        list => $aref,
                    );
                    if (!scalar @$aref) {
                        delete $groups_without_labels_a{$remove_label};
                    }
                }

                #  if we are now filled then update the tracking hashes
                if ($new_richness >= $target_richness{$return_gp}) {
                    $last_filled = $return_gp;
                    #  clean up the tracker hashes
                    $filled_groups{$last_filled} = $new_richness;
                    delete $unfilled_groups{$last_filled};
                    foreach my $label (keys %{$unfilled_gps_without_label_by_gp{$last_filled}}) {
                        my $list = $unfilled_gps_without_label{$label};
                        $self->delete_from_sorted_list (item => $last_filled, list => $list);
                    }
                    delete $unfilled_gps_without_label_by_gp{$last_filled};
                  LB:
                    foreach my $label ($new_bd->get_labels_in_group (group => $last_filled)) {
                        no autovivification;
                        #  don't decrement empties
                        next LB if !$labels_in_unfilled_gps{$label}; #  also empty
                        $labels_in_unfilled_gps{$label}--;
                        if (!$labels_in_unfilled_gps{$label}) {
                            delete $labels_in_unfilled_gps{$label};
                        }
                    }
                }
            }

            $swap_count ++;

            if (!($swap_count % 1000)) {
                say "Swap count $swap_count";
            }
        }

        #  add the new label to new_bd
        $new_bd->add_element (
            label => $add_label,
            group => $target_group,
            count => $add_count,
            csv_object => $csv_object,
        );
        if (my $aref = $groups_without_labels_a{$add_label}) {
            $self->delete_from_sorted_list (item => $target_group, list => $aref);
            if (!scalar @$aref) {
                delete $groups_without_labels_a{$add_label};
            }
        }
        if (exists $unfilled_groups{$target_group}) {
            my $list = $unfilled_gps_without_label{$add_label};
            $self->delete_from_sorted_list (item => $target_group, list => $list);
            delete $unfilled_gps_without_label_by_gp{$target_group}{$add_label};
        }

        #  check if we've filled this group, if nothing was swapped out
        my $new_richness = $new_bd->get_richness (element => $target_group);

        warn "ISSUES WITH TARGET $target_group\n"
          if $new_richness > $target_richness{$target_group};

        if (    $new_richness != $target_gp_richness 
            and $new_richness >= $target_richness{$target_group}) {

            $filled_groups{$target_group} = $new_richness;
            delete $unfilled_groups{$target_group};  #  no effect if it's not in the list
            LB:
            foreach my $label (keys %{$unfilled_gps_without_label_by_gp{$target_group}}) {
                my $list = $unfilled_gps_without_label{$label};
                $self->delete_from_sorted_list (item => $target_group, list => $list);
            }
            delete $unfilled_gps_without_label_by_gp{$target_group};
            $last_filled = $target_group;
        }
    }

    say "[Randomise structured] Final swap count is $swap_count";

    return;
}


sub process_group_props {
    my $self = shift;
    my %args = @_;

    my $orig_bd = $args{orig_bd};
    my $rand_bd = $args{rand_bd};

    my @keys = $orig_bd->get_groups_ref->get_element_property_keys;

    return if !scalar @keys;

    my $function = $args{function};
    if (not $function =~ /^process_group_props_/) {
        $function = 'process_group_props_' . $function;
    }
    
    my $success = eval {$self->$function (%args)};
    croak $EVAL_ERROR if $EVAL_ERROR;

    return $success;
}

sub process_group_props_no_change {
    my $self = shift;
    my %args = @_;

    my $orig_bd = $args{orig_bd};
    my $rand_bd = $args{rand_bd};

    $orig_bd->transfer_group_properties (
        %args,
        receiver => $rand_bd,
    );

    return;
}

#  move them around as a set of values, so the
#  receiving group gets all of the providing groups props
sub process_group_props_by_set {
    my $self = shift;
    my %args = @_;

    my $orig_bd = $args{orig_bd} || croak "Missing orig_bd argument\n";
    my $rand_bd = $args{rand_bd} || croak "Missing rand_bd argument\n";

    my $rand  = $args{rand_object};

    my $progress_bar = Biodiverse::Progress->new();

    my $elements_ref    = $orig_bd->get_groups_ref;
    my $to_elements_ref = $rand_bd->get_groups_ref;

    my $name        = $self->get_param ('NAME');
    my $to_name     = $rand_bd->get_param ('NAME');
    my $text        = "Transferring group properties from $name to $to_name";

    my $total_to_do = $elements_ref->get_element_count;
    print "[BASEDATA] Transferring properties for $total_to_do groups\n";

    my $count = 0;
    my $i = -1;

    my @to_element_list = sort $to_elements_ref->get_element_list;
    my $shuffled_to_elements = $rand->shuffle (\@to_element_list);

    BY_ELEMENT:
    foreach my $element (sort $elements_ref->get_element_list) {
        $i++;
        my $progress = $i / $total_to_do;
        $progress_bar->update (
            "$text\n"
            . "(label $i of $total_to_do)",
            $progress
        );

        my $to_element = shift @$shuffled_to_elements;

        my $props = $elements_ref->get_list_values (
            element => $element,
            list => 'PROPERTIES'
        );

        next BY_ELEMENT if ! defined $props;  #  none there

        #  delete any existing lists - cleaner and safer than adding to them
        $to_elements_ref->delete_lists (
            element => $to_element,
            lists => ['PROPERTIES'],
        );

        $to_elements_ref->add_to_lists (
            element    => $to_element,
            PROPERTIES => {%$props},  #  make sure it's a copy so bad things don't happen
        );
        $count ++;
    }

    return $count; 
}

#  move them around as a set of values, so the
#  receiving group gets all of the providing groups props
sub process_group_props_by_item {
    my $self = shift;
    my %args = @_;

    my $orig_bd = $args{orig_bd} || croak "Missing orig_bd argument\n";
    my $rand_bd = $args{rand_bd} || croak "Missing rand_bd argument\n";

    my $rand  = $args{rand_object};

    my $progress_bar = Biodiverse::Progress->new();

    my $elements_ref    = $orig_bd->get_groups_ref;
    my $to_elements_ref = $rand_bd->get_groups_ref;

    foreach my $to_element ($to_elements_ref->get_element_list) {
        #  delete any existing lists - cleaner and safer than adding to them
        $to_elements_ref->delete_lists (
            element => $to_element,
            lists => ['PROPERTIES'],
        );
    }

    my $name        = $self->get_param ('NAME');
    my $to_name     = $rand_bd->get_param ('NAME');
    my $text        = "Transferring group properties from $name to $to_name";

    my $total_to_do = $elements_ref->get_element_count;
    print "[BASEDATA] Transferring group properties for $total_to_do\n";

    my $count = 0;
    my $i = -1;

    my @to_element_list = sort $to_elements_ref->get_element_list;
    
    for my $prop_key ($elements_ref->get_element_property_keys) {

        my $shuffled_to_elements = $rand->shuffle ([@to_element_list]);  #  need a shuffled copy

        BY_ELEMENT:
        foreach my $element ($elements_ref->get_element_list) {
            $i++;
            my $progress = $i / $total_to_do;
            $progress_bar->update (
                "$text\n"
                . "(label $i of $total_to_do)",
                $progress
            );

            my $to_element = shift @$shuffled_to_elements;

            my $props = $elements_ref->get_list_values (
                element => $element,
                list => 'PROPERTIES'
            );

            next BY_ELEMENT if ! defined $props;  #  none there
            next BY_ELEMENT if ! exists $props->{$prop_key};

            #  now add the value for this property
            $to_elements_ref->add_to_lists (
                element    => $to_element,
                PROPERTIES => {$prop_key => $props->{$prop_key}},
            );

            $count ++;
        }
    }

    return $count; 
}

my $process_group_props_tooltip = <<'END_OF_GPPROP_TOOLTIP'
Group properties in the randomised basedata will be assigned in these ways:
no_change:  The same as in the original basedata. 
by_set:     All of a group's properties are assigned as a set.
by_item:    Properties are randomly allocated to new groups on an individual basis.  
END_OF_GPPROP_TOOLTIP
  ;

sub get_group_prop_metadata {
    my $self = shift;

    my %metadata = (
        name => 'randomise_group_props_by',
        type => 'choice',
        choices => [qw /no_change by_set by_item/],
        default => 0,
        tooltip => $process_group_props_tooltip,
    );

    return wantarray ? %metadata : \%metadata;
}

#  should build this from metadata
my $randomise_trees_tooltip = <<"END_RANDOMISE_TREES_TOOLTIP"
Trees used as arguments in the analyses will be randomised in these ways:
shuffle_no_change:  Trees will be unchanged. 
shuffle_terminal_names:  Terminal node names will be randomly re-assigned within each tree.
END_RANDOMISE_TREES_TOOLTIP
  ;

sub get_tree_shuffle_metadata {
    my $self = shift;

    require Biodiverse::Tree;
    my $tree = Biodiverse::Tree->new;
    my @choices = sort keys %{$tree->get_subs_with_prefix (prefix => 'shuffle')};
    my $default = first_index {$_ =~ 'no_change$'} @choices;
    @choices = map {(my $x = $_) =~ s/^shuffle_//; $x} @choices;  #  strip the shuffle_ off the front

    my %metadata = (
        name => 'randomise_trees_by',
        type => 'choice',
        choices => \@choices,
        default => $default,
        tooltip => $randomise_trees_tooltip,
    );

    return wantarray ? %metadata : \%metadata;
}


#  handlers to factor out binsearch calls into subs
sub insert_into_sorted_list {
    my $self = shift;
    my %args = @_;
    my $list = $args{list};
    my $item = $args{item};

    my $idx  = binsearch_pos { $a cmp $b } $item, @$list;
    splice @$list, $idx, 0, $item;

    return $idx;
}

sub delete_from_sorted_list {
    my $self = shift;
    my %args = @_;
    my $list = $args{list};
    my $item = $args{item};
    
    my $idx  = binsearch { $a cmp $b } $item, @$list;
    if (defined $idx) {
        splice @$list, $idx, 1;
    }
    return $idx;
}



#  these appear redundant but might help with mem leaks
#our $AUTOLOAD;
#sub AUTOLOAD { my $method = shift;
#              croak "Cannot call method Autoloading not supported in this package";
#              }
#sub DESTROY {}

1;

__END__

=head1 NAME

Biodiverse::Randomise

=head1 SYNOPSIS

  use Biodiverse::Randomise;
  $object = Biodiverse::Randomise->new();

=head1 DESCRIPTION

TO BE FILLED IN

=head1 METHODS

=over

=item INSERT METHODS

=back

=head1 REPORTING ERRORS

Use the issue tracker at http://www.purl.org/biodiverse

=head1 COPYRIGHT

Copyright (c) 2010 Shawn Laffan. All rights reserved.  

=head1 LICENSE

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

For a full copy of the license see <http://www.gnu.org/licenses/>.

=cut

