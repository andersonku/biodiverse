package Biodiverse::GUI::Overlays;

use strict;
use warnings;
use Gtk2;
use Gtk2::GladeXML;
use Data::Dumper;

our $VERSION = '0.99_006';

use Biodiverse::GUI::GUIManager;
use Biodiverse::GUI::Project;

my $default_colour       = Gtk2::Gdk::Color->parse('#001169');
my $last_selected_colour = $default_colour;

sub show_dialog {
    my $grid = shift;

    # Create dialog
    my $gui = Biodiverse::GUI::GUIManager->instance;
    my $dlgxml = Gtk2::GladeXML->new($gui->get_glade_file, 'wndOverlays');
    my $dlg = $dlgxml->get_widget('wndOverlays');
    my $colour_button = $dlgxml->get_widget('colorbutton_overlays');
    $dlg->set_transient_for( $gui->get_widget('wndMain') );
    
    $colour_button->set_color($last_selected_colour);

    my $project = $gui->get_project;
    my $model = make_overlay_model($project);
    my $list = init_overlay_list($dlgxml, $model);

    # Connect buttons
    $dlgxml->get_widget('btnAdd')->signal_connect(
        clicked => \&on_add,
        [$list, $project],
    );
    $dlgxml->get_widget('btnDelete')->signal_connect(
        clicked => \&on_delete,
        [$list, $project],
    );
    $dlgxml->get_widget('btnClear')->signal_connect(
        clicked => \&on_clear,
        [$list, $project, $grid, $dlg],
    );
    $dlgxml->get_widget('btnSet')->signal_connect(
        clicked => \&on_set,
        [$list, $project, $grid, $dlg, $colour_button],
    );
    $dlgxml->get_widget('btnOverlayCancel')->signal_connect(
        clicked => \&on_cancel,
        $dlg,
    );
    $dlgxml->get_widget('btn_overlay_set_default_colour')->signal_connect(
        clicked => \&on_set_default_colour,
        $colour_button,
    );
    

    $dlg->set_modal(1);
    $dlg->show_all();
    
    return;
}

sub init_overlay_list {
    my $dlgxml = shift;
    my $model = shift;
    my $tree = $dlgxml->get_widget('treeOverlays');
    
    my $col_name = Gtk2::TreeViewColumn->new();
    my $name_renderer = Gtk2::CellRendererText->new();
    $col_name->set_title('Filename');
    $col_name->pack_start($name_renderer, 1);
    $col_name->add_attribute($name_renderer,  text => 0);
    $tree->insert_column($col_name, -1);
    
    #  fiddling around with colour selection
    #my $colColour = Gtk2::TreeViewColumn->new();
    #my $colour_button = Gtk2::CellRendererPixbuf->new();
    #$colColour->set_title('Colour');
    #$colColour->pack_start($colour_button, 1);
    #$colColour->add_attribute($colour_button, text => 0);
    #$tree->insert_column($colColour, -1);

    $tree->set_headers_visible(0);
    $tree->set_model($model);
    
    return $tree;
}

# Make the object tree that appears on the left
sub make_overlay_model {
    my $model = Gtk2::ListStore->new(
        'Glib::String',
        #'Glib::Boolean',  #  fiddling around with colour selection
    );
    my $project = shift;

    my $overlays = $project->get_overlay_list();

    foreach my $name (@{$overlays}) {
        my $iter = $model->append;
        $model->set($iter, 0, $name);
    }


    return $model;
}


# Get what was selected..
sub get_selection {
    my $tree = shift;

    my $selection = $tree->get_selection();
    my $model = $tree->get_model();
    my $path = $selection->get_selected_rows();
    return if not $path;
    
    my $iter = $model->get_iter($path);
    my $name = $model->get($iter, 0);
    
    return wantarray ? ($name, $iter) : $name;
}


sub on_set_default_colour {
    my $button = shift;
    my $colour_button = shift;
    
    $colour_button->set_color ($default_colour);
    
    return;
}

sub on_add {
    my $button = shift;
    my $args = shift;
    my ($list, $project) = @$args;

    my $open = Gtk2::FileChooserDialog->new(
        'Add shapefile',
        undef,
        'open',
        'gtk-cancel',
        'cancel',
        'gtk-ok',
        'ok'
    );
    my $filter = Gtk2::FileFilter->new();

    $filter->add_pattern('*.shp');
    $filter->set_name('.shp files');
    $open->add_filter($filter);
    $open->set_modal(1);

    my $filename;
    if ($open->run() eq 'ok') {
        
        $filename = $open->get_filename();

        my $iter = $list->get_model->append;
        $list->get_model->set($iter, 0, $filename);
        my $sel = $list->get_selection;
        $sel->select_iter($iter);
        
        $project->add_overlay($filename);
    }
    $open->destroy();
    
    return;
}

sub on_delete {
    my $button = shift;
    my $args = shift;
    my ($list, $project) = @$args;

    my ($filename, $iter) = get_selection($list);
    return if not $filename;
    $project->delete_overlay($filename);
    $list->get_model->remove($iter);
    
    return;
}


sub on_clear {
    my $button = shift;
    my $args = shift;
    my ($list, $project, $grid, $dlg) = @$args;

    $grid->set_overlay(undef);
    $dlg->destroy();
    
    return;
}

sub on_set {
    my $button = shift;
    my $args = shift;
    my ($list, $project, $grid, $dlg, $colour_button) = @$args;

    my $filename = get_selection($list);
    
    my $colour = $colour_button->get_color;
    
    $dlg->destroy;
    
    if (not $filename) {    
        return;
    }

    print "[Overlay] Setting overlay to $filename\n";
    $grid->set_overlay( $project->get_overlay($filename), $colour );
    #$dlg->destroy();
    
    $last_selected_colour = $colour;
    
    return;
}

sub on_cancel {
    my $button = shift;
    my $dlg    = shift;

    $dlg->destroy;
    
    return;
}


1;

