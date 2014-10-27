package Biodiverse::GUI::GUIManager;

use strict;
use warnings;
use 5.010;

#use Data::Structure::Util qw /has_circular_ref get_refs/; #  hunting for circular refs

our $VERSION = '0.99_005';

#use Data::Dumper;
use Carp;
use Scalar::Util qw /blessed reftype/;

use English ( -no_match_vars );
use Readonly;

use FindBin qw ( $Bin );
use Path::Class ();
use Text::Wrapper;

use Biodiverse::Config;

require Biodiverse::GUI::Project;
require Biodiverse::GUI::BasedataImport;
require Biodiverse::GUI::MatrixImport;
require Biodiverse::GUI::PhylogenyImport;
require Biodiverse::GUI::OpenDialog;
require Biodiverse::GUI::Popup;
require Biodiverse::GUI::Exclusions;
require Biodiverse::GUI::Export;
require Biodiverse::GUI::Tabs::Outputs;
require Biodiverse::GUI::YesNoCancel;
use Biodiverse::GUI::ProgressDialog;

require Biodiverse::BaseData;
require Biodiverse::Matrix;
require Biodiverse::Config;

use parent qw /Biodiverse::Common Biodiverse::GUI::Help/; #/


##########################################################
# Construction
##########################################################
my $singleton;
BEGIN {
    $singleton = {
        project  => undef,    # Our subclass that inherits from the main Biodiverse object
        gladexml => undef,    # Main window widgets
        tabs     => [],       # Stores refs to Tabs objects. In order of page index.
        progress_bars => undef,
        test_val => ''
    };
    bless $singleton, 'Biodiverse::GUI::GUIManager';
    $Biodiverse::Config::running_under_gui = 1;
}

sub instance {
    my $class = shift;
    return $singleton;
}

##########################################################
# Getters / Setters
##########################################################
sub get_version {
    return $VERSION;
}

sub set_glade_xml {
    my $self = shift;
    my $gladexml = shift;
    $self->{gladexml} = $gladexml;
    
    return;
}

sub set_glade_file {
    my $self = shift;
    my $gladefile = shift;
    $self->{gladefile} = $gladefile;
    
    return;
}

sub get_glade_file {
    my $self = shift;
    return $self->{gladefile};
}

sub get_widget {
    my ($self, $id) = @_;
    return $self->{gladexml}->get_widget($id);
}

sub get_status_bar {
    my $self = shift;
    return $self->{gladexml}->get_widget('statusbar');
}

sub get_notebook {
    my $self = shift;
    return $self->{notebook};
}

sub get_project {
    my $self = shift;
    return $self->{project};
}

sub get_base_data_output_model {
    my $self = shift;
    return $self->{basedata_output_model};
}

sub set_dirty {
    my $self = shift;
    $self->{project}->set_dirty;
    return;
}


#  A kludge to stop keyboard events triggering during exports
#  when a display tab is open.
#  Should look into trapping button-press-events
my $activate_keyboard_snooper = 1;

sub activate_keyboard_snooper {
    my $class = shift;
    my $val   = scalar @_ ? (shift @_) : 1;  #  true if no args passed, else take first value
    $activate_keyboard_snooper = !!$val;  #  binarise
}

sub keyboard_snooper_active {
    return $activate_keyboard_snooper;
}

# Progress bar handling.  
# Lifecycle: nothing created on startup.  Subroutines will call add_progress_entry to
# add entries for tracking progress, as many may be active at any time.  When the first progress entry is added,
# the progress dialog will be created and shown.  When all progress entries are finished, the progress dialog
# is hidden (is it worth keeping open briefly or until closed?). 
sub init_progress_window {
    my $self = shift;
    #say 'init_progress_window';

    if ($self->{progress_bars}) {
       say 'prog bars defined';
       croak 'call to init_progress_window when defined';
    }
    
    $self->{progress_bars} = {
        window => undef,
        entry_box => undef,
        dialog_objects => {},
        dialog_entries => {}
    };

    # create window
    my $window = Gtk2::Window->new;
    $window->set_transient_for( $self->get_widget('wndMain') );
    $window->set_title('Progress');
    $window->set_default_size (300, -1);

    # do we need to track delete signals?    
    $window->signal_connect ('delete-event' => \&progress_destroy_callback, $self);

    my $entry_box = Gtk2::VBox->new(0, 5); # homogeneous, spacing
    $window->add($entry_box);

    $self->{progress_bars}->{window}    = $window;
    $self->{progress_bars}->{entry_box} = $entry_box;

    $window->show_all;
}

# called to add record to progress bar display
sub add_progress_entry {
    my ($self, $dialog_obj, $title, $text, $progress) = @_;

    # call init if not defined yet
    $self->init_progress_window if !$self->{progress_bars};
    
    # create new entry frame and widgets
    my $frame = Gtk2::Frame->new($title);
    $self->{progress_bars}->{entry_box}->pack_start($frame, 0, 1, 0);
    
    my $id = $dialog_obj->get_id; # unique number for each, allows hashing
    $self->{progress_bars}->{dialog_objects}{$id} = $dialog_obj;
    $self->{progress_bars}->{dialog_entries}{$id} = $frame;
    #say "values " . Dumper($self->{progress_bars});
    
    my $frame_vbox = Gtk2::VBox->new;
    $frame->add($frame_vbox);
    $frame_vbox->set_border_width(3);
    
    my $label_widget = Gtk2::Label->new;
    $label_widget->set_line_wrap (1);
    $label_widget->set_markup($text);
    $frame_vbox->pack_start($label_widget, 0, 0, 0);
    
    my $progress_widget = Gtk2::ProgressBar->new;
    $frame_vbox->pack_start($progress_widget, 0, 0, 0);

    # show the progress window
    #  don't use present - it grabs the system focus and makes work in other windows impossible
    #$self->{progress_bars}->{window}->present;
    $self->{progress_bars}->{window}->show_all;
    
    #say "Current progress bars: " . Dumper($self->{progress_bars});
    
    #$self->{progress_bars}->{id_to_entryframe}{$new_id}
    # return references to the id number, and label and progress widgets 
    #return ($new_id, $label_widget, $progress_widget);
    return ($label_widget, $progress_widget);
}

# called when a progress dialog finishes, to remove the entry from the display.  assume
# called from dialog
sub clear_progress_entry {    
    my ($self, $dialog_obj) = @_;

    croak 'call to clear_progress_entry when not inited (possibly after window close)' 
        if !$self->{progress_bars};

    croak 'invalid dialog obj given to clear_progress_entry' 
        if !defined $dialog_obj;

    my $id = $dialog_obj->get_id; # unique number for each, allows hashing

    #  sometimes the progress is not initialised, possibly due to threads?
    #  need a method for progress_bar attr
    return if ! (defined $id && defined $dialog_obj->{progress_bar});

    croak 'invalid dialog obj given to clear_progress_entry, can\'t read ID' 
        if !defined $self->{progress_bars}->{dialog_objects}{$id};

    my $entry_frame = $self->{progress_bars}->{dialog_entries}{$id};

    # remove given entry.  assume valid widget provided, otherwise will fail
    $self->{progress_bars}->{entry_box}->remove($entry_frame);
    
    delete $self->{progress_bars}->{dialog_objects}{$id};
    delete $self->{progress_bars}->{dialog_entries}{$id};
    
    # if no active entries in progress dialog, hide it
    if (   !$self->{progress_bars}->{entry_box}->get_children
        || scalar $self->{progress_bars}->{entry_box}->get_children == 0
        ) {
        $self->{progress_bars}->{window}->hide;
    }
    #else {
        #  The resize below triggers Gtk critical warnings when minimised.
        #  We seem not to be able to detect when windows are minimised on Windows
        #  as state is always normal.
        #my $window = $self->{progress_bars}->{window};
        #$window = $self->{gladexml}->get_widget('wndMain');
        #my $state = $window->get_state;
        #warn "State is $state\n";
        #$self->{progress_bars}->{window}->resize(1,1);
    #}
}

# called when window closed, try to stop active process?
sub progress_destroy_callback {
    my ($self_button, $event, $self_gui) = @_;

    #say "callback values " . Dumper($self_gui->{progress_bars});

    say "progress_destroy_callback";
    # call destroy on each child object (?) (need to record each child obj)
    foreach my $dialog (values %{$self_gui->{progress_bars}->{dialog_objects}}) {
        $dialog->end_dialog();
    }

    # clear all progress bar info so re-creates window on next add
    $self_gui->{progress_bars} = undef;

    # send exception to stop operation in progress
    Biodiverse::GUI::ProgressDialog::Cancel->throw(
        message  => "Progress bar closed, operation cancelled",
    );
}    

sub show_progress {
    my $self = shift;

    if ($self->{progress_bars}) {
        $self->{progress_bars}->{window}->show_all;
    }
}

##########################################################
# Initialisation
##########################################################

my $dev_version_warning = <<"END_OF_DEV_WARNING"
This is a development version.

Features are subject to change and it is not guaranteed
to be backwards compatible with previous versions.

To turn off this warning set an environment
variable called BD_NO_GUI_DEV_WARN to a true value.
END_OF_DEV_WARNING
  ;

