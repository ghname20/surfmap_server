#!perl
use XMLRPC::Lite +trace => [ 
#dispatch => \&log_dispatch,
#result => \&log_result,
#parameters => \&log_parameters,
#headers => \&log_headers,
#objects => \&log_objects,
#method => \&log_method,
#fault => \&log_fault,
#freeform => \&log_freeform,
#trace => \&log_trace,
debug => \&log_debug
] ;
use XMLRPC::Transport::HTTP;

print STDERR "pid=$$\n";

open $f, '>:raw', 'kkth.cmd';
print {$f} "taskkill /f /pid $$\n";
close $f;

$PORT=12345;
$daemon = XMLRPC::Transport::HTTP::Daemon
          ->new(LocalPort => $PORT)
          ->dispatch_to('KMG')
          ->handle( );


sub log_dispatch { &log_it('dispatch',@_) };
sub log_result { &log_it('result',@_) };
sub log_parameters { &log_it('parameters',@_) };
sub log_headers { &log_it('headers',@_) };
sub log_objects { &log_it('objects',@_) };
sub log_method { &log_it('method',@_) };
sub log_fault { &log_it('fault',@_) };
sub log_freeform { &log_it('freeform',@_) };
sub log_trace { &log_it('trace',@_) };
sub log_debug { &log_it('debug',@_) };


sub log_it {
  $method = shift;
  open LOGFILE, ">>server.log";
  print LOGFILE  "$method: $_[0]\n";
  close LOGFILE;
  print STDERR  "$method: $_[0]\n";
}


package KMG;

sub handler {
  my ($class, $args) = @_;
  print STDERR map { qq{$_: $args->{$_}} } sort keys %$args;
  return { test1=>1, test2=>2  };
}

