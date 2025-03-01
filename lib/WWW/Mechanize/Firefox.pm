package WWW::Mechanize::Firefox;
use 5.006; #weaken
use strict;
use Time::HiRes; # hires sleep()

use URI;
use Cwd;
use File::Basename qw(dirname);
use HTTP::Response;
use HTML::Selector::XPath 'selector_to_xpath';
use MIME::Base64;
use WWW::Mechanize::Link;
use Firefox::Application;
use MozRepl::RemoteObject ();
use HTTP::Cookies::MozRepl;
use Scalar::Util qw'blessed weaken';
use Encode qw(encode decode);
use Carp qw(carp croak );

use vars qw'$VERSION %link_spec';
$VERSION = '0.55';

=head1 NAME

WWW::Mechanize::Firefox - use Firefox as if it were WWW::Mechanize

=head1 SYNOPSIS

  use WWW::Mechanize::Firefox;
  my $mech = WWW::Mechanize::Firefox->new();
  $mech->get('http://google.com');

  $mech->eval_in_page('alert("Hello Firefox")');
  my $png = $mech->content_as_png();

This module will let you automate Firefox through the
Mozrepl plugin. You need to have installed
that plugin in your Firefox.

For more examples see L<WWW::Mechanize::Firefox::Examples>.

=head1 METHODS

=head2 C<< $mech->new( %args ) >>

  use WWW::Mechanize::Firefox;
  my $mech = WWW::Mechanize::Firefox->new();

Creates a new instance and connects it to Firefox.

Note that Firefox must have the C<mozrepl>
extension installed and enabled.

The following options are recognized:

=over 4

=item * 

C<tab> - regex for the title of the tab to reuse. If no matching tab is
found, the constructor dies.

If you pass in the string C<current>, the currently
active tab will be used instead.

=item *

C<create> - will create a new tab if no existing tab matching
the criteria given in C<tab> can be found.

=item *

C<activate> - make the tab the active tab

=item * 

C<launch> - name of the program to launch if we can't connect to it on
the first try.

=item *

C<frames> - an array reference of ids of subframes to include when 
searching for elements on a page.

If you want to always search through all frames, just pass C<1>. This
is the default.

To prevent searching through frames, pass

          frames => 0

To whitelist frames to be searched, pass the list
of frame selectors:

          frames => ['#content_frame']

=item * 

C<autodie> - whether web failures converted are fatal Perl errors. See
the C<autodie> accessor. True by default to make error checking easier.

To make errors non-fatal, pass

    autodie => 0

in the constructor.

=item * 

C<log> - array reference to log levels, passed through to L<MozRepl::RemoteObject>

=item *

C<bufsize> - L<Net::Telnet> buffer size, if the default of 1MB is not enough

=item * 

C<events> - the set of default Javascript events to listen for while
waiting for a reply

The default set is

  DOMFrameContentLoaded
  DOMContentLoaded
  pageshow
  error
  abort
  stop

=item * 

C<app> - a premade L<Firefox::Application>

=item * 

C<repl> - a premade L<MozRepl::RemoteObject> instance or a connection string
suitable for initializing one

=item *

C<use_queue> - whether to use the command queueing of L<MozRepl::RemoteObject>.
Default is 1.

=item *

C<js_JSON> - whether to use native JSON encoder of Firefox

    js_JSON => 'native', # force using the native JSON encoder

The default is to autodetect whether a native JSON encoder is available and
whether the transport is UTF-8 safe.

=item * 

C<pre_events> - the events that are sent to an input field before its
value is changed. By default this is C<[focus]>.

=item * 

C<post_events> - the events that are sent to an input field after its
value is changed. By default this is C<[blur, change]>.

=back

=cut

sub new {
    my ($class, %args) = @_;
    
    if (! ref $args{ app }) {
        my @passthrough = qw(launch repl bufsize log use_queue js_JSON);
        my %options = map { exists $args{ $_ } ? ($_ => delete $args{ $_ }) : () } 
                      @passthrough;
        $args{ app } = Firefox::Application->new(
            %options
        );
    };
        
    if (my $tabname = delete $args{ tab }) {
        if (! ref $tabname) {
            if ($tabname eq 'current') {
                $args{ tab } = $args{ app }->selectedTab();
            } else {
                croak "Don't know what to do with tab '$tabname'. Did you mean qr{$tabname}?";
            };
        } else {
            ($args{ tab }) = grep { $_->{title} =~ /$tabname/ }
                $args{ app }->openTabs();
            if (! $args{ tab }) {
                if (! delete $args{ create }) {
                    croak "Couldn't find a tab matching /$tabname/";
                } else {
                    # fall through into tab creation
                };
            } else {
                $args{ tab } = $args{ tab }->{tab};
            };
        };
    };
    if (! $args{ tab }) {
        my @autoclose = exists $args{ autoclose } ? (autoclose => $args{ autoclose }) : ();
        $args{ tab } = $args{ app }->addTab( @autoclose );
        my $body = $args{ tab }->__dive(qw[ linkedBrowser contentWindow document body ]);
        $body->{innerHTML} = __PACKAGE__;
    };

    if (delete $args{ autoclose }) {
        $args{ app }->autoclose_tab($args{ tab });
    };
    if (! exists $args{ autodie }) { $args{ autodie } = 1 };
    
    $args{ events } ||= [qw[DOMFrameContentLoaded DOMContentLoaded pageshow error abort stop]];
    $args{ on_event } ||= undef;
    $args{ pre_value } ||= ['focus'];
    $args{ post_value } ||= ['change','blur'];
    $args{ frames } ||= 1; # we default to searching frames

    die "No tab found"
        unless $args{tab};
        
    if (delete $args{ activate }) {
        $args{ app }->activateTab( $args{ tab });
    };
    
    $args{ response } ||= undef;
    $args{ current_form } ||= undef;
        
    bless \%args, $class;
};

sub DESTROY {
    my ($self) = @_;
    local $@;
    if (my $app = delete $self->{ app }) {
        %$self = (); # wipe out all references we keep
        # but keep $app alive until we can dispose of it
        # as the last thing, now:
        $app = undef;
    };
    #warn "FF cleaned up";
}

=head1 JAVASCRIPT METHODS

=head2 C<< $mech->allow( %options ) >>

Enables or disables browser features for the current tab.
The following options are recognized:

=over 4

=item * 

C<plugins> 	 - Whether to allow plugin execution.

=item * 

C<javascript> 	 - Whether to allow Javascript execution.

=item * 

C<metaredirects> - Attribute stating if refresh based redirects can be allowed.

=item * 

C<frames>, C<subframes> 	 - Attribute stating if it should allow subframes (framesets/iframes) or not.

=item * 

C<images> 	 - Attribute stating whether or not images should be loaded.

=back

Options not listed remain unchanged.

=head3 Disable Javascript

  $mech->allow( javascript => 0 );

=cut

use vars '%known_options';
%known_options = (
    'javascript'    => 'allowJavascript',
    'plugins'       => 'allowPlugins',
    'metaredirects' => 'allowMetaRedirects',
    'subframes'     => 'allowSubframes',
    'frames'        => 'allowSubframes',
    'images'        => 'allowImages',
);

sub allow  {
    my ($self,%options) = @_;
    my $shell = $self->docshell;
    for my $opt (sort keys %options) {
        if (my $opt_js = $known_options{ $opt }) {
            $shell->{$opt_js} = $options{ $opt };
        } else {
            carp "Unknown option '$opt_js' (ignored)";
        };
    };
};

=head2 C<< $mech->js_errors() >>

  print $_->{message}
      for $mech->js_errors();

An interface to the Javascript Error Console

Returns the list of errors in the JEC

Maybe this should be called C<js_messages> or
C<js_console_messages> instead.

=cut

sub js_console {
    my ($self) = @_;
    my $getConsoleService = $self->repl->declare(<<'JS');
    function() {
        return  Components.classes["@mozilla.org/consoleservice;1"]
                .getService(Components.interfaces.nsIConsoleService);
    }
JS
    $getConsoleService->()
}

sub js_errors {
    my ($self,$page) = @_;
    my $console = $self->js_console;
    my $getErrorMessages = $self->repl->declare(<<'JS', 'list');
    function (consoleService) {
        var out = {};
        consoleService.getMessageArray(out, {});
        return out.value || []
    };
JS
    $getErrorMessages->($console);
}

=head2 C<< $mech->clear_js_errors >>

    $mech->clear_js_errors();

Clears all Javascript messages from the console

=cut

sub clear_js_errors {
    my ($self,$page) = @_;
    $self->js_console->reset;

};

=head2 C<< $mech->eval_in_page( $str [, $env [, $document]] ) >>

=head2 C<< $mech->eval( $str [, $env [, $document]] ) >>

  my ($value, $type) = $mech->eval( '2+2' );

Evaluates the given Javascript fragment in the
context of the web page.
Returns a pair of value and Javascript type.

This allows access to variables and functions declared
"globally" on the web page.

The returned result needs to be treated with 
extreme care because
it might lead to Javascript execution in the context of
your application instead of the context of the webpage.
This should be evident for functions and complex data
structures like objects. When working with results from
untrusted sources, you can only safely use simple
types like C<string>.

If you want to modify the environment the code is run under,
pass in a hash reference as the second parameter. All keys
will be inserted into the C<this> object as well as
C<this.window>. Also, complex data structures are only
supported if they contain no objects.
If you need finer control, you'll have to
write the Javascript yourself.

This method is special to WWW::Mechanize::Firefox.

Also, using this method opens a potential B<security risk> as
the returned values can be objects and using these objects
can execute malicious code in the context of the Firefox application.

=cut

sub eval_in_page {
    my ($self,$str,$env,$doc,$window) = @_;
    $env ||= {};
    my $js_env = {};
    $doc ||= $self->document;
    
    # do a manual transfer of keys, to circumvent our stupid
    # transformation routine:
    if (keys %$env) {
        $js_env = $self->repl->declare(<<'JS')->();
            function () { return new Object }
JS
        for my $k (keys %$env) {
            $js_env->{$k} = $env->{$k};
        };
    };
    
    my $eval_in_sandbox = $self->repl->declare(<<'JS', 'list');
    function (w,d,str,env) {
        var unsafeWin = w.wrappedJSObject;
        var safeWin = XPCNativeWrapper(unsafeWin);
        var sandbox = Components.utils.Sandbox(safeWin);
        sandbox.window = safeWin;
        sandbox.document = d;
        // Transfer the environment
        for (var e in env) {
            sandbox[e] = env[e]
            sandbox.window[e] = env[e]
        }
        sandbox.__proto__ = unsafeWin;
        var res = Components.utils.evalInSandbox(str, sandbox);
        return [res,typeof(res)];
    };
JS
    $window ||= $self->tab->{linkedBrowser}->{contentWindow};
    # Report errors from scope of caller
    local @MozRepl::RemoteObject::Instance::CARP_NOT = (@MozRepl::RemoteObject::Instance::CARP_NOT,__PACKAGE__);
    #warn Dumper @MozRepl::RemoteObject::CARP_NOT;
    return $eval_in_sandbox->($window,$doc,$str,$js_env);
};
*eval = \&eval_in_page;

=head2 C<< $mech->unsafe_page_property_access( ELEMENT ) >>

Allows you unsafe access to properties of the current page. Using
such properties is an incredibly bad idea.

This is why the function C<die>s. If you really want to use
this function, edit the source code.

=cut

sub unsafe_page_property_access {
    my ($mech,$element) = @_;
    die;
    my $window = $mech->tab->{linkedBrowser}->{contentWindow};
    my $unsafe = $window->{wrappedJSObject};
    $unsafe->{$element}
};