sub init {
    my $self = shift;

    # title
    $self->{gladexml}->get_widget('wndMain')->set_title(
        'Biodiverse '
        . $self->get_version
    );

    # Notebook...
    $self->{notebook} = Gtk2::Notebook->new;
    $self->{notebook}->set_scrollable(1);
    #$self->{notebook}->popup_enable;
    $self->{notebook}->signal_connect_swapped(
        'switch-page',
        \&on_switch_tab,
        $self,
    );
    $self->{gladexml}->get_widget('vbox1')->pack_start(
        $self->{notebook},
        1,
        1,
        0,
    );    
    $self->{notebook}->show();

    # Hook up the models
    $self->init_combobox('comboBasedata');
    $self->init_combobox('comboMatrices');
    $self->init_combobox('comboPhylogenies');

    # Make the basedata-output model
    # (global - so that new projects use the same one.
    # The output tab then automatically updates
    # whenever projects are reloaded)
    # see Project.pm
    $self->{basedata_output_model}
      = Gtk2::TreeStore->new(
        'Glib::String',  'Glib::String', 'Glib::String',
        'Glib::Scalar',  'Glib::Scalar',
        'Glib::Boolean', 'Glib::String',
    );

    $self->do_new;

    # Show outputs tab
    Biodiverse::GUI::Tabs::Outputs->new();

    #  check if we had any errors when loading extensions
    my @load_extension_errors = Biodiverse::Config::get_load_extension_errors();
    if (@load_extension_errors) {
        my $count = scalar @load_extension_errors;
        my $text = "Failed to load $count extensions\n"
                 . join "\n", $#load_extension_errors;  #  last item is @INC, so not an extension
        $self->report_error($text);
    }

    #  warn if we are a dev version
    if ($VERSION =~ /_/ && !$ENV{BD_NO_GUI_DEV_WARN}) {
        my $dlg = Gtk2::MessageDialog->new (
            undef,   'modal',
            'error', 'ok',
            $dev_version_warning,
        );

        $dlg->run;
        $dlg->destroy;
    }

    return;
}

#sub progress_test {
#    my $self = shift;
#
#    my $dlg = Biodiverse::GUI::ProgressDialog->new;
#
#    #$dlg->update("0.5", 0.5);
#    #sleep(1);
#    #$dlg->update("0.5", 0.6);
#    #sleep(1);
#    $dlg->pulsate("pulsing first time", 0.7);
#    sleep(1); while (Gtk2->events_pending) { Gtk2->main_iteration(); }
#    sleep(1); while (Gtk2->events_pending) { Gtk2->main_iteration(); }
#    sleep(1); while (Gtk2->events_pending) { Gtk2->main_iteration(); }
#
#    sleep(1); $dlg->update("1/3", 0.1);
#    sleep(1); $dlg->update("2/3", 0.4);
#    sleep(1); $dlg->update("3/3", 0.7);
#
#    $dlg->pulsate("pulsing second time", 0.7);
#    sleep(1); while (Gtk2->events_pending) { Gtk2->main_iteration(); }
#    sleep(1); while (Gtk2->events_pending) { Gtk2->main_iteration(); }
#    sleep(1); while (Gtk2->events_pending) { Gtk2->main_iteration(); }
#
#    sleep(1); $dlg->update("1/3", 0.1);
#    sleep(1); $dlg->update("2/3", 0.4);
#    sleep(1); $dlg->update("3/3", 0.7);
#
#    $dlg->destroy;
#    
#    return;
#}

sub init_combobox {
    my ($self, $id) = @_;

    my $combo = $self->{gladexml}->get_widget($id);
    my $renderer = Gtk2::CellRendererText->new();
    $combo->pack_start($renderer, 1);
    $combo->add_attribute($renderer, text => 0);
    
    return;
}

# Called when Project is to be deleted
sub close_project {
    my $self = shift;
    
    return 1 if !defined $self->{project};

    #if (defined $self->{project}) {

        if ($self->{project}->is_dirty()) {
            # Show "Save changes?" dialog
            my $dlgxml = Gtk2::GladeXML->new($self->get_glade_file, 'dlgClose');
            my $dlg = $dlgxml->get_widget('dlgClose');
            $dlg->set_transient_for( $self->get_widget('wndMain') );
            $dlg->set_modal(1);
            my $response = $dlg->run();
            $dlg->destroy();

            # Check response
            if ($response eq 'yes') {
                # Save
                return 0 if not $self->do_save();
            }
            elsif ($response eq 'cancel' or $response ne 'no') {
                # Stop closing
                return 0;
            } # otherwise "no" - don't save - go on
        }

        # Close all analysis tabs (ie: except output tab)
        my @to_remove = @{$self->{tabs}};
        shift @to_remove;
        foreach my $tab (reverse @to_remove) {
            next if (blessed $tab) =~ /Outputs$/;
            $self->remove_tab($tab);
        }

        # Close all label popups
        Biodiverse::GUI::Popup::on_close_all();

        $self->{project} = undef;
    #}

    return 1;
}

##########################################################
# Opening / Creating / Saving
##########################################################
sub do_open {

    # Show the file selection dialogbox
    my $self = shift;
    my $dlg = Gtk2::FileChooserDialog->new(
        'Open Project',
        undef,
        'open',
        'gtk-cancel',
        'cancel',
        'gtk-ok',
        'ok',
    );
    my $filter; 
    
    #  Abortive attempt to load any file.
    #  Need to generalise project opens in a major way to get it to work
    #my @patterns = qw{*.bps *.bds *.bts *.bms *};  
    my @patterns = ('*.bps');
    my @text_vals = (
        'Biodiverse project files',
        #'Biodiverse BaseData files',
        #'Biodiverse tree files',
        #'Biodiverse matrix files',
        #'All files',
    );

    foreach my $i (0 .. $#patterns) {
        my $pattern = $patterns[$i];
        my $text    = $text_vals[$i];
        
        $filter = Gtk2::FileFilter->new();
        $filter->set_name ($text);
        $filter->add_pattern( $pattern ); 
        $dlg->add_filter($filter);
    }

    $dlg->set_modal(1);

    my $filename;
    if ($dlg->run() eq 'ok') {
        $filename = $dlg->get_filename();
    }
    $dlg->destroy();

    if (defined $filename) {
        my $project = $self->open($filename);
        
        #return if (blessed ($project) ne 'Biodiverse::GUI::Project');
    }

    return;
}

sub open {
    my $self = shift;
    my $filename = shift;

    my $object;
    
    if ($self->close_project()) {
        print "[GUI] Loading Biodiverse data from $filename...\n";

        #  using generalised load method
        $object = $self->{project} = eval {
            Biodiverse::GUI::Project->new (file => $filename)
        };
        croak $EVAL_ERROR if $EVAL_ERROR;
        
        # Must do this separately from new_from_xml because it'll otherwise
        # call the GUIManager but the {project} key won't be set yet
        #$self->{project}->init_models();
        if (blessed $object eq 'Biodiverse::GUI::Project') {
            $self->{filename} = $filename;

            $self->update_title_bar;
        }
    }

    return $object;
}

sub update_title_bar {
    my $self = shift;
    
    my $name = $self->{filename} || q{};
    
    my $title = 'Biodiverse '
                . $self->get_version
                . '          '
                . $name;

    $self->{gladexml}->get_widget('wndMain')->set_title($title);

    return;
}

sub do_new {
    my $self = shift;
    if ($self->close_project()) {
        $self->{project} = Biodiverse::GUI::Project->new();
        print "[GUI] Created new Biodiverse project\n";
        delete $self->{filename};
    }
    
    $self->update_title_bar;
    
    return;
}

sub do_save_as {
    # Show the file selection dialogbox (if no existing filename)
    my $self = shift;
    my $filename = shift || $self->show_save_dialog('Save Project', 'bps');

    if (defined $filename) {

        my $file = $self->{project}->save (filename => $filename);

        print "[GUI] Saved Biodiverse project to $file\n";
        $self->{filename} = $file;

        my $title = 'Biodiverse '
                    . $self->get_version
                    . '          '
                    . $file;
        $self->{gladexml}->get_widget('wndMain')->set_title($title);

        $self->{project}->clear_dirty(); # Mark as having no changes

        return 1;
    }

    return 0;
}

sub do_save {
    my $self = shift;
    
    return $self->do_save_as($self->{filename}) 
        if (exists $self->{filename} );

    return $self->do_save_as()
}


##########################################################
# Adding/Removing Matrices and Basedata
##########################################################
sub do_import {
    my $self = shift;
    
    eval {
        Biodiverse::GUI::BasedataImport::run($self);
    };
    if ($EVAL_ERROR) {
        $self->report_error ($EVAL_ERROR);
    }
    
    return;
}

sub do_add_matrix {
    my $self = shift;
    
    eval {
        Biodiverse::GUI::MatrixImport::run($self);
    };
    if ($EVAL_ERROR) {
        $self->report_error ($EVAL_ERROR);
    }
    
    return;
}

sub do_add_phylogeny {
    my $self = shift;
    
    eval {
        Biodiverse::GUI::PhylogenyImport::run($self);
    };
    if ($EVAL_ERROR) {
        $self->report_error ($EVAL_ERROR);
    }
    
    return;
}



sub do_open_matrix {
    my $self = shift;
    my $object = shift;
    
    if (! $object) {
        my ($name, $filename) =
          Biodiverse::GUI::OpenDialog::Run('Open Object', 'bms');

        if (defined $filename && -f $filename) {
            $object = Biodiverse::Tree->new(file => $filename);
            $object->set_param (NAME => $name);  #  override the name if the user says to
        }
    }
    
    return if !$object;

    $self->{project}->add_matrix($object);

    return;
}

sub do_open_phylogeny {
    my $self   = shift;
    my $object = shift;
    
    if (! $object) {
        my ($name, $filename) =
          Biodiverse::GUI::OpenDialog::Run('Open Object', 'bts');

        if (defined $filename && -f $filename) {
            $object = Biodiverse::Tree->new(file => $filename);
            $object->set_param (NAME => $name);  #  override the name if the user says to
        }
    }
    
    return if !$object;

    $self->{project}->add_phylogeny($object);

    return;
}


