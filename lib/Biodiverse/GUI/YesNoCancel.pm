package Biodiverse::GUI::YesNoCancel;

use strict;
use warnings;
use Gtk2;

use English ( -no_match_vars );

our $VERSION = '0.99_005';

use Biodiverse::GUI::GUIManager;

=head1
Implements a yes/no/cancel dialog

To use call in these ways

   Biodiverse::GUI::YesNoCancel->run({text => 'blah'}) or 
   Biodiverse::GUI::YesNoCancel->run({header => 'titular', text => blah}) or
   Biodiverse::GUI::YesNoCancel->run({header => 'titular', text => blah, hide_yes => 1, hide_no => 1}) 
   Biodiverse::GUI::YesNoCancel->run({title => 'window_title', hide_cancel => 1})

You can hide all the buttons if you really want to.

it returns 'yes', 'no', or 'cancel'

=cut

##########################################################
# Globals
##########################################################

use constant DLG_NAME => 'dlgYesNoCancel';

sub run {
    my $cls = shift; #ignored
    my $args = shift || {};
    
    
    my $text = q{};
    if (defined $args->{header}) {
        #print "mode1\n";
        $text .= '<b>'
                . Glib::Markup::escape_text ($args->{header})
                . '</b>';
    }
    if (defined $args->{text}) {
        $text .= Glib::Markup::escape_text(
            $args->{text}
        );
    }

    my $gui = Biodiverse::GUI::GUIManager->instance;
    my $dlgxml = Gtk2::GladeXML->new ($gui->get_glade_file, DLG_NAME);
    my $dlg = $dlgxml->get_widget(DLG_NAME);

    # Put it on top of main window
    $dlg->set_transient_for($gui->get_widget('wndMain'));

    # set the text
    my $label = $dlgxml->get_widget('lblText');
    
    #  try with markup - need to escape all the bits
    eval { $label->set_markup($text) };
    if ($EVAL_ERROR) {  #  and then try without markup
        $label->set_text($text);
    }
    
    if ($args->{hide_yes}) {
        $dlgxml->get_widget('btnYes')->hide;
    }
    if ($args->{hide_no}) {
        $dlgxml->get_widget('btnNo')->hide;
    }
    if ($args->{hide_cancel}) {
        $dlgxml->get_widget('btnCancel')->hide;
    }
    #  not yet... should add an OK button and hide by default
    if ($args->{yes_is_ok}) {
        $dlgxml->get_widget('btnYes')->set_label ('OK');
    }
    if ($args->{title}) {
        $dlg->set_title ($args->{title});
    }

    # Show the dialog
    my $response = $dlg->run();
    $dlg->destroy();

    $response = 'cancel' if $response eq 'delete-event';
    if (not ($response eq 'yes' or $response eq 'no' or $response eq 'cancel')) {
        die "not yes/no/cancel: $response";
    }

    #print "[YesNoCancel] - returning $response\n";
    return $response;
}



1;