=head1 UI METHODS

See also L<Firefox::Application> for how to add more than one tab
and how to manipulate windows and tabs.

=head2 C<< $mech->application() >>

    my $ff = $mech->application();

Returns the L<Firefox::Application> object for manipulating
more parts of the Firefox UI and application.

=cut

sub application { $_[0]->{app} };

sub autoclose_tab {
    my $self = shift;
    $self->application->autoclose_tab(@_);
};

=head2 C<< $mech->tab >>

Gets the object that represents the Firefox tab used by WWW::Mechanize::Firefox.

This method is special to WWW::Mechanize::Firefox.

=cut

sub tab { $_[0]->{tab} };

=head2 C<< $mech->autodie( [$state] ) >>

  $mech->autodie(0);

Accessor to get/set whether warnings become fatal.

=cut

sub autodie { $_[0]->{autodie} = $_[1] if @_ == 2; $_[0]->{autodie} }

=head2 C<< $mech->progress_listener( $source, %callbacks ) >>

    my $eventlistener = progress_listener(
        $browser,
        onLocationChange => \&onLocationChange,
    );

Sets up the callbacks for the C<< nsIWebProgressListener >> interface
to be the Perl subroutines you pass in.

Returns a handle. Once the handle gets released, all callbacks will
get stopped. Also, all Perl callbacks will get deregistered from the
Javascript bridge, so make sure not to use the same callback
in different progress listeners at the same time.

=cut

sub progress_listener {
    my ($mech,$source,%handlers) = @_;
    my $NOTIFY_STATE_DOCUMENT = $mech->repl->constant('Components.interfaces.nsIWebProgress.NOTIFY_STATE_DOCUMENT');
    my ($obj) = $mech->repl->expr('new Object');
    for my $key (keys %handlers) {
        $obj->{$key} = $handlers{$key};
    };
    #warn "Listener created";
    
    my $mk_nsIWebProgressListener = $mech->repl->declare(<<'JS');
    function (myListener,source) {
        myListener.source = source;
        var callbacks = ["onStateChange",
                       "onLocationChange",
                       "onProgressChange",
                       "onStatusChange",
                       "onSecurityChange",
        ];
        for (var h in callbacks) {
            var e = callbacks[h];
            if (! myListener[e]) {
                myListener[e] = function(){}
            };
        };
        myListener.QueryInterface = function(aIID) {
            if (aIID.equals(Components.interfaces.nsIWebProgressListener) ||
               aIID.equals(Components.interfaces.nsISupportsWeakReference) ||
               aIID.equals(Components.interfaces.nsISupports))
                return this;
            throw Components.results.NS_NOINTERFACE;
        };
        return myListener
    }
JS
    
    # Declare it here so we don't close over $lsn!
    my $release = sub {
        #warn "Listener removed";
        $_[0]->bridge->remove_callback(values %handlers);
    };
    my $lsn = $mk_nsIWebProgressListener->($obj,$source);
    $lsn->__release_action('self.source.removeProgressListener(self)');
    $lsn->__on_destroy(sub {
        # Clean up some memory leaks
        $release->(@_)
    });
    $source->addProgressListener($lsn,$NOTIFY_STATE_DOCUMENT);
    $lsn
};

=head2 C<< $mech->repl >>

  my ($value,$type) = $mech->repl->expr('2+2');

Gets the L<MozRepl::RemoteObject> instance that is used.

This method is special to WWW::Mechanize::Firefox.

=cut

sub repl { $_[0]->application->repl };

=head2 C<< $mech->events >>

  $mech->events( ['load'] );

Sets or gets the set of Javascript events that WWW::Mechanize::Firefox
will wait for after requesting a new page. Returns an array reference.

This method is special to WWW::Mechanize::Firefox.

=cut

sub events { $_[0]->{events} = $_[1] if (@_ > 1); $_[0]->{events} };

=head2 C<< $mech->on_event >>

  $mech->on_event(1); # prints every page load event

  # or give it a callback
  $mech->on_event(sub { warn "Page loaded with $ev->{name} event" });

Gets/sets the notification handler for the Javascript event
that finished a page load. Set it to C<1> to output via C<warn>,
or a code reference to call it with the event.

This method is special to WWW::Mechanize::Firefox.

=cut

sub on_event { $_[0]->{on_event} = $_[1] if (@_ > 1); $_[0]->{on_event} };

=head2 C<< $mech->cookies >>

  my $cookie_jar = $mech->cookies();

Returns a L<HTTP::Cookies> object that was initialized
from the live Firefox instance.

B<Note:> C<< ->set_cookie >> is not yet implemented,
as is saving the cookie jar.

=cut

sub cookies {
    return HTTP::Cookies::MozRepl->new(
        repl => $_[0]->repl
    )
}

=head2 C<< $mech->highlight_node( @nodes ) >>

    my @links = $mech->selector('a');
    $mech->highlight_node(@links);

Convenience method that marks all nodes in the arguments
with

  background: red;
  border: solid black 1px;
  display: block; /* if the element was display: none before */

This is convenient if you need visual verification that you've
got the right nodes.

There currently is no way to restore the nodes to their original
visual state except reloading the page.

=cut

sub highlight_node {
    my ($self,@nodes) = @_;
    for (@nodes) {
        my $style = $_->{style};
        $style->{display}    = 'block'
            if $style->{display} eq 'none';
        $style->{background} = 'red';
        $style->{border}     = 'solid black 1px;';
    };
};

=head1 NAVIGATION METHODS

=head2 C<< $mech->get( $url, %options ) >>

  $mech->get( $url, ':content_file' => $tempfile );

Retrieves the URL C<URL> into the tab.

It returns a faked L<HTTP::Response> object for interface compatibility
with L<WWW::Mechanize>.

Recognized options:

=over 4

=item *

C<< :content_file >> - filename to store the data in

=item *

C<< no_cache >> - if true, bypass the browser cache

=item *

C<< synchronize >> - wait until all elements have loaded

The default is to wait until all elements have loaded. You can switch
this off by passing

    synchronize => 0

for example if you want to manually poll for an element that appears fairly
early during the load of a complex page.

=back

=cut

sub get {
    my ($self,$url, %options) = @_;
    my $b = $self->tab->{linkedBrowser};
    $self->clear_current_form;
    
    my $flags = 0;
    if ($options{ no_cache }) {
        $flags = $self->repl->constant('nsIWebNavigation.LOAD_FLAGS_BYPASS_CACHE');
    };
    if (! exists $options{ synchronize }) {
        $options{ synchronize } = 1;
    };
    
    $self->_sync_call( $options{ synchronize }, $self->{events}, sub {
        if (my $target = delete $options{":content_file"}) {
            $self->save_url($url => ''.$target, %options);
        } else {
            $b->loadURIWithFlags(''.$url,$flags);
        };
    });
};

=head2 C<< $mech->get_local( $filename , %options ) >>

  $mech->get_local('test.html');

Shorthand method to construct the appropriate
C<< file:// >> URI and load it into Firefox. Relative
paths will be interpreted as relative to C<$0>.

This method accepts the same options as C<< ->get() >>.

This method is special to WWW::Mechanize::Firefox but could
also exist in WWW::Mechanize through a plugin.

=cut

sub get_local {
    my ($self, $htmlfile, %options) = @_;
    my $fn = File::Spec->rel2abs(
                 File::Spec->catfile(dirname($0),$htmlfile),
                 getcwd,
             );
    $fn =~ s!\\!/!g; # fakey "make file:// URL"

    $self->get("file://$fn", %options);
}

# Should I port this to Perl?
# Should this become part of MozRepl::RemoteObject?
# This should get passed 
sub _addEventListener {
    my ($self,@args) = @_;
    if (@args <= 2 and ref($args[0]) eq 'MozRepl::RemoteObject::Instance') {
        @args = [@args];
    };
    #use Data::Dumper;
    #local $Data::Dumper::Maxdepth = 2;
    #print Dumper \@args;
    for (@args) {
        $_->[1] ||= $self->events;
        $_->[1] = [$_->[1]]
            unless ref $_->[1];
    };
    # Now, flatten the arg list again...
    @args = map { @$_ } @args;

    # This registers multiple events for a one-shot event
    my $make_semaphore = $self->repl->declare(<<'JS');
function() {
    var lock = { "busy": 0, "event" : null };
    var listeners = [];
    var pairs = arguments;
    for( var k = 0; k < pairs.length ; k++) {
        var b = pairs[k];
        k++;
        var events = pairs[k];
        
        for( var i = 0; i < events.length; i++) {
            var evname = events[i];
            var callback = (function(listeners,evname){
                return function(e) {
                    if (! lock.busy) {
                        lock.busy++;
                        lock.event = e.type;
                        lock.js_event = {};
                        lock.js_event.target = e.originalTarget;
                        lock.js_event.type = e.type;
                        //alert("Caught first event " + e.type + " " + e.message);
                    } else {
                        //alert("Caught duplicate event " + e.type + " " + e.message);
                    };
                    for( var j = 0; j < listeners.length; j++) {
                        listeners[j][0].removeEventListener(listeners[j][1],listeners[j][2],true);
                    };
                };
            })(listeners,evname);
            listeners.push([b,evname,callback]);
            b.addEventListener(evname,callback,true);
        };
    };
    return lock
}
JS
    # $browser,$events
    return $make_semaphore->(@args);
};

sub _wait_while_busy {
    my ($self,@elements) = @_;
    # Now do the busy-wait
    # Should this also include a ->poll()
    # and a callback?
    while (1) {
        for my $element (@elements) {
            if ((my $s = $element->{busy} || 0) >= 1) {
                return $element;
            };
        };
        sleep 0.1;
    };
}

=head2 C<< $mech->synchronize( $event, $callback ) >>

Wraps a synchronization semaphore around the callback
and waits until the event C<$event> fires on the browser.
If you want to wait for one of multiple events to occur,
pass an array reference as the first parameter.

Usually, you want to use it like this:

  my $l = $mech->xpath('//a[@onclick]', single => 1);
  $mech->synchronize('DOMFrameContentLoaded', sub {
      $l->__click()
  });

It is necessary to synchronize with the browser whenever
a click performs an action that takes longer and
fires an event on the browser object.

The C<DOMFrameContentLoaded> event is fired by Firefox when
the whole DOM and all C<iframe>s have been loaded.
If your document doesn't have frames, use the C<DOMContentLoaded>
event instead.

If you leave out C<$event>, the value of C<< ->events() >> will
be used instead.


=cut