sub do_open_basedata {
    my $self = shift;

    my ($name, $filename) = Biodiverse::GUI::OpenDialog::Run('Open Object', 'bds');
    if (defined $filename && -f $filename) {
        my $object = Biodiverse::BaseData->new(file => $filename);
        croak "Unable to load basedata object from $filename" if !defined $object;
        $object->set_param (NAME => $name);  #  override the name if the user says to
        $self->{project}->add_base_data($object);
    }
    
    return;
}

sub get_new_basedata_name {
    my $self = shift;
    my %args = @_;
    
    my $suffix = $args{suffix} || q{};

    my $bd = $self->{project}->get_selected_base_data();
    
    # Show the Get Name dialog
    my $dlgxml = Gtk2::GladeXML->new($self->get_glade_file, 'dlgDuplicate');
    my $dlg = $dlgxml->get_widget('dlgDuplicate');
    $dlg->set_transient_for( $self->get_widget('wndMain') );

    my $txt_name = $dlgxml->get_widget('txtName');
    my $name = $bd->get_param('NAME');

    # If it ends with $suffix followed by a number then increment it
    if ($name =~ /(.*$suffix)([0-9]+)$/) {
        $name = $1 . ($2 + 1)
    }
    else {
        $name .= $suffix . 1;
    }
    $txt_name->set_text($name);

    my $response = $dlg->run();
    my $chosen_name;
    if ($response eq 'ok') {
        $chosen_name = $txt_name->get_text;
    }
    $dlg->destroy;
    
    return $chosen_name;
}

sub do_transpose_basedata {
    my $self = shift;
    
    my $new_name = $self->get_new_basedata_name (suffix => '_T');

    return if not $new_name;

    my $bd = $self->{project}->get_selected_base_data();
    my $t_bd = $bd->transpose;
    $t_bd->set_param ('NAME' => $new_name);
    $self->{project}->add_base_data($t_bd);
    
    return;
}

sub do_basedata_reorder_axes {
    my $self = shift;
    
    my $new_name = $self->get_new_basedata_name (suffix => '_R');
    return if not $new_name;
    
    my $bd = $self->{project}->get_selected_base_data();

    #  construct the label and group column settings
    my @lb_axes = 0 .. ($bd->get_labels_ref->get_axis_count - 1);
    my @lb_array;
    for my $i (@lb_axes) {
        push @lb_array, {name => "axis $i", id => $i};
    }

    my @gp_axes = 0 .. ($bd->get_groups_ref->get_axis_count - 1);
    my @gp_array;
    for my $i (@gp_axes) {
        push @gp_array, {name => "axis $i", id => $i};
    }

    my $column_settings = {
        groups => \@gp_array,
        labels => \@lb_array,
    };

    #  need to factor the reorder dialogues out of BasedataImport.pm
    my ($dlgxml, $dlg) = Biodiverse::GUI::BasedataImport::make_reorder_dialog($self, $column_settings);
    my $response = $dlg->run();

    if ($response ne 'ok') {
        $dlg->destroy;
        return;
    }

    my $params = Biodiverse::GUI::BasedataImport::fill_params($dlgxml);
    $dlg->destroy;

    my $new_bd = $bd->new_with_reordered_element_axes (%$params);
    $new_bd->set_param (NAME => $new_name);
    $self->{project}->add_base_data($new_bd);

    $self->set_dirty();

    return;
}

sub do_basedata_attach_label_abundances_as_properties {
    my $self = shift;

    my $bd = $self->{project}->get_selected_base_data();
    
    $bd->attach_label_abundances_as_properties;

    return;
}

sub do_basedata_attach_label_ranges_as_properties {
    my $self = shift;

    my $bd = $self->{project}->get_selected_base_data();

    $bd->attach_label_ranges_as_properties;

    return;
}

sub do_basedata_attach_properties {
    my $self = shift;

    my $bd = $self->{project}->get_selected_base_data();
    croak "Cannot add properties to Basedata with existing outputs\n"
        . "Use the Duplicate Without Outputs option to create a copy without deleting the outputs.\n"
      if $bd->get_output_ref_count;

    # are we attaching groups or labels?
    my $gui = $self;  #  copied code from elsewhere
    my $dlgxml = Gtk2::GladeXML->new($gui->get_glade_file, 'dlgGroupsLabels');
    my $dlg = $dlgxml->get_widget('dlgGroupsLabels');
    $dlg->set_transient_for( $gui->get_widget('wndMain') );
    $dlg->set_modal(1);
    my $label = $dlgxml->get_widget('label_dlg_groups_labels');
    $label->set_text ('Group or label properties?');
    $dlg->set_title('Attach properties');
    my $response = $dlg->run();
    $dlg->destroy();

    return if not $response =~ /^(yes|no)$/;

    my $type = $response eq 'yes' ? 'labels' : 'groups';

    my %options = Biodiverse::GUI::BasedataImport::get_remap_info(
        gui  => $self,
        type => $type,
        column_overrides => [qw /Input_element Property/],
    );
    
    return if ! defined $options{file};
    
    my $props = Biodiverse::ElementProperties->new (name => 'assigning properties');
    $props->import_data (%options);

    my $count = $bd->assign_element_properties (
        properties_object => $props,
        type              => $type,
    );

    if ($count) {
        $self->set_dirty();
    }
    
    my $summary_text = "Assigned properties to $count ${type}";
    my $summary_dlg = Gtk2::MessageDialog->new (
        $self->{gui},
        'destroy-with-parent',
        'info', # message type
        'ok', # which set of buttons?
        $summary_text,
    );
    $summary_dlg->set_title ('Assigned properties');
    
    $summary_dlg->run;
    $summary_dlg->destroy;

    return;
}

sub do_delete_basedata {
    my $self = shift;
 
    my $bd = $self->{project}->get_selected_base_data;
    my $name = $bd->get_param('NAME');

    my $response = Biodiverse::GUI::YesNoCancel->run({
        title => 'Confirmation dialogue',
        text  => "Delete BaseData $name?",
    });

    return if lc ($response) ne 'yes';

    my @tabs = @{$self->{tabs}};
    my $i = 0;
    foreach my $tab (@tabs) {
        next if (blessed $tab) =~ /Outputs$/;
        if ($tab->get_base_ref eq $bd) {
            $tab->on_close;
        }
        $i++;
    }

    $self->{project}->delete_base_data();

    return;
}

sub do_rename_basedata {
    #return;  # TEMP
    my $self = shift;
    my $bd = $self->{project}->get_selected_base_data();
    
    # Show the Get Name dialog
    my $dlgxml = Gtk2::GladeXML->new($self->get_glade_file, 'dlgDuplicate');
    my $dlg = $dlgxml->get_widget('dlgDuplicate');
    $dlg->set_title ('Rename Basedata object');
    $dlg->set_transient_for( $self->get_widget('wndMain') );

    my $txt_name = $dlgxml->get_widget('txtName');
    my $name = $bd->get_param('NAME');

    $txt_name->set_text($name);

    my $response = $dlg->run();
    
    if ($response eq 'ok') {
        my $chosen_name = $txt_name->get_text;
        $self->{project}->rename_base_data($chosen_name);

        my $tab_was_open;
        foreach my $tab (@{$self->{tabs}}) {
            #  don't rename tabs which aren't label viewers
            #my $aa = (blessed $tab);
            next if ! ((blessed $tab) =~ /Labels$/);

            my $reg_ref = eval {$tab->get_base_ref};

            if (defined $reg_ref and $reg_ref eq $bd) {
                $tab->update_name ('Labels - ' . $chosen_name);
                $tab_was_open = 1;
                #  we could stop checking now,
                #  but this allows us to have data
                #  open in more than one tab
            }
        }
    }
    
    $dlg->destroy;
    
    return;
}

sub do_rename_output {
    #return;  # TEMP
    my $self = shift;
    my $selection = shift; #  should really get from system
    
    my $object = $selection->{output_ref};
    
    # Show the Get Name dialog
    my $dlgxml = Gtk2::GladeXML->new($self->get_glade_file, 'dlgDuplicate');
    my $dlg = $dlgxml->get_widget('dlgDuplicate');
    $dlg->set_title ('Rename output');
    $dlg->set_transient_for( $self->get_widget('wndMain') );

    my $txt_name = $dlgxml->get_widget('txtName');
    my $name = $object->get_param('NAME');

    $txt_name->set_text($name);

    my $response = $dlg->run();
    
    my $chosen_name = $txt_name->get_text;
    
    if ($response eq 'ok' and $chosen_name ne $name) {
        #my $chosen_name = $txt_name->get_text;
        
        #  Go find it in any of the open tabs and update it
        #  The update triggers a rename in the output tab, so
        #  we only need this if one is open.
        #  This is messy - really the tab callback should be
        #  adjusted to require an enter key or similar
        my $tab_was_open;
        foreach my $tab (@{$self->{tabs}}) {
            my $reg_ref = $tab->get_current_registration;
            
            if (defined $reg_ref and $reg_ref eq $object) {
                $tab->update_name ($chosen_name);
                $tab_was_open = 1;
                last;  #  comment this line if we ever allow multiple tabs of the same output
            }
        }
        
        if (not $tab_was_open) {
            my $bd = $object->get_param ('BASEDATA_REF');
            eval {
                $bd->rename_output (
                    output => $object,
                    new_name => $chosen_name,
                );
            };
            if ($EVAL_ERROR) {
                $self->report_error ($EVAL_ERROR);
            }
            else {
                $self->{project}->update_output_name( $object );
            }
        }
    }
    $dlg->destroy;
    
    return;
}

