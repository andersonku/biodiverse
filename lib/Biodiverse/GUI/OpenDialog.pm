package Biodiverse::GUI::OpenDialog;

#
# A FileChooserWidget but with a name field
#

use strict;
use warnings;
use File::Basename;
use Gtk2;
use Gtk2::GladeXML;

use Cwd;

our $VERSION = '0.99_006';

use Biodiverse::GUI::GUIManager;

# Show the dialog. Params:
#   title
#   suffixes to use in the filter (OPTIONAL)
#     - can be array refs to let users choose a few types at once,
#       eg: ["csv", "txt"], "csv", "txt"
sub Run {
    my $title = shift;
    my @suffixes = @_;

    my $gui = Biodiverse::GUI::GUIManager->instance;

    # Load the widgets from Glade's XML
    my $dlgxml = Gtk2::GladeXML->new($gui->get_glade_file, 'dlgOpenWithName');
    my $dlg = $dlgxml->get_widget('dlgOpenWithName');
    $dlg->set_transient_for( $gui->get_widget('wndMain') );
    $dlg->set_title($title);

    # Connect file selected event - to automatically update name based on filename
    my $chooser = $dlgxml->get_widget('filechooser');
    $chooser->signal_connect('selection-changed' => \&on_file_selection, $dlgxml);
    $chooser->set_current_folder_uri(getcwd());
    $chooser->set_action('GTK_FILE_CHOOSER_ACTION_OPEN');

    # Add filters
    foreach my $suffix (@suffixes) {

        my $filter = Gtk2::FileFilter->new();
        if ((ref $suffix) =~ /ARRAY/) {
            foreach my $suff (@$suffix) {
                $filter->add_pattern("*.$suff");
            }
            $filter->set_name(join (' and ', @$suffix) . ' files');
        }
        else {
            $filter->add_pattern("*.$suffix");
            $filter->set_name("$suffix files");
        }

        $chooser->add_filter($filter);
    }

    # Show the dialog
    $dlg->set_modal(1);
    my $response = $dlg->run();

    my ($name, $filename);
    if ($response eq "ok") {
        # Save settings
        $name = $dlgxml->get_widget('txtName')->get_text();
        $filename = $chooser->get_filename();
    }

    $dlg->destroy();
    return ($name, $filename);
}


# Automatically update name based on filename
sub on_file_selection {
    my $chooser = shift;
    my $dlgxml = shift;

    my $filename = $chooser->get_filename();
    if ($filename && -f $filename) {
    
        my($name, $dir, $suffix) = fileparse($filename, qr/\.[^.]*/);
        
        $dlgxml->get_widget('txtName')->set_text($name);
    }
}

1;