sub _install_response_header_listener {
    my ($self) = @_;
    
    weaken $self;

    # Pre-Filter the progress on the JS side of things so we
    # don't get that much traffic back and forth between Perl and JS
    my $make_state_change_filter = $self->repl->declare(<<'JS');
        function (cb) {
            const STATE_STOP = Components.interfaces.nsIWebProgressListener.STATE_STOP;
            const STATE_IS_DOCUMENT = Components.interfaces.nsIWebProgressListener.STATE_IS_DOCUMENT;
            const STATE_IS_WINDOW = Components.interfaces.nsIWebProgressListener.STATE_IS_WINDOW;
            
            return cb
            return function (progress,request,flags,status) {
                if (flags & (STATE_STOP|STATE_IS_DOCUMENT) == (STATE_STOP|STATE_IS_DOCUMENT)) {
                    cb(progress,request,flags,status);
                }
            }
        }
JS

    # These should be cached and optimized into one hash query
    my $STATE_STOP = $self->repl->constant('Components.interfaces.nsIWebProgressListener.STATE_STOP');
    my $STATE_IS_DOCUMENT = $self->repl->constant('Components.interfaces.nsIWebProgressListener.STATE_IS_DOCUMENT');
    my $STATE_IS_WINDOW = $self->repl->constant('Components.interfaces.nsIWebProgressListener.STATE_IS_WINDOW');
    
    my $state_change = $make_state_change_filter->(sub {
        my ($progress,$request,$flags,$status) = @_;
        #warn sprintf "State     : <progress> <request> %08x %08x\n", $flags, $status;
        #warn sprintf "                                 %08x\n", $STATE_STOP | $STATE_IS_DOCUMENT;
        #warn "".$request->{URI}->{asciiSpec};
        
        if (($flags & ($STATE_STOP | $STATE_IS_DOCUMENT)) == ($STATE_STOP | $STATE_IS_DOCUMENT)) {
            if ($status == 0) {
                #warn "Storing request to response";
                #warn "URI ".$request->{URI}->{asciiSpec};
                $self->{ response } ||= $request;
            } else {
                #warn "Erasing response";
                undef $self->{ response };
            };
            #if ($status) {
            #    warn sprintf "%08x", $status;
            #};
        };
    });

    my $browser = $self->tab->{linkedBrowser};

    # These should mimick the LWP::UserAgent events maybe?
    return $self->progress_listener(
        $browser,
        onStateChange => $state_change,
        #onProgressChange => sub { print  "Progress  : @_\n" },
        #onLocationChange => sub { printf "Location  : %s\n", $_[2]->{spec} },
        #onStatusChange   => sub { print  "Status    : @_\n"; },
    );
};

sub synchronize {
    my ($self,$events,$callback) = @_;
    if (ref $events and ref $events eq 'CODE') {
        $callback = $events;
        $events = $self->events;
    };
    
    $events = [ $events ]
        unless ref $events;
    
    undef $self->{response};
    
    my $need_response = defined wantarray;
    my $response_catcher = $self->_install_response_header_listener();
    
    # 'load' on linkedBrowser is good for successfull load
    # 'error' on tab is good for failed load :-(
    my $b = $self->tab->{linkedBrowser};
    my $load_lock = $self->_addEventListener([$b,$events],[$self->tab,$events]);
    $callback->();
    my $ev = $self->_wait_while_busy($load_lock);
    if (my $h = $self->{on_event}) {
        if (ref $h eq 'CODE') {
            $h->($ev)
        } else {
            warn "Received $ev->{event}";
            #warn "$ev->{event}->{text}"";
        };
    };
    
    $self->signal_http_status; # will also fetch ->response if autodie is on :(
    if ($need_response) {
        #warn "Returning response";
        return $self->response
    };
};

=head2 C<< $mech->res >> / C<< $mech->response >>

    my $response = $mech->response();

Returns the current response as a L<HTTP::Response> object.

=cut

sub _headerVisitor {
    my ($self,$cb) = @_;
    my $obj = $self->repl->expr('new Object');
    $obj->{visitHeader} = $cb;
    $obj
};

sub _extract_response {
    my ($self,$request) = @_;
    
    my $nsIHttpChannel = $self->repl->constant('Components.interfaces.nsIHttpChannel');
    my $httpChannel = $request->QueryInterface($nsIHttpChannel);
    #warn $httpChannel->{originalURI}->{asciiSpec};
    
    my @headers;
    my $v = $self->_headerVisitor(sub{push @headers, @_});
    
    # If this fails, we're calling it too early :-(
    $httpChannel->visitResponseHeaders($v);
    
    my $res = HTTP::Response->new(
        $httpChannel->{responseStatus},
        $httpChannel->{responseStatusText},
        \@headers,
        undef, # no body so far
    );
    return $res;
};

sub response {
    my ($self) = @_;
    
    # If we still have a valid JS response,
    # create a HTTP::Response from that
    if (my $js_res = $self->{ response }) {
        #my $ouri = $js_res->{originalURI};
        my $ouri = $js_res->{URI};
        my $scheme = '<no scheme>';
        #warn "Reading response for ".$js_res->{URI}->{asciiSpec};
        #warn "            original ".$js_res->{originalURI}->{asciiSpec};
        if ($ouri) {
            $scheme = $ouri->{scheme};
        };
        if ($scheme and $scheme =~ /^https?/) {
            # We can only extract from a HTTP Response
            return $self->_extract_response( $js_res );
        } elsif ($scheme and $scheme =~ /^(file|data|about)\b/) {
            # We're cool!
            return HTTP::Response->new( 200, '', ['Content-Encoding','UTF-8'], encode 'UTF-8' => $self->content);
        } else {
            # We'll make up a response, below
            #my $url = $self->document->{documentURI};
            #carp "Making up a response for unknown URL scheme '$scheme' (from '$url')";
        };
    };
    
    # Otherwise, make up a reason:
    my $eff_url = $self->document->{documentURI};
    #warn $eff_url;
    if ($eff_url =~ /^about:neterror/) {
        # this is an error
        return HTTP::Response->new(500)
    };   

    # We're cool, except we don't know what we're doing here:
    #warn "Huh?";
    return HTTP::Response->new( 200, '', ['Content-Encoding','UTF-8'], encode 'UTF-8' => $self->content);
}
*res = \&response;

=head2 C<< $mech->success >>

    $mech->get('http://google.com');
    print "Yay"
        if $mech->success();

Returns a boolean telling whether the last request was successful.
If there hasn't been an operation yet, returns false.

This is a convenience function that wraps C<< $mech->res->is_success >>.

=cut

sub success {
    my $res = $_[0]->response;
    $res and $res->is_success
}

=head2 C<< $mech->status >>

    $mech->get('http://google.com');
    print $mech->status();
    # 200

Returns the HTTP status code of the response.
This is a 3-digit number like 200 for OK, 404 for not found, and so on.

=cut

sub status {
    $_[0]->response->code
};

=head2 C<< $mech->reload( [$bypass_cache] ) >>

    $mech->reload();

Reloads the current page. If C<$bypass_cache>
is a true value, the browser is not allowed to
use a cached page. This is the difference between
pressing C<F5> (cached) and C<shift-F5> (uncached).

Returns the (new) response.

=cut

sub reload {
    my ($self, $bypass_cache) = @_;
    $bypass_cache ||= 0;
    if ($bypass_cache) {
        $bypass_cache = $self->repl->constant('nsIWebNavigation.LOAD_FLAGS_BYPASS_CACHE');
    };
    $self->synchronize( sub {
        $self->tab->{linkedBrowser}->reloadWithFlags($bypass_cache);
    });
}

# Internal convenience method for dipatching a call either synchronized
# or not
sub _sync_call {
    my ($self, $synchronize, $events, $cb) = @_;

    if ($synchronize) {
        $self->synchronize( $events, $cb );
    } else {
        $cb->();
    };    
};

=head2 C<< $mech->back( [$synchronize] ) >>

    $mech->back();

Goes one page back in the page history.

Returns the (new) response.

=cut

sub back {
    my ($self, $synchronize) = @_;
    $synchronize ||= (@_ != 2);
    
    $self->_sync_call($synchronize, $self->events, sub {
        $self->tab->{linkedBrowser}->goBack;
    });
}

=head2 C<< $mech->forward( [$synchronize] ) >>

    $mech->forward();

Goes one page forward in the page history.

Returns the (new) response.

=cut

sub forward {
    my ($self, $synchronize) = @_;
    $synchronize ||= (@_ != 2);
    
    $self->_sync_call($synchronize, $self->events, sub {
        $self->tab->{linkedBrowser}->goForward;
    });
}

=head2 C<< $mech->uri >>

    print "We are at " . $mech->uri;

Returns the current document URI.

=cut

sub uri {
    my ($self) = @_;
    my $loc = $self->tab->__dive(qw[
        linkedBrowser
        currentURI
        asciiSpec ]);
    return URI->new( $loc );
};

=head1 CONTENT METHODS

=head2 C<< $mech->document >>

Returns the DOM document object.

This is WWW::Mechanize::Firefox specific.

=cut

sub document {
    my ($self) = @_;
    $self->tab->__dive(qw[linkedBrowser contentWindow document]);
}

=head2 C<< $mech->docshell >>

    my $ds = $mech->docshell;

Returns the C<docShell> Javascript object associated with the tab.

This is WWW::Mechanize::Firefox specific.

=cut

sub docshell {
    my ($self) = @_;
    $self->tab->__dive(qw[linkedBrowser docShell]);
}

=head2 C<< $mech->content >>

  print $mech->content;

This always returns the content as a Unicode string. It tries
to decode the raw content according to its input encoding.

This is likely not binary-safe.

It also currently only works for HTML pages.

=cut

sub content {
    my ($self, %options) = @_;
    my $d = $self->document; # keep a reference to it!
    
    my $html = $self->repl->declare(<<'JS', 'list');
function(d){
    var e = d.createElement("div");
    e.appendChild(d.documentElement.cloneNode(true));
    return [e.innerHTML,d.inputEncoding];
}
JS
    # We return the raw bytes here.
    my ($content,$encoding) = $html->($d);
    if (! utf8::is_utf8($content)) {
        #warn "Switching on UTF-8 (from $encoding)";
        # Switch on UTF-8 flag
        # This should never happen, as JSON::XS (and JSON) should always
        # already return proper UTF-8
        # But it does happen.
        $content = Encode::decode($encoding, $content);
    };
    
    if ( my $format = delete $options{format} ) {
        if ( $format eq 'text' ) {
            $content = $self->text;
        }
        else {
            $self->die( qq{Unknown "format" parameter "$format"} );
        }
    }

    return $content
};

=head2 $mech->text()

Returns the text of the current HTML content.  If the content isn't
HTML, $mech will die.

=cut

sub text {
    my $self = shift;
    
    # Waugh - this is highly inefficient but conveniently short to write
    # Maybe this should skip SCRIPT nodes...
    join '', map { $_->{nodeValue} } $self->xpath('//*/text()');
}


=head2 C<< $mech->content_encoding >>

    print "The content is encoded as ", $mech->content_encoding;

Returns the encoding that the content is in. This can be used
to convert the content from UTF-8 back to its native encoding.

=cut

sub content_encoding {
    my ($self, $d) = @_;
    $d ||= $self->document; # keep a reference to it!
    return $d->{inputEncoding};
};

=head2 C<< $mech->update_html( $html ) >>

  $mech->update_html($html);

Writes C<$html> into the current document. This is mostly
implemented as a convenience method for L<HTML::Display::MozRepl>.

=cut

sub update_html {
    my ($self,$content) = @_;
    my $url = URI->new('data:');
    $url->media_type("text/html");
    $url->data($content);
    $self->synchronize($self->events, sub {
        $self->tab->{linkedBrowser}->loadURI("$url");
    });
    return
};

=head2 C<< $mech->save_content( $localname [, $resource_directory] [, %options ] ) >>

  $mech->get('http://google.com');
  $mech->save_content('google search page','google search page files');

Saves the given URL to the given filename. The URL will be
fetched from the cache if possible, avoiding unnecessary network
traffic.

If C<$resource_directory> is given, the whole page will be saved.
All CSS, subframes and images
will be saved into that directory, while the page HTML itself will
still be saved in the file pointed to by C<$localname>.

Returns a C<nsIWebBrowserPersist> object through which you can cancel the
download by calling its C<< ->cancelSave >> method. Also, you can poll
the download status through the C<< ->{currentState} >> property.

If you are interested in the intermediate download progress, create
a ProgressListener through C<< $mech->progress_listener >>
and pass it in the C<progress> option.

The download will
continue in the background. It will not show up in the
Download Manager.

=cut