sub do_rename_matrix {
    my $self = shift;
    my $ref = $self->{project}->get_selected_matrix();
    
    # Show the Get Name dialog
    my $dlgxml = Gtk2::GladeXML->new($self->get_glade_file, 'dlgDuplicate');
    my $dlg = $dlgxml->get_widget('dlgDuplicate');
    $dlg->set_title ('Rename matrix object');
    $dlg->set_transient_for( $self->get_widget('wndMain') );

    my $txt_name = $dlgxml->get_widget('txtName');
    my $name = $ref->get_param('NAME');

    $txt_name->set_text($name);

    my $response = $dlg->run();
    
    if ($response eq 'ok') {
        my $chosen_name = $txt_name->get_text;
        $self->{project}->rename_matrix($chosen_name, $ref);
    }

    $dlg->destroy;

    return;
}

sub do_rename_phylogeny {
    #return;  # TEMP
    my $self = shift;
    my $ref = $self->{project}->get_selected_phylogeny();

    # Show the Get Name dialog
    my $dlgxml = Gtk2::GladeXML->new($self->get_glade_file, 'dlgDuplicate');
    my $dlg = $dlgxml->get_widget('dlgDuplicate');
    $dlg->set_title ('Rename tree object');
    $dlg->set_transient_for( $self->get_widget('wndMain') );

    my $txt_name = $dlgxml->get_widget('txtName');
    my $name = $ref->get_param('NAME');

    $txt_name->set_text($name);

    my $response = $dlg->run();
    
    if ($response eq 'ok') {
        my $chosen_name = $txt_name->get_text;
        $self->{project}->rename_phylogeny($chosen_name, $ref);
    }

    $dlg->destroy;

    return;
}

sub do_phylogeny_delete_cached_values {
    my $self = shift;
    
    my $object = $self->{project}->get_selected_phylogeny || return;
    $object->get_root_node->delete_cached_values;

    $self->set_dirty;

    return;    
}

sub do_describe_basedata {
    my $self = shift;

    my $bd = $self->{project}->get_selected_base_data;

    my $description = $bd->describe;

    say $description;
    $self->show_describe_dialog ($description);

    return;
}

sub do_describe_matrix {
    my $self = shift;

    my $mx = $self->{project}->get_selected_matrix;

    die "No matrix selected\n" if !defined $mx;

    my $description = $mx->describe;

    say $description;
    $self->show_describe_dialog ($description);

    return;
}

sub do_describe_phylogeny {
    my $self = shift;

    my $tree = $self->{project}->get_selected_phylogeny;
    
    die "No tree selected\n" if !defined $tree;

    my $description = $tree->describe;

    $self->show_describe_dialog ($description);

    return;
}

sub print_describe {
    my $self = shift;
    my $object = shift;
    
    say "DESCRIBE OBJECT\n";
    return scalar $object->describe;
}


sub show_describe_dialog {
    my $self        = shift;
    my $description = shift;
    
    #  passed a string so disassemble it into an array
    if (!reftype ($description)) {
        my @desc = split "\n", $description;
        $description = [];
        foreach my $line (@desc) {
            my @line = split /\b:\s+/, $line;
            push @$description, \@line;
        }
    }
    
    
    my $table_widget;
    if (ref $description) {
        my $row_count = scalar @$description;
        my $table = Gtk2::Table->new ($row_count, 2);
        
        my $i=0;
        foreach my $row (@$description) {
            my $j = 0;
            foreach my $col (@$row) {
                my $label = Gtk2::Label->new;
                $label->set_text ($col);
                $label->set_selectable(1);
                $label->set_padding (10, 10);
                $table->attach_defaults($label, $j, $j+1, $i, $i+1);
                $j++;
            }
            $i++;
        }
        $table_widget = $table;
        
        my $window = Gtk2::Window->new('toplevel');
        $window->set_title('Description');
        $window->add($table_widget);
        $window->show_all;
    }
    else {
        my $dlg = Gtk2::MessageDialog->new (
            $self->{gui},
            'destroy-with-parent',
            'info', # message type
            'ok', # which set of buttons?
            $description,
        );

        $dlg->set_title ('Description');
        
        if ($table_widget) {
            $dlg->attach ($table_widget);
        }
        
        my $response = $dlg->run;
        $dlg->destroy;
    }
    

    return;    
}

sub do_delete_matrix {
    my $self = shift;
    
    my $mx = $self->{project}->get_selected_matrix;

    croak "no selected matrix\n" if ! defined $mx;

    my $name = $mx->get_param('NAME');

    my $response = Biodiverse::GUI::YesNoCancel->run({
        title => 'Confirmation dialogue',
        text  => "Delete matrix $name?",
    });

    return if lc ($response) ne 'yes';

    $self->{project}->delete_matrix();

    return;
}

sub do_delete_phylogeny {
    my $self = shift;
    
    my $tree = $self->{project}->get_selected_phylogeny;
    my $name = $tree->get_param('NAME');

    my $response = Biodiverse::GUI::YesNoCancel->run({
        title => 'Confirmation dialogue',
        text  => "Delete tree $name?",
    });

    return if lc ($response) ne 'yes';

    $self->{project}->delete_phylogeny();
    
    return;
}

sub do_save_matrix {
    my $self = shift;
    my $object = $self->{project}->get_selected_matrix();
    $self->save_object($object);
    
    return;
}

sub do_save_basedata {
    my $self = shift;
    my $object = $self->{project}->get_selected_base_data();
    $self->save_object($object);
    
    return;
}

sub do_save_phylogeny {
    my $self = shift;
    my $object = $self->{project}->get_selected_phylogeny();
    $self->save_object($object);
    
    return;
}

sub do_duplicate_basedata {
    my $self = shift;
    
    my $object = $self->{project}->get_selected_base_data();

    # Show the Get Name dialog
    my $dlgxml = Gtk2::GladeXML->new($self->get_glade_file, 'dlgDuplicate');
    my $dlg = $dlgxml->get_widget('dlgDuplicate');
    $dlg->set_transient_for( $self->get_widget('wndMain') );

    my $txt_name = $dlgxml->get_widget('txtName');
    my $name = $object->get_param('NAME');

    # If ends with a number increment it
    if ($name =~ /(.*)([0-9]+)$/) {
        $name = $1 . ($2 + 1);
    }
    else {
        $name .= '1';
    }
    $txt_name->set_text($name);

    my $response = $dlg->run();
    if ($response eq 'ok') {
        my $chosen_name = $txt_name->get_text;
        # This uses the dclone method from Storable
        my $cloned = $object->clone (@_);  #  pass on the args
        $cloned->set_param (NAME => $chosen_name || $object->get_param ('NAME') . "_CLONED");
        $self->{project}->add_base_data($cloned);
    }

    $dlg->destroy();
    
    $self->set_dirty;
    return;
}

sub do_rename_basedata_labels {
    my $self = shift;
    
    my $bd = $self->{project}->get_selected_base_data();
    my %options = Biodiverse::GUI::BasedataImport::get_remap_info (
        gui => $self,
        column_overrides => [qw /Input_element Remapped_element/],
    );
    
    ##  now do something with them...
    if ($options{file}) {
        #my $file = $options{file};
        my $check_list = Biodiverse::ElementProperties->new;
        $check_list->import_data (%options);
        $bd->rename_labels (remap => $check_list);
    }

    $self->set_dirty;
    return;
}

sub do_binarise_basedata_elements {
    my $self = shift;

    my $bd = $self->{project}->get_selected_base_data();
    return if !$bd;

    $bd->binarise_sample_counts;

    $self->set_dirty;
}

sub do_add_basedata_label_properties {
    my $self = shift;
    
    my $bd = $self->{project}->get_selected_base_data();
    my %options = Biodiverse::GUI::BasedataImport::get_remap_info (
        gui => $self,
    );

    ##  now do something with them...
    if ($options{file}) {
        #my $file = $options{file};
        my $check_list = Biodiverse::ElementProperties->new;
        $check_list->import_data (%options);
        $bd->assign_element_properties (
            type              => 'labels',
            properties_object => $check_list,
        );
    }

    $self->set_dirty;
    return;
}

sub do_add_basedata_group_properties {
    my $self = shift;
    
    my $bd = $self->{project}->get_selected_base_data();
    my %options = Biodiverse::GUI::BasedataImport::get_remap_info (
        gui => $self,
    );

    ##  now do something with them...
    if ($options{file}) {
        #my $file = $options{file};
        my $check_list = Biodiverse::ElementProperties->new;
        $check_list->import_data (%options);
        $bd->assign_element_properties (
            type              => 'groups',
            properties_object => $check_list,
        );
    }

    $self->set_dirty;
    return;
}

sub do_export_groups {
    my $self = shift;
    
    my $base_ref = $self->{project}->get_selected_base_data();
    Biodiverse::GUI::Export::Run($base_ref->get_groups_ref);
    
    return;
}

sub do_export_labels {
    my $self = shift;
    
    my $base_ref = $self->{project}->get_selected_base_data();
    Biodiverse::GUI::Export::Run($base_ref->get_labels_ref);
    
    return;
}

sub do_export_matrix {
    my $self = shift;
    
    my $object = $self->{project}->get_selected_matrix || return;
    Biodiverse::GUI::Export::Run($object);
    
    return;
}

sub do_export_phylogeny {
    my $self = shift;
    
    my $object = $self->{project}->get_selected_phylogeny || return;
    Biodiverse::GUI::Export::Run($object);
    
    return;
}

# Saves an object in native format
sub save_object {
    my $self = shift;
    my $object = shift;

    my $suffix_str = $object->get_param('OUTSUFFIX');
    #my $suffix_xml = $object->get_param('OUTSUFFIX_XML');
    my $suffix_yaml = $object->get_param('OUTSUFFIX_YAML');
    my $filename = $self->show_save_dialog('Save Object', $suffix_str, $suffix_yaml);

    if (defined $filename) {

        my ($prefix, $suffix) = $filename =~ /(.*?)\.(...)$/;
        if (not defined $prefix) {
            $prefix = $filename;
        }
        $object->set_param('OUTPFX', $prefix);
        
        $object->save (filename => $filename);
    }
    
    return;
}

##########################################################
# Base sets / Matrices combos
##########################################################

#  sometime we need to force this
sub set_active_iter {
    my $self  = shift;
    my $combo = shift;
    
    my $iter = $combo->get_active_iter();
    
    #  drop out if it is set
    return if $iter;
    
    #  loop over the iters and choose the one called none
    my $i = 0;
    while (1) {
        $combo->set_active_iter ($i);
        $iter = $combo->get_active_iter();
        return if $iter->get_text eq '(none)';
    }
    
    return;
}

sub set_basedata_model {
    my $self  = shift;
    my $model = shift;
    
    $self->{gladexml}->get_widget('comboBasedata')->set_model($model);
    
    return;
}

sub set_matrix_model {
    my $self  = shift;
    my $model = shift;
    
    my $widget = $self->{gladexml}->get_widget('comboMatrices')->set_model($model);

    return;
}

sub set_phylogeny_model {
    my $self  = shift;
    my $model = shift;

    $self->{gladexml}->get_widget('comboPhylogenies')->set_model($model);

    return;
}

sub set_basedata_iter {
    my $self = shift;
    my $iter = shift;

    my $combo = $self->{gladexml}->get_widget('comboBasedata');
    $combo->set_active_iter($iter);
    $self->{active_basedata} = $combo->get_model()->get_string_from_iter($iter);
    
    return;
}

sub set_matrix_iter {
    my $self = shift;
    my $iter = shift;

    my $combo = $self->{gladexml}->get_widget('comboMatrices');
    $combo->set_active_iter($iter);
    $self->{active_matrix} = $combo->get_model()->get_string_from_iter($iter);
    
    return;
}

sub set_phylogeny_iter {
    my $self = shift;
    my $iter = shift;

    my $combo = $self->{gladexml}->get_widget('comboPhylogenies');
    return if not $iter;
    croak "pyhlogeny iter undef\n" if not defined $iter;
    $combo->set_active_iter($iter);
    $self->{active_phylogeny} = $combo->get_model()->get_string_from_iter($iter);
    
    return;
}

sub do_basedata_changed {
    my $self = shift;
    my $combo = $self->{gladexml}->get_widget('comboBasedata');
    my $iter = $combo->get_active_iter();
    
    return if ! defined $iter;  #  sometimes $iter is not defined when this sub is called.  
    
    my $text = $combo->get_model->get($iter, 0);

    # FIXME: not sure how $self->{project} can be undefined - but it appears to be
    if (defined $self->{project} and 
        defined $self->{active_basedata} and 
        $combo->get_model->get_string_from_iter($iter) ne $self->{active_basedata}
        ) {
        $self->{project}->select_base_data_iter( $iter ) if not ($text eq '(none)');
    }
    
    return;
}

sub do_convert_labels_to_phylogeny {
    my $self = shift;
    
    my $bd = $self->{project}->get_selected_base_data;
    
    return if ! defined $bd;
    
    # Show the Get Name dialog
    my $dlgxml = Gtk2::GladeXML->new($self->get_glade_file, 'dlgDuplicate');
    my $dlg = $dlgxml->get_widget('dlgDuplicate');
    $dlg->set_transient_for( $self->get_widget('wndMain') );

    my $txt_name = $dlgxml->get_widget('txtName');
    my $name = $bd->get_param('NAME');

    # If ends with _T followed by a number then increment it
    #if ($name =~ /(.*_AS_TREE)([0-9]+)$/) {
        #$name = $1 . ($2 + 1)
    #}
    #else {
        $name .= '_AS_TREE';
    #}
    $txt_name->set_text($name);

    my $response = $dlg->run();
    if ($response eq 'ok') {
        my $chosen_name = $txt_name->get_text;
        my $phylogeny = $bd->to_tree (name => $chosen_name);
        #$phylogeny->set_param (NAME => $chosen_name);
        if (defined $phylogeny) {
            #  now we add it if it is not already in the list
            # otherwise we select it
            my $phylogenies = $self->{project}->get_phylogeny_list;
            my $in_list = 0;
            foreach my $ph (@$phylogenies) {
                if ($ph eq $phylogeny) {
                    $in_list = 1;
                    last;
                }
            }
            if ($in_list) {
                $self->{project}->select_phylogeny ($phylogeny);
            }
            else {
                $self->{project}->add_phylogeny ($phylogeny, 0);
            }
        }
    }
    $dlg->destroy;

    return;
}

sub do_convert_matrix_to_phylogeny {
    my $self = shift;
    
    my $matrix_ref = $self->{project}->get_selected_matrix;
    
    if (! defined $matrix_ref) {
        Biodiverse::GUI::YesNoCancel->run({
            header      => 'no matrix selected',
            hide_yes    => 1,
            hide_no     => 1,
            hide_cancel => 1
        });
        return 0;
    }
    
    my $phylogeny = $matrix_ref->get_param ('AS_TREE');
    
    my $response = 'no';
    if (defined $phylogeny) {
        my $mx_name = $matrix_ref->get_param ('NAME');
        my $ph_name = $phylogeny->get_param ('NAME');
        $response = Biodiverse::GUI::YesNoCancel->run({
            header  => "$mx_name has already been converted.",
            text    => "Use cached tree $ph_name?"
        });
        return if $response eq 'cancel';
    }
    
    if ($response eq 'no') {  #  get a new one
        
        # Show the Get Name dialog
        my $dlgxml = Gtk2::GladeXML->new($self->get_glade_file, 'dlgDuplicate');
        my $dlg = $dlgxml->get_widget('dlgDuplicate');
        $dlg->set_transient_for( $self->get_widget('wndMain') );
    
        my $txt_name = $dlgxml->get_widget('txtName');
        my $name = $matrix_ref->get_param('NAME');
    
        # If ends with _T followed by a number then increment it
        if ($name =~ /(.*_AS_TREE)([0-9]+)$/) {
            $name = $1 . ($2 + 1)
        }
        else {
            $name .= '_AS_TREE1';
        }
        $txt_name->set_text($name);
    
        $response = $dlg->run();
        
        if ($response eq 'ok') {
            my $chosen_name = $txt_name->get_text;
            $matrix_ref->set_param (AS_TREE => undef);  #  clear the previous version

            eval {
                $phylogeny = $matrix_ref->to_tree (
                    linkage_function => 'link_average',
                );
            };
            if ($EVAL_ERROR) {
                $self->report_error ($EVAL_ERROR);
                $dlg->destroy;
                return;
            }

            $phylogeny->set_param (NAME => $chosen_name);
            if ($self->get_param ('CACHE_MATRIX_AS_TREE')) {
                $matrix_ref->set_param (AS_TREE => $phylogeny);
            }
        }
        $dlg->destroy;
    }
    
    #  now we add it if it is not already in the list
    #  otherwise we select it
    my $phylogenies = $self->{project}->get_phylogeny_list;
    my $in_list = 0;
    foreach my $mx (@$phylogenies) {
        if ($mx eq $phylogeny) {
            $in_list = 1;
            last;
        }
    }
    if ($in_list) {
        $self->{project}->select_phylogeny ($phylogeny);
    }
    else {
        $self->{project}->add_phylogeny ($phylogeny, 0);
    }

    return;
}

sub do_convert_phylogeny_to_matrix {
    my $self = shift;
    my $phylogeny = $self->{project}->get_selected_phylogeny;

    if (! defined $phylogeny ) {
        Biodiverse::GUI::YesNoCancel->run(
            {
                header      => 'no phylogeny selected',
                hide_no     => 1,
                hide_yes    => 1,
                hide_cancel => 1,
            }
        );
        return 0;
    }

    my $matrix_ref = $phylogeny->get_param ('AS_MX');
    my $response = 'no';
    if (defined $matrix_ref) {
        my $mx_name = $matrix_ref->get_param ('NAME');
        my $ph_name = $phylogeny->get_param ('NAME');
        $response = Biodiverse::GUI::YesNoCancel->run(
            {
                header  => "$ph_name has already been converted",
                text    => "use cached tree $mx_name?"
            }
        );
        return 0 if $response eq 'cancel';
    }

    if ($response eq 'no') {  #  get a new one
        # Show the Get Name dialog
        my $dlgxml = Gtk2::GladeXML->new($self->get_glade_file, 'dlgDuplicate');
        my $dlg = $dlgxml->get_widget('dlgDuplicate');
        $dlg->set_transient_for( $self->get_widget('wndMain') );

        my $txt_name = $dlgxml->get_widget('txtName');
        my $name = $phylogeny->get_param('NAME');

        # If ends with _AS_MX followed by a number then increment it
        if ($name =~ /(.*_AS_MX)([0-9]+)$/) {
            $name = $1 . ($2 + 1)
        }
        else {
            $name .= '_AS_MX1';
        }
        $txt_name->set_text($name);

        $response = $dlg->run();

        if ($response eq 'ok') {
            my $chosen_name = $txt_name->get_text;
            $dlg->destroy;

            eval {
                $matrix_ref = $phylogeny->to_matrix (
                        name => $chosen_name,
                );
            };
            if ($EVAL_ERROR) {
                $self->report_error ($EVAL_ERROR);
                return;
            }

            if ($phylogeny->get_param ('CACHE_TREE_AS_MATRIX')) {
                $phylogeny->set_param (AS_MX => $matrix_ref);
            }

        }
    }
    
    #  now we add it if it is not already in the list
    #  otherwise we select it
    my $matrices = $self->{project}->get_matrix_list;
    my $in_list = 0;
    foreach my $mx (@$matrices) {
        if ($mx eq $matrix_ref) {
            $in_list = 1;
            last;
        }
    }
    if ($in_list) {
        $self->{project}->select_matrix ($matrix_ref);
    }
    else {
        $self->{project}->add_matrix ($matrix_ref, 0);
    }

    return;
}