sub save_content {
    my ($self,$localname,$resource_directory,%options) = @_;
    
    $localname = File::Spec->rel2abs($localname, '.');    
    # Touch the file
    if (! -f $localname) {
    	open my $fh, '>', $localname
    	    or die "Couldn't create '$localname': $!";
    };

    if ($resource_directory) {
        $resource_directory = File::Spec->rel2abs($resource_directory, '.');

        # Create the directory
        if (! -d $resource_directory) {
            mkdir $resource_directory
                or die "Couldn't create '$resource_directory': $!";
        };
    };
    
    my $transfer_file = $self->repl->declare(<<'JS');
function (document,filetarget,rscdir,progress) {
    //new file object
    var obj_target;
    if (filetarget) {
        obj_target = Components.classes["@mozilla.org/file/local;1"]
        .createInstance(Components.interfaces.nsILocalFile);
    };

    //set file with path
    obj_target.initWithPath(filetarget);

    var obj_rscdir;
    if (rscdir) {
        obj_rscdir = Components.classes["@mozilla.org/file/local;1"]
        .createInstance(Components.interfaces.nsILocalFile);
        obj_rscdir.initWithPath(rscdir);
    };

    var obj_Persist = Components.classes["@mozilla.org/embedding/browser/nsWebBrowserPersist;1"]
        .createInstance(Components.interfaces.nsIWebBrowserPersist);

    // with persist flags if desired
    const nsIWBP = Components.interfaces.nsIWebBrowserPersist;
    const flags = nsIWBP.PERSIST_FLAGS_REPLACE_EXISTING_FILES;
    obj_Persist.persistFlags = flags | nsIWBP.PERSIST_FLAGS_FROM_CACHE
                                     | nsIWBP["PERSIST_FLAGS_FORCE_ALLOW_COOKIES"]
                                     ;
    
    obj_Persist.progressListener = progress;

    //save file to target
    obj_Persist.saveDocument(document,obj_target, obj_rscdir, null,0,0);
    return obj_Persist
};
JS
    #warn "=> $localname / $resource_directory";
    $transfer_file->(
        $self->document,
        $localname,
        $resource_directory,
        $options{progress}
    );
}

=head2 C<< $mech->save_url( $url, $localname, [%options] ) >>

  $mech->save_url('http://google.com','google_index.html');

Saves the given URL to the given filename. The URL will be
fetched from the cache if possible, avoiding unnecessary network
traffic.

Returns a C<nsIWebBrowserPersist> object through which you can cancel the
download by calling its C<< ->cancelSave >> method. Also, you can poll
the download status through the C<< ->{currentState} >> property.

If you are interested in the intermediate download progress, create
a ProgressListener through C<< $mech->progress_listener >>
and pass it in the C<progress> option.

The download will
continue in the background. It will also not show up in the
Download Manager.

=cut

sub save_url {
    my ($self,$url,$localname,%options) = @_;
    
    $localname = File::Spec->rel2abs($localname, '.');
    
    if (! -f $localname) {
    	open my $fh, '>', $localname
    	    or die "Couldn't create '$localname': $!";
    };
    
    my $transfer_file = $self->repl->declare(<<'JS');
function (source,filetarget,progress) {
    //new obj_URI object
    var obj_URI = Components.classes["@mozilla.org/network/io-service;1"]
        .getService(Components.interfaces.nsIIOService).newURI(source, null, null);

    //new file object
    var obj_target;
    if (filetarget) {
        obj_target = Components.classes["@mozilla.org/file/local;1"]
        .createInstance(Components.interfaces.nsILocalFile);
    };

    //set file with path
    obj_target.initWithPath(filetarget);

    //new persitence object
    var obj_Persist = Components.classes["@mozilla.org/embedding/browser/nsWebBrowserPersist;1"]
        .createInstance(Components.interfaces.nsIWebBrowserPersist);

    // with persist flags if desired
    const nsIWBP = Components.interfaces.nsIWebBrowserPersist;
    const flags = nsIWBP.PERSIST_FLAGS_REPLACE_EXISTING_FILES;
    // Also make it send the proper cookies
    // If we are on a 3.0 Firefox, PERSIST_FLAGS_FORCE_ALLOW_COOKIES does
    // not exist, so we need to get creative:
    
    obj_Persist.persistFlags = flags | nsIWBP.PERSIST_FLAGS_FROM_CACHE
                                     | nsIWBP["PERSIST_FLAGS_FORCE_ALLOW_COOKIES"]
                                     ;
    obj_Persist.progressListener = progress;

    //save file to target
    obj_Persist.saveURI(obj_URI,null,null,null,null,obj_target);
    return obj_Persist
};
JS
    $transfer_file->("$url" => $localname, $options{progress});
}

=head2 C<< $mech->base >>

  print $mech->base;

Returns the URL base for the current page.

The base is either specified through a C<base>
tag or is the current URL.

This method is specific to WWW::Mechanize::Firefox

=cut

sub base {
    my ($self) = @_;
    (my $base) = $self->selector('base');
    $base = $base->{href}
        if $base;
    $base ||= $self->uri;
};

=head2 C<< $mech->content_type >>

=head2 C<< $mech->ct >>

  print $mech->content_type;

Returns the content type of the currently loaded document

=cut

sub content_type {
    my ($self) = @_;
    return $self->document->{contentType};
};

*ct = \&content_type;

=head2 C<< $mech->is_html() >>

  print $mech->is_html();

Returns true/false on whether our content is HTML, according to the
HTTP headers.

=cut

sub is_html {       
    my $self = shift;
    return defined $self->ct && ($self->ct eq 'text/html');
}

=head2 C<< $mech->title >>

  print "We are on page " . $mech->title;

Returns the current document title.

=cut

sub title {
    my ($self) = @_;
    return $self->document->{title};
};

=head1 EXTRACTION METHODS

=head2 C<< $mech->links >>

  print $_->text . " -> " . $_->url . "\n"
      for $mech->links;

Returns all links in the document as L<WWW::Mechanize::Link> objects.

Currently accepts no parameters. See C<< ->xpath >>
or C<< ->selector >> when you want more control.

=cut