sub do_range_weight_tree {
    my $self = shift;

    return $self->do_trim_tree_to_basedata (
        do_range_weighting => 1,
        suffix             => 'RW',
    );
}


#  Should probably rename this sub as it is being used for more purposes,
#  some of which do not involve trimming.  
sub do_trim_tree_to_basedata {
    my $self = shift;
    my %args = @_;

    my $phylogeny = $self->{project}->get_selected_phylogeny;
    my $bd = $self->{project}->get_selected_base_data || return 0;
    
    if (! defined $phylogeny) {
        Biodiverse::GUI::YesNoCancel->run({
            header       => 'no tree selected',
            hide_yes     => 1,
            hide_no      => 1,
            hide_cancel  => 1,
            }
        );

        return 0;
    }

    # Show the Get Name dialog
    my $dlgxml = Gtk2::GladeXML->new($self->get_glade_file, 'dlgDuplicate');
    my $dlg = $dlgxml->get_widget('dlgDuplicate');
    $dlg->set_transient_for( $self->get_widget('wndMain') );

    my $txt_name = $dlgxml->get_widget('txtName');
    my $name = $phylogeny->get_param('NAME');

    my $suffix = $args{suffix} || 'TRIMMED';
    # If ends with _TRIMMED followed by a number then increment it
    if ($name =~ /(.*_$suffix)([0-9]+)$/) {
        $name = $1 . ($2 + 1)
    }
    else {
        $name .= "_${suffix}1";
    }
    $txt_name->set_text($name);

    my $response = $dlg->run();
    my $chosen_name = $txt_name->get_text;

    $dlg->destroy;

    return if $response ne 'ok';  #  they chickened out

    my $new_tree = $phylogeny->clone;
    if (!$args{no_trim}) {
        $new_tree->trim (keep => scalar $bd->get_labels);
    }

    if ($args{do_range_weighting}) {
        foreach my $node ($new_tree->get_node_refs) {
            my $range = $node->get_node_range (basedata_ref => $bd);
            $node->set_length (length => $node->get_length / $range);
        }
    }

    $new_tree->set_param (NAME => $chosen_name);

    #  now we add it if it is not already in the list
    #  otherwise we select it
    my $phylogenies = $self->{project}->get_phylogeny_list;

    my $in_list = grep {$_ eq $new_tree} @$phylogenies;

    if ($in_list) {
        $self->{project}->select_phylogeny ($new_tree);
    }
    else {
        $self->{project}->add_phylogeny ($new_tree, 0);
    }

    return;
}

sub do_tree_equalise_branch_lengths {
    my $self = shift;
    my %args = @_;

    my $phylogeny = $self->{project}->get_selected_phylogeny;

    if (! defined $phylogeny) {
        Biodiverse::GUI::YesNoCancel->run({
            header       => 'no tree selected',
            hide_yes     => 1,
            hide_no      => 1,
            hide_cancel  => 1,
            }
        );

        return 0;
    }

    # Show the Get Name dialog
    my $dlgxml = Gtk2::GladeXML->new($self->get_glade_file, 'dlgDuplicate');
    my $dlg = $dlgxml->get_widget('dlgDuplicate');
    $dlg->set_transient_for( $self->get_widget('wndMain') );

    my $txt_name = $dlgxml->get_widget('txtName');
    my $name = $phylogeny->get_param('NAME');

    my $suffix = $args{suffix} || 'EQ';
    # If ends with _TRIMMED followed by a number then increment it
    if ($name =~ /(.*_$suffix)([0-9]+)$/) {
        $name = $1 . ($2 + 1)
    }
    else {
        $name .= "_${suffix}1";
    }
    $txt_name->set_text($name);

    my $response    = $dlg->run();
    my $chosen_name = $txt_name->get_text;

    $dlg->destroy;

    return if $response ne 'ok';  #  they chickened out

    my $new_tree = $phylogeny->clone_tree_with_equalised_branch_lengths;

    $new_tree->set_param (NAME => $chosen_name);

    #  now we add it if it is not already in the list
    #  otherwise we select it
    my $phylogenies = $self->{project}->get_phylogeny_list;

    my $in_list = grep {$_ eq $new_tree} @$phylogenies;

    if ($in_list) {
        $self->{project}->select_phylogeny ($new_tree);
    }
    else {
        $self->{project}->add_phylogeny ($new_tree, 0);
    }

    return;
}

sub do_basedata_extract_embedded_trees {
    my $self = shift;
    
    my $bd = $self->{project}->get_selected_base_data();
    
    return if !defined $bd;
    
    my @objects = $bd->get_embedded_trees;

    foreach my $object (@objects) {
        $self->do_open_phylogeny($object);
    }

    return;
}

sub do_basedata_extract_embedded_matrices {
    my $self = shift;
    
    my $bd = $self->{project}->get_selected_base_data();
    
    return if !defined $bd;
    
    my @objects = $bd->get_embedded_matrices;
    
    foreach my $object (@objects) {
        $self->do_open_matrix($object);
    }
    
    return;
}

sub do_basedata_trim_to_tree {
    my $self = shift;
    my %args = @_;  #  keep or trim flag

    my $bd   = $self->{project}->get_selected_base_data;
    my $tree = $self->{project}->get_selected_phylogeny;

    return if !defined $bd || ! defined $tree;

    $self->do_trim_basedata ($bd, $tree, %args);

    return;
}

sub do_basedata_trim_to_matrix {
    my $self = shift;
    my %args = @_;  #  keep or trim flag

    my $bd = $self->{project}->get_selected_base_data;
    my $mx = $self->{project}->get_selected_matrix;

    return if !defined $bd || ! defined $mx;

    $self->do_trim_basedata ($bd, $mx, %args);
    
    return;
}

sub do_trim_basedata {
    my $self = shift;
    my $bd   = shift;
    my $data = shift;
    my %args = @_;
    
    my %results = eval {
        $bd->trim ($args{option} => $data);
    };
    if ($EVAL_ERROR) {
        $self->report_error ($EVAL_ERROR);
        return;
    }

    my $label_count = $bd->get_label_count;
    my $group_count = $bd->get_group_count;
    my $name = $bd->get_param('NAME');

    my $text = "Deleted $results{DELETE_COUNT} labels"
             . " from $results{DELETE_SUB_COUNT} groups. "
             . "$name has $label_count labels remaining across "
             . "$group_count groups.\n";

    $self->report_error (
        $text,
        'Trim results',
    );

    if ($results{DELETE_COUNT}) {
        $self->set_dirty();
    }

    return;
}

sub do_matrix_changed {
    my $self = shift;
    my $combo = $self->{gladexml}->get_widget('comboMatrices');
    my $iter = $combo->get_active_iter();
    #print "MATRIX CHANGE ITER IS $iter";
    #my ($text) = $combo->get_model->get($iter, 0);

    if (defined $iter and
        defined $self->{project} and 
        defined $self->{active_matrix} and 
        $combo->get_model->get_string_from_iter($iter) ne $self->{active_matrix}
        ) {
        #warn $text . "\n";
        $self->{project}->select_matrix_iter( $iter );
    }
    
    return;
}

sub do_phylogeny_changed {
    my $self = shift;
    my $combo = $self->{gladexml}->get_widget('comboPhylogenies');
    my $iter = $combo->get_active_iter();
    #my ($text) = $combo->get_model->get($iter, 0);

    if (defined $iter and
        defined $self->{project} and 
        defined $self->{active_phylogeny} and 
        $combo->get_model->get_string_from_iter($iter) ne $self->{active_phylogeny}
        ) {
        $self->{project}->select_phylogeny_iter( $iter );
    }

    return;
}

##########################################################
# Tabs
##########################################################

sub add_tab {
    my $self = shift;
    my $tab = shift;
    my $page = $tab->get_page_index;
    
    # Add tab to our array at the right position
    push @{$self->{tabs}}, $tab;

    # Enable keyboard shortcuts (CTRL-G)
    $tab->set_keyboard_handler();

    # Switch to added tab
    $self->switch_tab($tab);
    
    return;
}

sub switch_tab {
    my $self = shift;
    my $tab  = shift; # Expecting the tab object
    my $page = shift;
    
    if ($tab) {
        my $index = $tab->get_page_index;
        $self->get_notebook->set_current_page($tab->get_page_index);
    }
    else {
        my $last_page = $self->get_notebook->get_nth_page(-1);
        my $max_page_index = $self->get_notebook->page_num($last_page);
        if ($page > $max_page_index) {
            $page = 0;
        }
        elsif ($page < 0) {
            $page = $max_page_index;
        }
        $self->get_notebook->set_current_page($page);
    }
    
    return;
}

sub remove_tab {
    my $self = shift;
    my $tab = shift;
    
    #  don't close the outputs tab
    return if (blessed $tab) =~ /Outputs$/;

    # Remove tab from our array
    #  do we really need to store the tabs?
    my @tabs = @{$self->{tabs}};
    my $i = $#tabs;
    foreach my $check (reverse @tabs) {
        if ($tab eq $check) {
            splice(@{$self->{tabs}}, $i, 1);
        }
        $i --;
    }
    undef @tabs;

    $tab->remove_keyboard_handler();
    $tab->remove();

    return;
}

sub on_switch_tab {
    my $self = shift;
    my $page = shift;  #  passed by Gtk, not needed here
    my $page_index = shift;  #  passed by gtk

    foreach my $tab (@{$self->{tabs}}) {
        next if $page_index != $tab->get_page_index;
        $tab->set_keyboard_handler();
        last;
    }

    return;
}

##########################################################
# Spatial index dialog
##########################################################

sub delete_index {
    my $self = shift;
    my $bd = shift
        || $self->{project}->get_selected_base_data;
    
    my $result = $bd->delete_spatial_index;

    my $name = $bd->get_param ('NAME');

    if ($result) {
        $self->set_dirty();
        $self->report_error (
            "BaseData $name: Spatial index deleted\n",
            q{},
        );
    }
    else {
        $self->report_error (
            "BaseData $name: had no spatial index, so nothing deleted\n",
            q{},
        );
    }

    return;
}


#  show the spatial index dialogue
#  need to add buttons to increment/decrement all by the step size
sub show_index_dialog {
    my $self = shift;

    my $gui = Biodiverse::GUI::GUIManager->instance;

    #  get an array of the cellsizes
    my $bd = $self->{project}->get_selected_base_data;
    my @cellsize_array = $bd->get_cell_sizes;  #  get a copy
    my %coord_bounds   = $bd->get_coord_bounds;

    #  get the current index
    my $used_index = $bd->get_param('SPATIAL_INDEX');
    my @resolutions;
    if ($used_index) {
        my $res_array = $used_index->get_param('RESOLUTIONS');
        @resolutions = @$res_array;
    }

    #  create the table and window
    #  we really should generate one from scratch...
    my $dlgxml = Gtk2::GladeXML->new($self->get_glade_file, 'dlgImportParameters');
    my $tooltip_group = Gtk2::Tooltips->new;
    my $table = $dlgxml->get_widget('tableImportParameters');

    #my $window = Gtk2::Window->new;
    #$window->set_title ('Set index sizes xxxx');
    #$window->set_resizable (1);
    #$window->set_modal (1);
    ##$window->set_position ('GTK_WIN_POS_CENTER_ON_PARENT');
    #$window->set_transient_for ( $gui->get_widget('wndMain') );
    #my $table = Gtk2::Table->new (1,2);
    #$table->set_col_spacings (3);
    #$table->set_row_spacings (3);
    #$window->add ($table);

    #$table->set_homogeneous (0);

    my $dlg = $dlgxml->get_widget('dlgImportParameters');
    $dlg->set_transient_for( $self->get_widget('wndMain') );
    $dlg->set_title ('Set index sizes');
    
    # Make the checkbox to use index or not
    #my $check_label = Gtk2::Label->new;
    #$check_label->set_use_markup (1);
    #$check_label->set_markup( '<b>Use index?</b>' );
    #my $check_box = Gtk2::CheckButton->new;
    #$check_box->set(active => $used_index ? 1 : 0);
    #my $rows = $table->get('n-rows');
    #$rows++;
    #$table->set('n-rows' => $rows);
    #$table->attach($check_label,  0, 1, $rows, $rows + 1, 'fill', [], 0, 0);
    #$table->attach($check_box,    1, 2, $rows, $rows + 1, 'fill', [], 0, 0);
    #$tooltip_group->set_tip(
    #    $check_label,
    #    'Uncheck to delete the current index',
    #    undef,
    #);
    
    #  add the incr/decr buttons
    my $rows = $table->get('n-rows');
    $rows++;
    $table->set('n-rows' => $rows);
    my $incr_button = Gtk2::Button->new_with_label('Increment all');
    $table->attach($incr_button,  0, 1, $rows, $rows + 1, 'shrink', [], 0, 0);
    $tooltip_group->set_tip(
        $incr_button,
        'Increase all the axes by their default increments',
        undef,
    );
    my $decr_button = Gtk2::Button->new_with_label('Decrement all');
    $table->attach($decr_button,  1, 2, $rows, $rows + 1, 'shrink', [], 0, 0);
    $tooltip_group->set_tip(
        $decr_button,
        'Decrease all the axes by their default increments',
        undef,
    );

    my $i = 0;
    my @resolution_widgets;
    
    BY_AXIS:
    foreach my $cellsize (@cellsize_array) {
        
        my $is_text_axis = 0;

        my $init_value = $used_index ? $resolutions[$i] : $cellsize * 2;

        my $min_val = $cellsize;
        my $max_val = 10E10;
        my $step_incr = $cellsize;

        if ($cellsize == 0) {   #  allow some change for points
            $init_value = ($coord_bounds{MAX}[$i] - $coord_bounds{MIN}[$i]) / 20;
            $min_val    = 0;      #  should allow non-zero somehow
            $step_incr  = $init_value;
        }
        elsif ($cellsize < 0) { #  allow no change for text
            $init_value   = 0;
            $min_val      = 0;
            $max_val      = 0;
            $is_text_axis = 1;
            $step_incr    = 0;
        }

        my $page_incr = $cellsize * 10;

        my $label_text = "Axis $i";

        $rows = $table->get('n-rows');
        $rows++;
        $table->set('n-rows' => $rows);

        # Make the label
        my $label = Gtk2::Label->new;
        $label->set_text( $label_text );

        #  make the widget
        my $adj = Gtk2::Adjustment->new(
            $init_value,
            $min_val,
            $max_val,
            $step_incr,
            $page_incr,
            0,
        );
        my $widget = Gtk2::SpinButton->new(
            $adj,
            $init_value,
            6,
        );

        $table->attach($label,  0, 1, $rows, $rows + 1, 'shrink', [], 0, 0);
        $table->attach($widget, 1, 2, $rows, $rows + 1, 'shrink', [], 0, 0);

        push @resolution_widgets, $widget;

        # Add a tooltip
        my $tip_text = $is_text_axis
            ? "Text axes must be set to zero"
            : "Set the index size for axis $i\n"
              . "Middle click the arrows to change by $page_incr.";
        $tooltip_group->set_tip($widget, $tip_text, undef);
        $tooltip_group->set_tip($label,  $tip_text, undef);

        if ($is_text_axis) {
            $widget->set_sensitive (0); 
        }

        $label->show;
        $widget->show;

        $i++;
    }

    $incr_button->signal_connect (
        clicked => \&on_index_dlg_change_all,
        [1, undef, \@resolution_widgets],
    );
    $decr_button->signal_connect (
        clicked => \&on_index_dlg_change_all,
        [0, undef, \@resolution_widgets],
    );

    # Show the dialog
    $dlg->show_all();
    
    #$window->show_all;

    #  a kludge until we build the window and table ourselves
    $dlgxml->get_widget('ImportParametersLabel')->hide;
    $dlgxml->get_widget('lblDlgImportParametersNext')->set_label ('OK');

    RUN_DIALOG:
    my $response = $dlg->run();

    if ($response ne 'ok') {
        $dlg->destroy;
        return;
    }
    
    #my $use_index = $check_box->get_active;
    #if (! $use_index) {
    #    $self->report_error ('Spatial index deleted', q{});
    #    $bd->delete_spatial_index;
    #}
    #else {
        #  need to harvest all the widget values
        my @widget_values;
        foreach my $widget (@resolution_widgets) {
            push @widget_values, $widget->get_value;
        }

        my $join_text = q{, };
        my $orig_res_text = join ($join_text, @resolutions);
        my $new_res_text  = join ($join_text, @widget_values);

        my $feedback = q{};
        if ($new_res_text eq $orig_res_text) {
            $feedback = 
                "Resolutions unchanged, spatial index not rebuilt\n"
                . 'Delete the index and rebuild if you have imported '
                . 'new data since it was last built';
        }
        else {
            $bd->build_spatial_index (resolutions => [@widget_values]);
            $feedback = "Spatial index built using resolutions:\n"
                        . $new_res_text;
        }
        
        print "[GUI] $feedback\n";
        Biodiverse::GUI::YesNoCancel->run({
                text  => $feedback,
                title => 'Feedback',
                hide_yes    => 0,
                hide_no     => 1,
                hide_cancel => 1,
                yes_is_ok   => 1,
        });
    #}
    
    $dlg->destroy;

    return;    
}

sub on_index_dlg_change_all {
    my $button  = shift;
    my $args_array = shift;

    my $incr        = $args_array->[0];
    #my $check_box   = $args_array->[1];
    my $widgets     = $args_array->[2];

    #  activate the checkbox    
    #$check_box->set_active (1);
    
    #  and update the spinboxes
    foreach my $widget (@$widgets) {
        my $adj = $widget->get_adjustment;
        my $increment = $adj->step_increment;
        my $value = $incr
            ? $widget->get_value + $increment
            : $widget->get_value - $increment;
        $widget->set_value ($value);
    }
    
    return;
}