%link_spec = (
    a      => { url => 'href', },
    area   => { url => 'href', },
    frame  => { url => 'src', },
    iframe => { url => 'src', },
    link   => { url => 'href', },
    meta   => { url => 'content', xpath => (join '',
                    q{translate(@http-equiv,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',},
                    q{'abcdefghijklmnopqrstuvwxyz')="refresh"}), },
);

# taken from WWW::Mechanize. This should possibly just be reused there
sub make_link {
    my ($self,$node,$base) = @_;
    my $tag = lc $node->{tagName};
    
    if (! exists $link_spec{ $tag }) {
        warn "Unknown tag '$tag'";
    };
    my $url = $node->{ $link_spec{ $tag }->{url} };
    
    if ($tag eq 'meta') {
        my $content = $url;
        if ( $content =~ /^\d+\s*;\s*url\s*=\s*(\S+)/i ) {
            $url = $1;
            $url =~ s/^"(.+)"$/$1/ or $url =~ s/^'(.+)'$/$1/;
        }
        else {
            undef $url;
        }
    };
    
    if (defined $url) {
        my $res = WWW::Mechanize::Link->new({
            tag   => $tag,
            name  => $node->{name},
            base  => $base,
            url   => $url,
            text  => $node->{innerHTML},
            attrs => {},
        });
        
        $res
    } else {
        ()
    };
}

sub links {
    my ($self) = @_;
    my @links = $self->selector( join ",", sort keys %link_spec);
    my $base = $self->base;
    return map {
        $self->make_link($_,$base)
    } @links;
};

# Call croak or carp, depending on the C< autodie > setting
sub signal_condition {
    my ($self,$msg) = @_;
    if ($self->{autodie}) {
        croak $msg
    } else {
        carp $msg
    }
};

# Call croak on the C< autodie > setting if we have a non-200 status
sub signal_http_status {
    my ($self) = @_;
    if ($self->{autodie}) {
        if ($self->status !~ /^2/) {
            # there was an error
            croak ($self->response->message || sprintf "Got status code %d", $self->status );
        };
    } else {
        # silent
    }
};

=head2 C<< $mech->find_link_dom( %options ) >>

  print $_->{innerHTML} . "\n"
      for $mech->find_link_dom( text_contains => 'CPAN' );

A method to find links, like L<WWW::Mechanize>'s
C<< ->find_links >> method. This method returns DOM objects from
Firefox instead of WWW::Mechanize::Link objects.

Note that Firefox
might have reordered the links or frame links in the document
so the absolute numbers passed via C<n>
might not be the same between
L<WWW::Mechanize> and L<WWW::Mechanize::Firefox>.

Returns the DOM object as L<MozRepl::RemoteObject>::Instance.

The supported options are:

=over 4

=item *

C<< text >> and C<< text_contains >> and C<< text_regex >>

Match the text of the link as a complete string, substring or regular expression.

Matching as a complete string or substring is a bit faster, as it is
done in the XPath engine of Firefox.

=item *

C<< id >> and C<< id_contains >> and C<< id_regex >>

Matches the C<id> attribute of the link completely or as part

=item *

C<< name >> and C<< name_contains >> and C<< name_regex >>

Matches the C<name> attribute of the link

=item *

C<< url >> and C<< url_regex >>

Matches the URL attribute of the link (C<href>, C<src> or C<content>).

=item *

C<< class >> - the C<class> attribute of the link

=item *

C<< n >> - the (1-based) index. Defaults to returning the first link.

=item *

C<< single >> - If true, ensure that only one element is found. Otherwise croak
or carp, depending on the C<autodie> parameter.

=item *

C<< one >> - If true, ensure that at least one element is found. Otherwise croak
or carp, depending on the C<autodie> parameter.

The method C<croak>s if no link is found. If the C<single> option is true,
it also C<croak>s when more than one link is found.

=back

=cut

use vars '%xpath_quote';
%xpath_quote = (
    '"' => '\"',
    #"'" => "\\'",
    #'[' => '&#91;',
    #']' => '&#93;',
    #'[' => '[\[]',
    #'[' => '\[',
    #']' => '[\]]',
);

# Return the default limiter if no other limiting option is set:
sub _default_limiter {
    my ($default, $options) = @_;
    if (! grep { exists $options->{ $_ } } qw(single one maybe all any)) {
        $options->{ $default } = 1;
    };
    return ()
};

sub quote_xpath($) {
    local $_ = $_[0];
    s/(['"\[\]])/$xpath_quote{$1} || $1/ge;
    $_
};

#sub perl_regex_to_xpath($) {
#    my ($re) = @_;
#    my $flags = '';
#    warn $re;
#    $re =~ s!^\(\?([a-z]*)\-[a-z]*:(.*)\)$!$2!
#        and $flags = $1;
#    warn qq{=> XPATH: "$re" , "$flags"};
#    ($re, $flags)
#};

sub find_link_dom {
    my ($self,%opts) = @_;
    my %xpath_options;
    
    for (qw(node document frames)) {
        # Copy over XPath options that were passed in
        if (exists $opts{ $_ }) {
            $xpath_options{ $_ } = delete $opts{ $_ };
        };
    };
    
    my $single = delete $opts{ single };
    my $one = delete $opts{ one } || $single;
    if ($single and exists $opts{ n }) {
        croak "It doesn't make sense to use 'single' and 'n' option together"
    };
    my $n = (delete $opts{ n } || 1);
    $n--
        if ($n ne 'all'); # 1-based indexing
    my @spec;
    
    # Decode text and text_contains into XPath
    for my $lvalue (qw( text id name class )) {
        my %lefthand = (
            text => 'text()',
        );
        my %match_op = (
            '' => q{%s="%s"},
            'contains' => q{contains(%s,"%s")},
            # Ideally we would also handle *_regex here, but Firefox XPath
            # does not support fn:matches() :-(
            #'regex' => q{matches(%s,"%s","%s")},
        );
        my $lhs = $lefthand{ $lvalue } || '@'.$lvalue;
        for my $op (keys %match_op) {
            my $v = $match_op{ $op };
            $op = '_'.$op if length($op);
            my $key = "${lvalue}$op";

            if (exists $opts{ $key }) {
                my $p = delete $opts{ $key };
                push @spec, sprintf $v, $lhs, $p;
            };
        };
    };

    if (my $p = delete $opts{ url }) {
        push @spec, sprintf '@href = "%s" or @src="%s"', quote_xpath $p, quote_xpath $p;
    }
    my @tags = (sort keys %link_spec);
    if (my $p = delete $opts{ tag }) {
        @tags = $p;
    };
    if (my $p = delete $opts{ tag_regex }) {
        @tags = grep /$p/, @tags;
    };
    
    my $q = join '|', 
            map {
                my @full = map {qq{($_)}} grep {defined} (@spec, $link_spec{$_}->{xpath});
                if (@full) {
                    sprintf "//%s[%s]", $_, join " and ", @full;
                } else {
                    sprintf "//%s", $_
                };
            }  (@tags);
    #warn $q;
    
    my @res = $self->xpath($q, %xpath_options );
    
    if (keys %opts) {
        # post-filter the remaining links through WWW::Mechanize
        # for all the options we don't support with XPath
        
        my $base = $self->base;
        require WWW::Mechanize;
        @res = grep { 
            WWW::Mechanize::_match_any_link_parms($self->make_link($_,$base),\%opts) 
        } @res;
    };
    
    if ($one) {
        if (0 == @res) { $self->signal_condition( "No link found matching '$q'" )};
        if ($single) {
            if (1 <  @res) {
                $self->highlight_node(@res);
                $self->signal_condition(
                    sprintf "%d elements found found matching '%s'", scalar @res, $q
                );
            };
        };
    };
    
    if ($n eq 'all') {
        return @res
    };
    $res[$n]
}

=head2 C<< $mech->find_link( %options ) >>

  print $_->text . "\n"
      for $mech->find_link_dom( text_contains => 'CPAN' );

A method quite similar to L<WWW::Mechanize>'s method.
The options are documented in C<< ->find_link_dom >>.

Returns a L<WWW::Mechanize::Link> object.

This defaults to not look through child frames.

=cut

sub find_link {
    my ($self,%opts) = @_;
    my $base = $self->base;
    croak "Option 'all' not available for ->find_link. Did you mean to call ->find_all_links()?"
        if 'all' eq ($opts{n} || '');
    if (my $link = $self->find_link_dom(frames => 0, %opts)) {
        return $self->make_link($link, $base)
    } else {
        return
    };
};

=head2 C<< $mech->find_all_links( %options ) >>

  print $_->text . "\n"
      for $mech->find_link_dom( text_regex => qr/google/i );

Finds all links in the document.
The options are documented in C<< ->find_link_dom >>.

Returns them as list or an array reference, depending
on context.

This defaults to not look through child frames.

=cut

sub find_all_links {
    my ($self, %opts) = @_;
    $opts{ n } = 'all';
    my $base = $self->base;
    my @matches = map {
        $self->make_link($_, $base);
    } $self->find_all_links_dom( frames => 0, %opts );
    return @matches if wantarray;
    return \@matches;
};

=head2 C<< $mech->find_all_links_dom %options >>

  print $_->{innerHTML} . "\n"
      for $mech->find_link_dom( text_regex => qr/google/i );

Finds all matching linky DOM nodes in the document.
The options are documented in C<< ->find_link_dom >>.

Returns them as list or an array reference, depending
on context.

This defaults to not look through child frames.

=cut

sub find_all_links_dom {
    my ($self,%opts) = @_;
    $opts{ n } = 'all';
    my @matches = $self->find_link_dom( frames => 0, %opts );
    return @matches if wantarray;
    return \@matches;
};

=head2 C<< $mech->follow_link $link >>

=head2 C<< $mech->follow_link %options >>

  $mech->follow_link( xpath => '//a[text() = "Click here!"]' );

Follows the given link. Takes the same parameters that C<find_link_dom>
uses. In addition, C<synchronize> can be passed to (not) force
waiting for a new page to be loaded.

Note that C<< ->follow_link >> will only try to follow link-like
things like C<A> tags.

=cut

sub follow_link {
    my ($self,$link,%opts);
    if (@_ == 2) { # assume only a link parameter
        ($self,$link) = @_;
        $self->click($link);
    } else {
        ($self,%opts) = @_;
        _default_limiter( one => \%opts );
        $link = $self->find_link_dom(%opts);
        $self->click({ dom => $link, %opts });
    }
}

=head2 C<< $mech->xpath $query, %options >>

    my $link = $mech->xpath('//a[id="clickme"]', one => 1);
    # croaks if there is no link or more than one link found

    my @para = $mech->xpath('//p');
    # Collects all paragraphs

Runs an XPath query in Firefox against the current document.

The options allow the following keys:

=over 4

=item *

C<< document >> - document in which the query is to be executed. Use this to
search a node within a specific subframe of C<< $mech->document >>.

=item *

C<< frames >> - if true, search all documents in all frames and iframes.
This may or may not conflict with C<node>. This will default to the
C<frames> setting of the WWW::Mechanize::Firefox object.

=item *

C<< node >> - node relative to which the query is to be executed

=item *

C<< single >> - If true, ensure that only one element is found. Otherwise croak
or carp, depending on the C<autodie> parameter.

=item *

C<< one >> - If true, ensure that at least one element is found. Otherwise croak
or carp, depending on the C<autodie> parameter.

=item *

C<< maybe >> - If true, ensure that at most one element is found. Otherwise
croak or carp, depending on the C<autodie> parameter.

=item *

C<< all >> - If true, return all elements found. This is the default.
You can use this option if you want to use C<< ->xpath >> in scalar context
to count the number of matched elements, as it will otherwise emit a warning
for each usage in scalar context without any of the above restricting options.

=item *

C<< any >> - no error is raised, no matter if an item is found or not.

=back

Returns the matched nodes.

You can pass in a list of queries as an array reference for the first parameter.
The result will then be the list of all elements matching any of the queries.

This is a method that is not implemented in WWW::Mechanize.

In the long run, this should go into a general plugin for
L<WWW::Mechanize>.

=cut

sub xpath {
    my ($self,$query,%options) = @_;
    if ('ARRAY' ne (ref $query||'')) {
        $query = [$query];
    };
    
    if ($options{ node }) {
        $options{ document } ||= $options{ node }->{ownerDocument};
        #warn "Have node, searching below node";
    } else {
        $options{ document } ||= $self->document;
    };
    
    $options{ user_info } ||= join " or ", map {qq{'$_'}} @$query;
    my $single = delete $options{ single };
    my $first  = delete $options{ one };
    my $maybe  = delete $options{ maybe };
    my $any    = delete $options{ any };
    
    # Construct some helper variables
    my $zero_allowed = not ($single or $first);
    my $two_allowed  = not( $single or $maybe);
    my $return_first = ($single or $first or $maybe or $any);
    #warn "Zero: $zero_allowed";
    #warn "Two : $two_allowed";
    #warn "Ret : $return_first";
    
    # Sanity check for the common error of
    # my $item = $mech->xpath("//foo");
    if (! exists $options{ all } and not ($return_first)) {
        $self->signal_condition(join "\n",
            "You asked for many elements but seem to only want a single item.",
            "Did you forget to pass the 'single' option with a true value?",
            "Pass 'all => 1' to suppress this message and receive the count of items.",
        ) if defined wantarray and !wantarray;
    };
    
    if (not exists $options{ frames }) {
        $options{frames} = $self->{frames};
    };
    
    my @res;
    
    DOCUMENTS: {            
        my @documents = $options{ document };
        #warn "Invalid root document" unless $options{ document };
        
        # recursively join the results of sub(i)frames if wanted
        # This should maybe go into the loop to expand every frame as we descend
        # into the available subframes

        while (@documents) {
            my $doc = shift @documents;
            #warn "Invalid document" unless $doc;

            my $n = $options{ node } || $doc;
            #warn ">Searching @$query in $doc->{title}";
            # Munge the multiple @$queries into one:
            my $q = join "|", @$query;
            #warn $q;
            my @found = map { $doc->__xpath($_, $n) } $q; # @$query;
            #warn "Found $_->{tagName}" for @found;
            push @res, @found;
            
            # A small optimization to return if we already have enough elements
            # We can't do this on $return_first as there might be more elements
            last DOCUMENTS if @res and $first;        
            
            if ($options{ frames } and not $options{ node }) {
                #warn "$nesting>Expanding below " . $doc->{title};
                #local $nesting .= "--";
                my @d = $self->expand_frames( $options{ frames }, $doc );
                #warn "Found $_->{title}" for @d;
                push @documents, @d;
            };
        };
    };
    
    if (! $zero_allowed and @res == 0) {
        $self->signal_condition( "No elements found for $options{ user_info }" );
    };
    
    if (! $two_allowed and @res > 1) {
        $self->highlight_node(@res);
        $self->signal_condition( (scalar @res) . " elements found for $options{ user_info }" );
    };
    
    return $return_first ? $res[0] : @res;
};

=head2 C<< $mech->selector $css_selector, %options >>

  my @text = $mech->selector('p.content');

Returns all nodes matching the given CSS selector. If
C<$css_selector> is an array reference, it returns
all nodes matched by any of the CSS selectors in the array.

This takes the same options that C<< ->xpath >> does.

In the long run, this should go into a general plugin for
L<WWW::Mechanize>.

=cut

sub selector {
    my ($self,$query,%options) = @_;
    $options{ user_info } ||= "CSS selector '$query'";
    if ('ARRAY' ne (ref $query || '')) {
        $query = [$query];
    };
    my @q = map { selector_to_xpath($_) } @$query;
    $self->xpath(\@q, %options);
};

=head2 C<< $mech->by_id $id, %options >>

  my @text = $mech->by_id('_foo:bar');

Returns all nodes matching the given ids. If
C<$id> is an array reference, it returns
all nodes matched by any of the ids in the array.

This method is equivalent to calling C<< ->xpath >> :

    $self->xpath(qq{//*[\@id="$_"], %options)

It is convenient when your element ids get mistaken for
CSS selectors.

=cut

sub by_id {
    my ($self,$query,%options) = @_;
    if ('ARRAY' ne (ref $query||'')) {
        $query = [$query];
    };
    $options{ user_info } ||= "id " 
                            . join(" or ", map {qq{'$_'}} @$query)
                            . " found";
    $query = [map { qq{.//*[\@id="$_"]} } @$query];
    $self->xpath($query, %options)
}

=head2 C<< $mech->click $name [,$x ,$y] >>

  $mech->click( 'go' );
  $mech->click({ xpath => '//button[@name="go"]' });

Has the effect of clicking a button on the current form. The first argument
is the C<name> of the button to be clicked. The second and third arguments
(optional) allow you to specify the (x,y) coordinates of the click.

If there is only one button on the form, C<< $mech->click() >> with
no arguments simply clicks that one button.

If you pass in a hash reference instead of a name,
the following keys are recognized:

=over 4

=item *

C<selector> - Find the element to click by the CSS selector

=item *

C<xpath> - Find the element to click by the XPath query

=item *

C<dom> - Click on the passed DOM element

=item *

C<id> - Click on the element with the given id

This is useful if your document ids contain characters that
do look like CSS selectors. It is equivalent to

    xpath => qq{//*[\@id="$id"}

=item *

C<synchronize> - Synchronize the click (default is 1)

Synchronizing means that WWW::Mechanize::Firefox will wait until
one of the events listed in C<events> is fired. You want to switch
it off when there will be no HTTP response or DOM event fired, for
example for clicks that only modify the DOM.

=back

Returns a L<HTTP::Response> object.

As a deviation from the WWW::Mechanize API, you can also pass a 
hash reference as the first parameter. In it, you can specify
the parameters to search much like for the C<find_link> calls.

=cut

sub click {
    my ($self,$name,$x,$y) = @_;
    my %options;
    my @buttons;
    
    if (! defined $name) {
        croak("->click called with undef link");
    } elsif (ref $name and blessed($name) and $name->can('__click')) {
        $options{ dom } = $name;
    } elsif (ref $name eq 'HASH') { # options
        %options = %$name;
    } else {
        $options{ name } = $name;
    };
    
    if (exists $options{ name }) {
        $name = quotemeta($options{ name }|| '');
        $options{ xpath } = [
                       sprintf( q{//*[(translate(local-name(.), "ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz")="button" and @name="%s") or (translate(local-name(.), "ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz")="input" and (@type="button" or @type="submit" or @type="image") and @name="%s")]}, $name, $name), 
        ];
        if ($options{ name } eq '') {
            push @{ $options{ xpath }}, 
                       q{//*[(translate(local-name(.), "ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz") = "button" or translate(local-name(.), "ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz")="input") and @type="button" or @type="submit" or @type="image"]},
            ;
        };
        $options{ user_info } = "Button with name '$name'";
    };
    
    if (! exists $options{ synchronize }) {
        $options{ synchronize } = 1;
    };
    
    if ($options{ dom }) {
        @buttons = $options{ dom };
    } else {
        @buttons = $self->_option_query(%options);
    };
        
    $self->_sync_call(
        $options{ synchronize }, $self->events, sub { # ,'abort'
            $buttons[0]->__click();
        }
    );

    if (defined wantarray) {
        return $self->response
    };
}

=head2 C<< $mech->click_button( ... ) >>

  $mech->click_button( name => 'go' );
  $mech->click_button( input => $mybutton );

Has the effect of clicking a button on the current form by specifying its
name, value, or index. Its arguments are a list of key/value pairs. Only
one of name, number, input or value must be specified in the keys.

=over 4

=item *

C<name> - name of the button

=item *

C<value> - value of the button

=item *

C<input> - DOM node

=item *

C<id> - id of the button

=item *

C<number> - number of the button

=back

If you find yourself wanting to specify a button through its
C<selector> or C<xpath>, consider using C<< ->click >> instead.

=cut

sub click_button {
    my ($self,%options) = @_;
    my $node;
    my $xpath;
    my $user_message;
    if (exists $options{ input }) {
        $node = delete $options{ input };
    } elsif (exists $options{ name }) {
        my $v = delete $options{ name };
        $xpath = sprintf( '//*[(translate(local-name(.), "ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz") = "button" and @name="%s") or (translate(local-name(.), "ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz")="input" and @type="button" or @type="submit" and @name="%s")]', $v, $v);
        $user_message = "Button name '$v' unknown";
    } elsif (exists $options{ value }) {
        my $v = delete $options{ value };
        $xpath = sprintf( '//*[(translate(local-name(.), "ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz") = "button" and @value="%s") or (translate(local-name(.), "ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz")="input" and (@type="button" or @type="submit") and @value="%s")]', $v, $v);
        $user_message = "Button value '$v' unknown";
    } elsif (exists $options{ id }) {
        my $v = delete $options{ id };
        $xpath = sprintf '//*[@id="%s"]', $v;
        $user_message = "Button name '$v' unknown";
    } elsif (exists $options{ number }) {
        my $v = delete $options{ number };
        $xpath = sprintf '//*[translate(local-name(.), "ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz") = "button" or (local-name() = "input" and @type="submit")][%s]', $v;
        $user_message = "Button number '$v' out of range";
    };
    #warn $xpath;
    $node ||= $self->xpath( $xpath,
                          node => $self->current_form,
                          single => 1,
                          user_message => $user_message,
              );
    if ($node) {
        $self->click({ dom => $node, %options });
    } else {
        
        $self->signal_condition($user_message);
    };
    
}

=head1 FORM METHODS

=head2 C<< $mech->current_form >>

  print $mech->current_form->{name};

Returns the current form.

This method is incompatible with L<WWW::Mechanize>.
It returns the DOM C<< <form> >> object and not
a L<HTML::Form> instance.

Note that WWW::Mechanize::Firefox has little way to know
that the current form is not displayed in the browser
anymore, so it often holds on to the last value. If
you want to make sure that a fresh or no form is used,
remove it:

    $mech->clear_current_form;
    
The current form will be reset by WWW::Mechanize::Firefox
on calls to C<< ->get() >> and C<< ->get_local() >>,
and on calls to C<< ->submit() >> and C<< ->submit_with_fields >>.

=cut

sub current_form {
    $_[0]->{current_form}
};
sub clear_current_form {
    undef $_[0]->{current_form};
};

=head2 C<< $mech->form_name $name [, %options] >>

  $mech->form_name( 'search' );

Selects the current form by its name. The options
are identical to those accepted by the L</$mech->xpath> method.

=cut

sub form_name {
    my ($self,$name,%options) = @_;
    $name = quote_xpath $name;
    _default_limiter( single => \%options );
    $self->{current_form} = $self->selector("form[name='$name']",
        user_info => "form name '$name'",
        %options
    );
};

=head2 C<< $mech->form_id $id [, %options] >>

  $mech->form_id( 'login' );

Selects the current form by its C<id> attribute.
The options
are identical to those accepted by the L</$mech->xpath> method.

This is equivalent to calling

    $mech->by_id($id,single => 1,%options)

=cut

sub form_id {
    my ($self,$name,%options) = @_;
    
    _default_limiter( single => \%options );
    $self->{current_form} = $self->by_id($name,
        user_info => "form with id '$name'",
        %options
    );
};

=head2 C<< $mech->form_number $number [, %options] >>

  $mech->form_number( 2 );

Selects the I<number>th form.
The options
are identical to those accepted by the L<< /$mech->xpath >> method.

=cut

sub form_number {
    my ($self,$number,%options) = @_;

    _default_limiter( single => \%options );
    $self->{current_form} = $self->xpath("//form[$number]",
        user_info => "form number $number",
        %options
    );
};

=head2 C<< $mech->form_with_fields [$options], @fields >>

  $mech->form_with_fields(
      'user', 'password'
  );

Find the form which has the listed fields.

If the first argument is a hash reference, it's taken
as options to C<< ->xpath >>.

See also L<< /$mech->submit_form >>.

=cut

sub form_with_fields {
    my ($self,@fields) = @_;
    my $options = {};
    if (ref $fields[0] eq 'HASH') {
        $options = shift @fields;
    };
    my @clauses  = map { $self->application->element_query([qw[input select textarea]], { 'name' => $_ })} @fields;
    
    
    my $q = "//form[" . join( " and ", @clauses)."]";
    #warn $q;
    _default_limiter( single => $options );
    $self->{current_form} = $self->xpath($q,
        user_info => "form with fields [@fields]",
        %$options
    );
};

=head2 C<< $mech->forms %options >>

  my @forms = $mech->forms();

When called in a list context, returns a list 
of the forms found in the last fetched page.
In a scalar context, returns a reference to
an array with those forms.

The options
are identical to those accepted by the L<< /$mech->selector >> method.

The returned elements are the DOM C<< <form> >> elements.

=cut

sub forms {
    my ($self, %options) = @_;
    my @res = $self->selector('form', %options);
    return wantarray ? @res
                     : \@res
};

=head2 C<< $mech->field $selector, $value, [,\@pre_events [,\@post_events]] >>

  $mech->field( user => 'joe' );
  $mech->field( not_empty => '', [], [] ); # bypass JS validation

Sets the field with the name given in C<$selector> to the given value.
Returns the value.

The method understands very basic CSS selectors in the value for C<$selector>,
like the L<HTML::Form> find_input() method.

A selector prefixed with '#' must match the id attribute of the input.
A selector prefixed with '.' matches the class attribute. A selector
prefixed with '^' or with no prefix matches the name attribute.

By passing the array reference C<@pre_events>, you can indicate which
Javascript events you want to be triggered before setting the value.
C<@post_events> contains the events you want to be triggered
after setting the value.

By default, the events set in the
constructor for C<pre_events> and C<post_events>
are triggered.

=cut

sub field {
    my ($self,$name,$value,$pre,$post) = @_;
    $self->get_set_value(
        name => $name,
        value => $value,
        pre => $pre,
        post => $post,
        node => $self->current_form,
    );
}

=head2 C<< $mech->value( $selector_or_element, [%options] ) >>

    print $mech->value( 'user' );

Returns the value of the field given by C<$selector_or_name> or of the
DOM element passed in.

The legacy form of

    $mech->value( name => value );

is also still supported but will likely be deprecated
in favour of the C<< ->field >> method.

For fields that can have multiple values, like a C<select> field,
the method is context sensitive and returns the first selected
value in scalar context and all values in list context.

=cut

sub value {
    if (@_ == 3) {
        my ($self,$name,$value) = @_;
        return $self->field($name => $value);
    } else {
        my ($self,$name,%options) = @_;
        return $self->get_set_value(
            node => $self->current_form,
            %options,
            name => $name,
        );
    };
};

=head2 C<< $mech->get_set_value( %options ) >>

Allows fine-grained access to getting/setting a value
with a different API. Supported keys are:

  pre
  post
  name
  value

in addition to all keys that C<< $mech->xpath >> supports.

=cut

sub _field_by_name {
    my ($self,%options) = @_;
    my @fields;
    my $name  = delete $options{ name };
    my $attr = 'name';
    if ($name =~ s/^\^//) { # if it starts with ^, it's supposed to be a name
        $attr = 'name'
    } elsif ($name =~ s/^#//) {
        $attr = 'id'
    } elsif ($name =~ s/^\.//) {
        $attr = 'class'
    };
    if (blessed $name) {
        @fields = $name;
    } else {
        _default_limiter( single => \%options );
        my $query = $self->application->element_query([qw[input select textarea]], { $attr => $name });
        #warn $query;
        @fields = $self->xpath($query,%options);
    };
    @fields
}

sub get_set_value {
    my ($self,%options) = @_;
    my $set_value = exists $options{ value };
    my $value = delete $options{ value };
    my $pre   = delete $options{pre}  || $self->{pre_value};
    my $post  = delete $options{post} || $self->{post_value};
    my $name  = delete $options{ name };
    my @fields = $self->_field_by_name(
                     name => $name, 
                     user_info => "input with name '$name'",
                     %options );
    $pre = [$pre]
        if (! ref $pre);
    $post = [$post]
        if (! ref $post);
        
    if ($fields[0]) {
        my $tag = $fields[0]->{tagName};
        if ($set_value) {
            for my $ev (@$pre) {
                $fields[0]->__event($ev);
            };

            if ('select' eq $tag) {
                $self->select($fields[0], $value);
            } else {
                $fields[0]->{value} = $value;
            };

            for my $ev (@$post) {
                $fields[0]->__event($ev);
            };
        };
        # What about 'checkbox'es/radioboxes?

        # Don't bother to fetch the field's value if it's not wanted
        return unless defined wantarray;

        # We could save some work here for the simple case of single-select
        # dropdowns by not enumerating all options
        if ('SELECT' eq uc $tag) {
            my @options = $self->xpath('.//option', node => $fields[0] );
            my @values = map { $_->{value} } grep { $_->{selected} } @options;
            if (wantarray) {
                return @values
            } else {
                return $values[0];
            }
        } else {
            return $fields[0]->{value}
        };
    } else {
        return
    }
}

=head2 C<< $mech->select( $name, $value ) >>

=head2 C<< $mech->select( $name, \@values ) >>

Given the name of a C<select> field, set its value to the value
specified.  If the field is not C<< <select multiple> >> and the
C<$value> is an array, only the B<first> value will be set. 
Passing C<$value> as a hash with
an C<n> key selects an item by number (e.g.
C<< {n => 3} >> or C<< {n => [2,4]} >>).
The numbering starts at 1.  This applies to the current form.

If you have a field with C<< <select multiple> >> and you pass a single
C<$value>, then C<$value> will be added to the list of fields selected,
without clearing the others.  However, if you pass an array reference,
then all previously selected values will be cleared.

Returns true on successfully setting the value. On failure, returns
false and calls C<< $self>warn() >> with an error message.

=cut

sub select {
    my ($self, $name, $value) = @_;
    my ($field) = $self->_field_by_name(
        node => $self->current_form,
        name => $name,
        #%options,
    );
    
    if (! $field) {
        return
    };
    
    my @options = $self->xpath( './/option', node => $field);
    my @by_index;
    my @by_value;
    my $single = $field->{type} eq "select-one";
    my $deselect;

    if ('HASH' eq ref $value||'') {
        for (keys %$value) {
            $self->warn(qq{Unknown select value parameter "$_"})
              unless $_ eq 'n';
        }
        
        $deselect = ref $value->{n};
        @by_index = ref $value->{n} ? @{ $value->{n} } : $value->{n};
    } elsif ('ARRAY' eq ref $value||'') {
        # clear all preselected values
        $deselect = 1;
        @by_value = @{ $value };
    } else {
        @by_value = $value;
    };
    
    if ($deselect) {
        for my $o (@options) {
            $o->{selected} = 0;
        }
    };
    
    if ($single) {
        # Only use the first element for single-element boxes
        $#by_index = 0+@by_index ? 0 : -1;
        $#by_value = 0+@by_value ? 0 : -1;
    };
    
    # Select the items, either by index or by value
    for my $idx (@by_index) {
        $options[$idx-1]->{selected} = 1;
    };
    
    for my $v (@by_value) {
        my $option = $self->xpath( sprintf( './/option[@value="%s"]', quote_xpath $v) , node => $field, single => 1 );
        $option->{selected} = 1;
    };
    
    return @by_index + @by_value > 0;
}

=head2 C<< $mech->tick( $name, $value [, $set ] ) >>

    $mech->tick("confirmation_box", 'yes');

"Ticks" the first checkbox that has both the name and value associated with it
on the current form. Dies if there is no named check box for that value.
Passing in a false value as the third optional argument will cause the
checkbox to be unticked.

(Un)ticking the checkbox is done by sending a click event to it if needed.
If C<$value> is C<undef>, the first checkbox matching C<$name> will 
be (un)ticked.

If C<$name> is a reference to a hash, that hash will be used
as the options to C<< ->find_link_dom >> to find the element.

=cut

sub tick {
    my ($self, $name, $value, $set) = @_;
    $set = 1
        if (@_ < 4);
    my %options;
    my @boxes;
    
    if (! defined $name) {
        croak("->tick called with undef name");
    } elsif (ref $name and blessed($name) and $name->can('__click')) {
        $options{ dom } = $name;
    } elsif (ref $name eq 'HASH') { # options
        %options = %$name;
    } else {
        $options{ name } = $name;
    };
    
    if (exists $options{ name }) {
        my $attr = 'name';
        if ($name =~ s/^\^//) { # if it starts with ^, it's supposed to be a name
            $attr = 'name'
        } elsif ($name =~ s/^#//) {
            $attr = 'id'
        } elsif ($name =~ s/^\.//) {
            $attr = 'class'
        };
        $name = quotemeta($name);
        $value = quotemeta($value) if $value;
    
        _default_limiter( one => \%options );
        $options{ xpath } = [
                       defined $value
                       ? sprintf( q{//input[@type="checkbox" and @%s="%s" and @value="%s"]}, $attr, $name, $value)
                       : sprintf( q{//input[@type="checkbox" and @%s="%s"]}, $attr, $name)
        ];
        $options{ user_info } =  defined $value
                              ? "Checkbox with name '$name' and value '$value'"
                              : "Checkbox with name '$name'";
    };
    
    if ($options{ dom }) {
        @boxes = $options{ dom };
    } else {
        @boxes = $self->_option_query(%options);
    };
    
    my $target = $boxes[0];
    my $is_set = $target->{checked} eq 'true';
    if ($set xor $is_set) {
        if ($set) {
            $target->{checked}= 'checked';
        } else {
            $target->{checked} = 0;
        };
    };
};

=head2 C<< $mech->untick($name, $value) >>

  $mech->untick('spam_confirm','yes',undef)

Causes the checkbox to be unticked. Shorthand for 

  $mech->tick($name,$value,undef)

=cut

sub untick {
    my ($self, $name, $value) = @_;
    $self->tick( $name, $value, undef );
};

=head2 C<< $mech->submit >>

  $mech->submit;

Submits the current form. Note that this does B<not> fire the C<onClick>
event and thus also does not fire eventual Javascript handlers.
Maybe you want to use C<< $mech->click >> instead.

=cut

sub submit {
    my ($self,$dom_form) = @_;
    $dom_form ||= $self->current_form;
    if ($dom_form) {
        $dom_form->submit(); # why don't we ->synchronize here??
        $self->signal_http_status;

        $self->clear_current_form;
        1;
    } else {
        croak "I don't know which form to submit, sorry.";
    }
};

=head2 C<< $mech->submit_form( %options ) >>

  $mech->submit_form(
      with_fields => {
          user => 'me',
          pass => 'secret',
      }
  );

This method lets you select a form from the previously fetched page,
fill in its fields, and submit it. It combines the form_number/form_name,
set_fields and click methods into one higher level call. Its arguments are
a list of key/value pairs, all of which are optional.

=over 4

=item *

C<< form => $mech->current_form() >>

Specifies the form to be filled and submitted. Defaults to the current form.

=item *

C<< fields => \%fields >>

Specifies the fields to be filled in the current form

=item *

C<< with_fields => \%fields >>

Probably all you need for the common case. It combines a smart form selector
and data setting in one operation. It selects the first form that contains
all fields mentioned in \%fields. This is nice because you don't need to
know the name or number of the form to do this.

(calls L<< /$mech->form_with_fields() >> and L<< /$mech->set_fields() >>).

If you choose this, the form_number, form_name, form_id and fields options
will be ignored.

=back

=cut

sub submit_form {
    my ($self,%options) = @_;
    
    my $form = delete $options{ form };
    my $fields;
    if (! $form) {
        if ($fields = delete $options{ with_fields }) {
            my @names = keys %$fields;
            $form = $self->form_with_fields( \%options, @names );
            if (! $form) {
                $self->signal_condition("Couldn't find a matching form for @names.");
                return
            };
        } else {
            $fields = delete $options{ fields } || {};
            $form = $self->current_form;
        };
    };
    
    if (! $form) {
        $self->signal_condition("No form found to submit.");
        return
    };
    $self->do_set_fields( form => $form, fields => $fields );
    $self->submit($form);
}

=head2 C<< $mech->set_fields( $name => $value, ... ) >>

  $mech->set_fields(
      user => 'me',
      pass => 'secret',
  );

This method sets multiple fields of the current form. It takes a list of
field name and value pairs. If there is more than one field with the same
name, the first one found is set. If you want to select which of the
duplicate field to set, use a value which is an anonymous array which
has the field value and its number as the 2 elements.

=cut

sub set_fields {
    my ($self, %fields) = @_;
    my $f = $self->current_form;
    if (! $f) {
        croak "Can't set fields: No current form set.";
    };
    $self->do_set_fields(form => $f, fields => \%fields);
};

sub do_set_fields {
    my ($self, %options) = @_;
    my $form = delete $options{ form };
    my $fields = delete $options{ fields };
    
    while (my($n,$v) = each %$fields) {
        if (ref $v) {
            ($v,my $num) = @$v;
            warn "Index larger than 1 not supported, ignoring"
                unless $num == 1;
        };
        
        $self->get_set_value( node => $form, name => $n, value => $v, %options );
    }
};

=head2 C<< $mech->set_visible( @values ) >>

  $mech->set_visible( $username, $password );

This method sets fields of the current form without having to know their
names. So if you have a login screen that wants a username and password,
you do not have to fetch the form and inspect the source (or use the
C<mech-dump> utility, installed with L<WWW::Mechanize>) to see what
the field names are; you can just say

  $mech->set_visible( $username, $password );

and the first and second fields will be set accordingly. The method is
called set_visible because it acts only on visible fields;
hidden form inputs are not considered. 

The specifiers that are possible in L<WWW::Mechanize> are not yet supported.

=cut

sub set_visible {
    my ($self,@values) = @_;
    my $form = $self->current_form;
    my @form;
    if ($form) { @form = (node => $form) };
    my @visible_fields = $self->xpath(q{//input[not(@type) or (@type != "hidden" and @type!= "button" and @type!="submit")]}, 
                                      @form
                                      );
    for my $idx (0..$#values) {
        if ($idx > $#visible_fields) {
            $self->signal_condition( "Not enough fields on page" );
        }
        $self->field( $visible_fields[ $idx ] => $values[ $idx ]);
    }
}

=head2 C<< $mech->is_visible $element >>

=head2 C<< $mech->is_visible %options >>

  if ($mech->is_visible( selector => '#login' )) {
      print "You can log in now.";
  };

Returns true if the element is visible, that is, it is
a member of the DOM and neither it nor its ancestors have
a CSS C<visibility> attribute of C<hidden> or
a C<display> attribute of C<none>.

You can either pass in a DOM element or a set of key/value
pairs to search the document for the element you want.

=over 4

=item *

C<xpath> - the XPath query

=item *

C<selector> - the CSS selector

=item *

C<dom> - a DOM node

=back

The remaining options are passed through to either the
L<< /$mech->xpath|xpath >> or L<< /$mech->selector|selector >> method.

=cut

sub is_visible {
    my ($self,%options);
    if (2 == @_) {
        ($self,$options{dom}) = @_;
    } else {
        ($self,%options) = @_;
    };
    _default_limiter( 'maybe', \%options );
    if (! $options{dom}) {
        $options{dom} = $self->_option_query(%options);
    };
    # No element means not visible
    return
        unless $options{ dom };
    $options{ window } ||= $self->tab->{linkedBrowser}->{contentWindow};
    
    
    my $_is_visible = $self->repl->declare(<<'JS');
    function (obj,window)
    {
        while (obj) {
            // No object
            if (!obj) return false;
            // Descends from document, so we're done
            if (obj.parentNode === obj.ownerDocument) {
                return true;
            };
            // Not in the DOM
            if (!obj.parentNode) {
                return false;
            };
            // Direct style check
            if (obj.style) {
                if (obj.style.display == 'none') return false;
                if (obj.style.visibility == 'hidden') return false;
            };
            
            if (window.getComputedStyle) {
                var style = window.getComputedStyle(obj, null);
                if (style.display == 'none') {
                    return false; }
                if (style.visibility == 'hidden') {
                    return false;
                };
            }
            obj = obj.parentNode;
        };
        // The object does not live in the DOM at all
        return false
    }
JS
    !!$_is_visible->($options{dom}, $options{window});
};

=head2 C<< $mech->wait_until_invisible( $element ) >>

=head2 C<< $mech->wait_until_invisible( %options ) >>

  $mech->wait_until_invisible( $please_wait );

Waits until an element is not visible anymore.

Takes the same options as L<< $mech->is_visible/->is_visible >>.

In addition, the following options are accepted:

=over 4

=item *

C<timeout> - the timeout after which the function will C<croak>. To catch
the condition and handle it in your calling program, use an L<eval> block.
A timeout of C<0> means to never time out.

=item *

C<sleep> - the interval in seconds used to L<sleep>. Subsecond
intervals are possible.

=back

=cut

sub wait_until_invisible {
    my ($self,%options);
    if (2 == @_) {
        ($self,$options{dom}) = @_;
    } else {
        ($self,%options) = @_;
    };
    my $sleep = delete $options{ sleep } || 0.3;
    my $timeout = delete $options{ timeout } || 0;
    
    _default_limiter( 'maybe', \%options );

    if (! $options{dom}) {
        $options{dom} = $self->_option_query(%options);
    };
    return
        unless $options{dom};

    my $timeout_after;
    if ($timeout) {
        $timeout_after = time + $timeout;
    };
    my $v;
    while (     $v = $self->is_visible($options{dom})
           and (!$timeout_after or time < $timeout_after )) {
        sleep $sleep;
    };
    if (! $v and time > $timeout_after) {
        croak "Timeout of $timeout seconds reached while waiting for element";
    };    
};

# Internal method to run either an XPath, CSS or id query against the DOM
# Returns the element(s) found
my %rename = (
    xpath => 'xpath',
    selector => 'selector',
    id => 'by_id',
    by_id => 'by_id',
);

sub _option_query {
    my ($self,%options) = @_;
    my ($method,$q);
    for my $meth (keys %rename) {
        if (exists $options{ $meth }) {
            $q = delete $options{ $meth };
            $method = $rename{ $meth } || $meth;
        }
    };
    _default_limiter( 'one' => \%options );
    croak "Need either a name, a selector or an xpath key!"
        if not $method;
    return $self->$method( $q, %options );
};

=head2 C<< $mech->clickables >>

    print "You could click on\n";
    for my $el ($mech->clickables) {
        print $el->{innerHTML}, "\n";
    };

Returns all clickable elements, that is, all elements
with an C<onclick> attribute.

=cut

sub clickables {
    my ($self, %options) = @_;
    $self->xpath('//*[@onclick]', %options);
};

=head2 C<< $mech->expand_frames( $spec ) >>

  my @frames = $mech->expand_frames();

Expands the frame selectors (or C<1> to match all frames)
into their respective DOM document nodes according to the current
document. All frames will be visited in breadth first order.

This is mostly an internal method.

=cut

sub expand_frames {
    my ($self, $spec, $document) = @_;
    $spec ||= $self->{frames};
    my @spec = ref $spec ? @$spec : $spec;
    $document ||= $self->document;
    
    if ($spec == 1) {
        # All frames
        @spec = qw( frame iframe );
    };
    
    # Optimize the default case of only names in @spec
    my @res;
    if (! grep {ref} @spec) {
        @res = map { $_->{contentDocument} }
               $self->selector(
                        \@spec,
                        document => $document,
                        frames => 0, # otherwise we'll recurse :)
                    );
    } else {
        @res = 
            map { #warn "Expanding $_";
                    ref $_
                  ? $_
                  # Just recurse into the above code path
                  : $self->expand_frames( $_, $document );
            } @spec;
    }
};

=head1 IMAGE METHODS

=head2 C<< $mech->content_as_png( [$tab, \%coordinates ] ) >>

    my $png_data = $mech->content_as_png();

Returns the given tab or the current page rendered as PNG image.

All parameters are optional. 

=over 4

=item *

C<$tab> defaults to the current tab.

=item *

If the coordinates are given, that rectangle will be cut out.
The coordinates should be a hash with the four usual entries,
C<left>,C<top>,C<width>,C<height>.

=back

This is specific to WWW::Mechanize::Firefox.

Currently, the data transfer between Firefox and Perl
is done Base64-encoded. It would be beneficial to find what's
necessary to make JSON handle binary data more gracefully.

=cut

sub content_as_png {
    my ($self, $tab, $rect) = @_;
    $tab ||= $self->tab;
    $rect ||= {};
    
    # Mostly taken from
    # http://wiki.github.com/bard/mozrepl/interactor-screenshot-server
    my $screenshot = $self->repl->declare(<<'JS');
    function (tab,rect) {
        var browser = tab.linkedBrowser;
        var browserWindow = Components.classes['@mozilla.org/appshell/window-mediator;1']
            .getService(Components.interfaces.nsIWindowMediator)
            .getMostRecentWindow('navigator:browser');
        var win = browser.contentWindow;
        var body = win.document.body;
        if(!body) {
            return;
        };
        var canvas = browserWindow
               .document
               .createElementNS('http://www.w3.org/1999/xhtml', 'canvas');
        var left = rect.left || 0;
        var top = rect.top || 0;
        var width = rect.width || body.clientWidth;
        var height = rect.height || body.clientHeight;
        canvas.width = width;
        canvas.height = height;
        var ctx = canvas.getContext('2d');
        ctx.clearRect(0, 0, width, height);
        ctx.save();
        ctx.scale(1.0, 1.0);
        ctx.drawWindow(win, left, top, width, height, 'rgb(255,255,255)');
        ctx.restore();

        //return atob(
        return canvas
               .toDataURL('image/png', '')
               .split(',')[1]
        // );
    }
JS
    my $scr = $screenshot->($tab, $rect);
    return $scr ? decode_base64($scr) : undef
};

=head2 C<< $mech->element_as_png( $element ) >>

    my $shiny = $mech->selector('#shiny', single => 1);
    my $i_want_this = $mech->element_as_png($shiny);

Returns PNG image data for a single element

=cut

sub element_as_png {
    my ($self, $element) = @_;
    my $tab = $self->tab;

    my $pos = $self->element_coordinates($element);
    return $self->content_as_png($tab, $pos);
};

=head2 C<< $mech->element_coordinates( $element ) >>

    my $shiny = $mech->selector('#shiny', single => 1);
    my ($pos) = $mech->element_coordinates($shiny);
    print $pos->{x},',', $pos->{y};

Returns the page-coordinates of the C<$element>
in pixels as a hash with four entries, C<left>, C<top>, C<width> and C<height>.

This function might get moved into another module more geared
towards rendering HTML.

=cut

sub element_coordinates {
    my ($self, $element) = @_;
    
    # Mostly taken from
    # http://www.quirksmode.org/js/findpos.html
    my $findPos = $self->repl->declare(<<'JS');
    function (obj) {
        var res = { 
            left: 0,
            top: 0,
            width: obj.scrollWidth,
            height: obj.scrollHeight
        };
        if (obj.offsetParent) {
            do {
                res.left += obj.offsetLeft;
                res.top += obj.offsetTop;
            } while (obj = obj.offsetParent);
        }
        return res;
    }
JS
    $findPos->($element);
};

1;

__END__

=head1 COOKIE HANDLING

Firefox cookies will be read through L<HTTP::Cookies::MozRepl>. This is
relatively slow currently.

=head1 INCOMPATIBILITIES WITH WWW::Mechanize

As this module is in a very early stage of development,
there are many incompatibilities. The main thing is
that only the most needed WWW::Mechanize methods
have been implemented by me so far.

=head2 Link attributes

In Firefox, the C<name> attribute of links seems always
to be present on links, even if it's empty. This is in
difference to WWW::Mechanize, where the C<name> attribute
can be C<undef>.

=head2 Frame tags

Firefox is much less lenient than WWW::Mechanize when it comes
to FRAME tags. A page will not contain a FRAME tag if it contains
content other than the FRAMESET. WWW::Mechanize has no such restriction.

=head2 Unsupported Methods

=over 4

=item *

C<< ->find_all_inputs >>

This function is likely best implemented through C<< $mech->selector >>.

=item *

C<< ->find_all_submits >>

This function is likely best implemented through C<< $mech->selector >>.

=item *

C<< ->images >>

This function is likely best implemented through C<< $mech->selector >>.

=item *

C<< ->find_image >>

This function is likely best implemented through C<< $mech->selector >>.

=item *

C<< ->find_all_images >>

This function is likely best implemented through C<< $mech->selector >>.

=back

=head2 Functions that will likely never be implemented

These functions are unlikely to be implemented because
they make little sense in the context of Firefox.

=over 4

=item *

C<< ->add_header >>

=item *

C<< ->delete_header >>

=item *

C<< ->clone >>

=item *

C<< ->credentials( $username, $password ) >>

=item *

C<< ->get_basic_credentials( $realm, $uri, $isproxy ) >>

=item *

C<< ->clear_credentials() >>

=item *

C<< ->put >>

I have no use for it

=item *

C<< ->post >>

I have no use for it

=back

=head1 TODO

=over 4

=item *

Add C<< limit >> parameter to C<< ->xpath() >> to allow an early exit-case
when searching through frames.

=item *

Implement download progress via C<nsIWebBrowserPersist.progressListener>
and our own C<nsIWebProgressListener>.

=item *

Rip out parts of Test::HTML::Content and graft them
onto the C<links()> and C<find_link()> methods here.
Firefox is a conveniently unified XPath engine.

Preferrably, there should be a common API between the two.

=item *

Spin off XPath queries (C<< ->xpath >>) and CSS selectors (C<< ->selector >>)
into their own Mechanize plugin(s).

=back

=head1 INSTALLING

=over 4

=item *

Install the C<mozrepl> add-on into Firefox

=item *

Start the C<mozrepl> add-on or you will see test failures/skips
in the module when calling C<< ->new >>. You may want to set
C<mozrepl> to start when the browser starts.

=back

=head1 SEE ALSO

=over 4

=item *

The MozRepl Firefox plugin at L<http://wiki.github.com/bard/mozrepl>

=item *

L<WWW::Mechanize> - the module whose API grandfathered this module

=item *

L<WWW::Scripter> - another WWW::Mechanize-workalike with Javascript support

=item *

L<https://developer.mozilla.org/En/FUEL/Window> for JS events relating to tabs

=item *

L<https://developer.mozilla.org/en/Code_snippets/Tabbed_browser#Reusing_tabs>
for more tab info

=item *

L<https://developer.mozilla.org/en/Document_Loading_-_From_Load_Start_to_Finding_a_Handler>
for information on how to possibly override the "Save As" dialog

=item *

L<http://code.google.com/p/selenium/source/browse/trunk/javascript/firefox-driver/extension/components/promptService.js>
for information on how to override a lot of other prompts (like proxy etc.)

=back

=head1 REPOSITORY

The public repository of this module is 
L<http://github.com/Corion/www-mechanize-firefox>.

=head1 SUPPORT

The public support forum of this module is
L<http://perlmonks.org/>.

=head1 TALKS

I've given two talks about this module at Perl conferences:

L<http://corion.net/talks/WWW-Mechanize-FireFox/www-mechanize-firefox.html|German Perl Workshop, German>

L<http://corion.net/talks/WWW-Mechanize-FireFox/www-mechanize-firefox.en.html|YAPC::Europe 2010, English>

=head1 BUG TRACKER

Please report bugs in this module via the RT CPAN bug queue at
L<https://rt.cpan.org/Public/Dist/Display.html?Name=WWW-Mechanize-Firefox>
or via mail to L<www-mechanize-firefox-Bugs@rt.cpan.org>.

=head1 AUTHOR

Max Maischein C<corion@cpan.org>

=head1 COPYRIGHT (c)

Copyright 2009-2011 by Max Maischein C<corion@cpan.org>.

=head1 LICENSE

This module is released under the same terms as Perl itself.

=cut