sub show_index_dialog_orig {
    my $self = shift;

    my $dlgxml = Gtk2::GladeXML->new($self->get_glade_file, 'dlgIndex');
    my $dlg = $dlgxml->get_widget('dlgIndex');
    $dlg->set_transient_for( $self->get_widget('wndMain') );
    $dlg->set_modal(1);
        
    # set existing settings
    my $base_ref = $self->get_project->get_selected_base_data();
    return if not defined $base_ref;
    
    my $cell_sizes = $base_ref->get_cell_sizes;

    my $used_index = $base_ref->get_param('SPATIAL_INDEX');
    $dlgxml->get_widget('chkIndex')->set_active ($used_index);
    my $spin = $dlgxml->get_widget ('spinContains');
    #my $step, $page) = $spin->get_increments;
    if ($used_index) {
        my $resolutions = $used_index->get_param('RESOLUTIONS');
        $spin->set_value ($resolutions->[0]);
        $spin->set_increments ($resolutions->[0], $resolutions->[0]*10);
    }
    else {
        #  default is zero for non-numeric axes
        my $cell1 = $cell_sizes->[0];
        $spin->set_value ($cell1 >= 0 ? $cell1 : 0);
        $spin->set_increments( abs($cell1), abs($cell1*10));
    }

    my $response = $dlg->run();
    if ($response eq 'ok') {
        
        my $use_index = $dlgxml->get_widget('chkIndex')->get_active();
        if ($use_index) {

            #my $resolution = $dlgxml->get_widget('spinContains')->get_value_as_int;
            my $resolution = $dlgxml->get_widget('spinContains')->get_value;
            
            #  repeat the resolution for all cell sizes until the widget has more spinners
            my @resolutions = ($resolution) x scalar @$cell_sizes;
            
            #  override for any text fields
            foreach my $i (0 .. $#$cell_sizes) {
                $resolutions[$i] = 0 if $cell_sizes->[$i] < 0;
            }
            
            $base_ref->build_spatial_index (resolutions => [@resolutions]);
        }
        else {
            print "[GUI] Index deleted\n";
            $base_ref->delete_spatial_index;
        }
        
    }

    $dlg->destroy();
    
    return;
}

##########################################################
# Misc
##########################################################

sub do_run_exclusions {
    my $self = shift;

    my $basedata = $self->{project}->get_selected_base_data();

    return if not defined $basedata;

    my @array = $basedata->get_output_refs;
    if (scalar @array) {
        my $text = "Cannot run exclusions on a BaseData object with existing outputs\n"
                 . "Either delete the outputs or use 'File->Duplicate without outputs'"
                 . " to create a new object\n";
        $self->report_error ($text);
        return;
    }

    my $exclusions_hash = $basedata->get_param('EXCLUSION_HASH');
    if (Biodiverse::GUI::Exclusions::show_dialog($exclusions_hash)) {
        #print Data::Dumper::Dumper($exclusions_hash);
        my $tally = eval {$basedata->run_exclusions()};
        my $feedback = $tally->{feedback};
        if ($EVAL_ERROR) {
            $self->report_error ($EVAL_ERROR);
            return;
        }
        my $dlg = Gtk2::Dialog->new(
            'Exclusion results',
            $self->get_widget('wndMain'),
            'modal',
            'gtk-ok' => 'ok',
        );
        my $text_widget = Gtk2::Label->new();
        $text_widget->set_alignment (0, 1);
        $text_widget->set_text ($feedback);
        $text_widget->set_selectable (1);
        $dlg->vbox->pack_start ($text_widget, 0, 0, 0);

        $dlg->show_all;
        $dlg->run;
        $dlg->destroy;

        $self->set_dirty();
    }

    return;
}


sub show_save_dialog {
    my $self = shift;
    my $title = shift;
    my @suffixes = @_;

    my $dlg = Gtk2::FileChooserDialog->new($title, undef, "save", "gtk-cancel", "cancel", "gtk-ok", 'ok');

    foreach my $suffix (@suffixes) {
        my $filter = Gtk2::FileFilter->new();
        $filter->add_pattern("*.$suffix");
        $filter->set_name("$suffix files");
        $dlg->add_filter($filter);
    }
    
    $dlg->set_modal(1);
    eval { $dlg->set_do_overwrite_confirmation(1); }; # GTK < 2.8 doesn't have this

    my $filename;
    if ($dlg->run() eq 'ok') {
        $filename = $dlg->get_filename();
    }
    $dlg->destroy();
    
    return $filename;
}

#FIXME merge with above
sub show_open_dialog {
    my $self = shift;
    my %args = @_;
    
    my $title       = $args{title};
    my $suffix      = $args{suffix};
    my $initial_dir = $args{initial_dir};

    my $dlg = Gtk2::FileChooserDialog->new(
        $title,
        undef,
        'open',
        'gtk-cancel' => 'cancel',
        'gtk-ok'     => 'ok',
    );
    if (!defined $initial_dir) {
        use Cwd;
        $initial_dir = getcwd();
    }
    $dlg->set_current_folder($initial_dir);

    my $filter = Gtk2::FileFilter->new();

    $filter->add_pattern("*.$suffix");
    $filter->set_name(".$suffix files");
    $dlg->add_filter($filter);
    $dlg->set_modal(1);

    my $filename;
    if ($dlg->run() eq 'ok') {
        $filename = $dlg->get_filename();
    }
    $dlg->destroy();
    
    return $filename;
}

sub do_set_working_directory {
    my $self = shift;
    my $title = shift || "Select working directory";
    my $initial_dir = shift;
    
    my $dlg = Gtk2::FileChooserDialog->new($title, undef, "open", "gtk-cancel", "cancel", "gtk-ok", 'ok');
    $dlg->set_action ('select-folder');
    $dlg->set_current_folder($initial_dir) if $initial_dir;
    
    my $dir;
    if ($dlg->run() eq 'ok') {
        $dir = $dlg->get_current_folder ();
        print "[GUIMANAGER] Setting working directory to be $dir\n";
        chdir ($dir);
    }
    $dlg->destroy;
    
    return $dir;
}

#  report an error using a dialog window
#  turning into general feedback - needs modification
sub report_error {
    my $self  = shift;
    my $error = shift;  #  allows for error classes
    my $title = shift;
    my $use_all_text = shift;

    if (! defined $title) {
        $title = 'PROCESSING ERRORS';
    }
    
    my $e = $error;  # keeps a copy of the object

    #  messy - should check for $error->isa('Exception::Class')
    if (blessed $error and (blessed $error) !~ /ProgressDialog::Cancel/) {
        warn $error->error, "\n", $error->trace->as_string, "\n";
    }
    elsif ($title =~ /error/i) {
        warn $error;
    }
    else {
        print $error;  #  might not be an error
    }

    #  and now strip out message from the error class
    if (blessed $error) {
        $error = $error->message . "\n";
        if ($e->{Error}) {
            $error .= $e->{Error};  #  nasty hack at error internals
        }
    }
    my @error_array = $use_all_text
        ? $error
        : split ("\n", $error, 2);

    if (@error_array > 1) {
        my $text_wrapper = Text::Wrapper->new(columns => 80);
        $error_array[1] = $text_wrapper->wrap($error_array[1]);
    }

    my $show_details_value = -10;

    my $dlg = Gtk2::Dialog->new(
        $title,
        $self->get_widget('wndMain'),
        'modal',
        'show details' => $show_details_value,
        'gtk-ok' => 'ok',
    );
    my $text_widget = Gtk2::Label->new();
    my $extra_text_widget = Gtk2::Label->new();

    foreach my $w ($text_widget, $extra_text_widget) {
        #$w->set_use_markup(1);
        $w->set_line_wrap (1);
        $w->set_width_chars(90);
        $w->set_alignment (0, 0);
        $w->set_selectable (1);
        $w->set_ellipsize('PANGO_ELLIPSIZE_END');
    }

    $text_widget->set_text ($error_array[0]);
    $extra_text_widget->set_text ($error_array[1] // 'There are no additional details');

    my $check_button = Gtk2::ToggleButton->new_with_label('show details');
    $check_button->signal_connect_swapped (
        clicked => \&on_report_error_show_hide,
        $extra_text_widget,
    );
    $check_button->set_active (0);

    my $details_box = Gtk2::VBox->new(1, 6);
    $details_box->set_homogeneous(0);
    $details_box->pack_start(Gtk2::HSeparator->new(), 0, 0, 0);
    #$details_box->pack_start($check_button, 0, 0, 0);
    $details_box->pack_start($extra_text_widget, 0, 0, 0);

    $dlg->vbox->pack_start ($text_widget, 0, 0, 0);
    $dlg->vbox->pack_start ($details_box, 0, 0, 0);


    $dlg->show_all;
    my $details_visible = 0;
    #$extra_text_widget->hide;
    $details_box->hide;
    $dlg->resize(1,1);

    while (1) {
        my $response = $dlg->run;
        last if $response ne 'apply'; #  not sure whey we're being fed 'apply' as the value
        if ($details_visible) {  #  replace with set_visible when Gtk used is 2.18+
            $details_box->hide;
            $dlg->resize(1,1);
        }
        else {
            $details_box->show;
        }
        $details_visible = ! $details_visible;
    }

    $dlg->destroy;

    return;
}


#  warn if the user tries to run a randomisation and the basedata already has outputs
sub warn_outputs_exist_if_randomisation_run {
    my $self = shift;
    my $bd_name = shift;

    warn "[GUI] Warning:  Creating cluster or spatial output when Basedata has existing randomisation outputs\n";

    my $header  = "BaseData object $bd_name has one or more existing randomisations.\n";

    my $warning = "Any new analyses will not be synchronised with those randomisations.\n"
                . 'Continue?'
                ;

    my $response = Biodiverse::GUI::YesNoCancel->run (
        {text        => $warning,
         header      => $header,
         title       => 'WARNING',
         hide_cancel => 1,
         }
    );

    return $response;
}

1;

__END__

=head1 NAME

Biodiverse::GUI::GUIManager

=head1 DESCRIPTION

Module containing methods to control the Biodiverse GUI. 

=head1 AUTHOR

Eugene Lubarsky and Shawn Laffan

=head1 LICENSE

LGPL

=head1 SEE ALSO

See http://www.purl.org/biodiverse for more details.

=cut
